#!/usr/bin/env python3
"""WebSocket bridge between the Noctalia MagicPods plugin and the MagicPodsCore daemon.

Noctalia's Luau runtime can spawn processes (``noctalia.runStream`` /
``noctalia.runAsync``) and make HTTP requests, but it has no WebSocket client.
MagicPodsCore only speaks WebSocket JSON (see ``api-reference.md``), so this
script is the glue: a tiny, dependency-free RFC 6455 client.

Two modes:

  stream            Connect, request the full state once (``GetAll``) and then
                    print every JSON message the daemon sends, one per line, on
                    stdout. Reconnects forever with backoff. The Luau service
                    entry runs this under ``noctalia.runStream`` and forwards
                    each line into ``noctalia.state``.

  send <json>       Connect, send a single JSON request (``ConnectDevice``,
                    ``DisconnectDevice``, ``SetCapabilities``, ``GetAll`` ...),
                    print whatever the daemon replies for a short window, then
                    exit. The Luau service runs this one-shot per user action
                    via ``noctalia.runAsync``.

Connection lifecycle messages are emitted as ``{"_bridge": {...}}`` lines so the
plugin can show a "daemon offline" state without guessing.

Pure standard library on purpose: a Noctalia user only needs ``python3``.
"""

import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
from urllib.parse import urlparse

# Default matches MagicPodsCore's WebSocket port. The daemon listens on all
# interfaces, so localhost is the correct address for a per-user desktop
# service (the "172.0.1.0" in the upstream docs is illustrative only).
DEFAULT_URL = "ws://127.0.0.1:2020"

RECONNECT_MIN_SECONDS = 1.0
RECONNECT_MAX_SECONDS = 15.0
SEND_READ_WINDOW_SECONDS = 2.0

# RFC 6455 opcodes
OP_CONT = 0x0
OP_TEXT = 0x1
OP_BIN = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA


class WebSocketError(Exception):
    pass


class WebSocketClient:
    """Minimal synchronous WebSocket client (client-to-server frames masked)."""

    def __init__(self, url, timeout=10.0):
        parsed = urlparse(url)
        if parsed.scheme not in ("ws", "wss"):
            raise WebSocketError(f"unsupported scheme: {parsed.scheme!r}")
        if parsed.scheme == "wss":
            # The daemon is a local plaintext server; TLS is intentionally
            # unsupported to keep the bridge dependency-free.
            raise WebSocketError("wss (TLS) is not supported by this bridge")
        self._host = parsed.hostname or "127.0.0.1"
        self._port = parsed.port or 2020
        self._path = parsed.path or "/"
        if parsed.query:
            self._path += "?" + parsed.query
        self._timeout = timeout
        self._sock = None
        self._recv_buf = b""

    def connect(self):
        self._sock = socket.create_connection((self._host, self._port), self._timeout)
        self._sock.settimeout(self._timeout)
        self._handshake()

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {self._path} HTTP/1.1\r\n"
            f"Host: {self._host}:{self._port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            # Deliberately do NOT offer permessage-deflate: without it the
            # server never compresses, so frame parsing stays simple.
            "\r\n"
        )
        self._sock.sendall(request.encode("ascii"))

        header = self._read_until(b"\r\n\r\n")
        status_line = header.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = status_line.split(" ", 2)
        if len(parts) < 2 or parts[1] != "101":
            raise WebSocketError(f"handshake failed: {status_line!r}")

    def _read_until(self, marker):
        while marker not in self._recv_buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise WebSocketError("connection closed during handshake")
            self._recv_buf += chunk
        idx = self._recv_buf.index(marker) + len(marker)
        head, self._recv_buf = self._recv_buf[:idx], self._recv_buf[idx:]
        return head

    def _recv_exactly(self, n):
        while len(self._recv_buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise WebSocketError("connection closed")
            self._recv_buf += chunk
        data, self._recv_buf = self._recv_buf[:n], self._recv_buf[n:]
        return data

    def send_text(self, text):
        self._send_frame(OP_TEXT, text.encode("utf-8"))

    def _send_frame(self, opcode, payload):
        fin_op = 0x80 | opcode
        header = bytearray([fin_op])
        length = len(payload)
        mask_bit = 0x80  # client frames MUST be masked
        if length < 126:
            header.append(mask_bit | length)
        elif length < 65536:
            header.append(mask_bit | 126)
            header += struct.pack("!H", length)
        else:
            header.append(mask_bit | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._sock.sendall(bytes(header) + masked)

    def recv_message(self):
        """Return the next application text message, transparently handling
        control frames and fragmentation. Returns None when the peer closes."""
        data = bytearray()
        message_opcode = None
        while True:
            first = self._recv_exactly(1)[0]
            fin = first & 0x80
            opcode = first & 0x0F
            second = self._recv_exactly(1)[0]
            masked = second & 0x80
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exactly(8))[0]
            mask = self._recv_exactly(4) if masked else b""
            payload = self._recv_exactly(length) if length else b""
            if masked and payload:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == OP_CLOSE:
                try:
                    self._send_frame(OP_CLOSE, b"")
                except OSError:
                    pass
                return None
            if opcode == OP_PING:
                self._send_frame(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue

            if opcode in (OP_TEXT, OP_BIN):
                message_opcode = opcode
            data += payload
            if fin:
                if message_opcode == OP_TEXT:
                    return data.decode("utf-8", "replace")
                # Binary frames are not part of the MagicPodsCore protocol.
                return ""

    def close(self):
        if self._sock is not None:
            try:
                self._send_frame(OP_CLOSE, b"")
            except OSError:
                pass
            try:
                self._sock.close()
            finally:
                self._sock = None


def _emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _emit_line(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def run_stream(url):
    backoff = RECONNECT_MIN_SECONDS
    while True:
        client = WebSocketClient(url)
        try:
            client.connect()
        except (OSError, WebSocketError) as exc:
            _emit({"_bridge": {"connected": False, "error": str(exc)}})
            time.sleep(backoff)
            backoff = min(backoff * 2, RECONNECT_MAX_SECONDS)
            continue

        backoff = RECONNECT_MIN_SECONDS
        _emit({"_bridge": {"connected": True}})
        try:
            client.send_text(json.dumps({"method": "GetAll"}))
            while True:
                message = client.recv_message()
                if message is None:
                    break
                message = message.strip()
                if message:
                    _emit_line(message)
        except (OSError, WebSocketError) as exc:
            _emit({"_bridge": {"connected": False, "error": str(exc)}})
        finally:
            client.close()

        _emit({"_bridge": {"connected": False}})
        time.sleep(backoff)
        backoff = min(backoff * 2, RECONNECT_MAX_SECONDS)


def run_send(url, payload):
    # Validate/normalize the JSON so the daemon never sees garbage.
    try:
        obj = json.loads(payload)
    except json.JSONDecodeError as exc:
        _emit({"_bridge": {"error": f"invalid json: {exc}"}})
        return 2

    client = WebSocketClient(url)
    try:
        client.connect()
    except (OSError, WebSocketError) as exc:
        _emit({"_bridge": {"connected": False, "error": str(exc)}})
        return 1

    try:
        client.send_text(json.dumps(obj, separators=(",", ":")))
        deadline = time.monotonic() + SEND_READ_WINDOW_SECONDS
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            client._sock.settimeout(max(0.1, remaining))
            try:
                message = client.recv_message()
            except (socket.timeout, TimeoutError):
                break
            except (OSError, WebSocketError):
                break
            if message is None:
                break
            message = message.strip()
            if message:
                _emit_line(message)
    finally:
        client.close()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="MagicPodsCore WebSocket bridge")
    parser.add_argument("--url", default=os.environ.get("MAGICPODS_URL", DEFAULT_URL))
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("stream", help="stream daemon messages as JSON lines")
    send_parser = sub.add_parser("send", help="send one JSON request")
    send_parser.add_argument("json", help="the JSON request to send")

    args = parser.parse_args(argv)
    if args.mode == "stream":
        try:
            run_stream(args.url)
        except KeyboardInterrupt:
            return 0
        return 0
    if args.mode == "send":
        return run_send(args.url, args.json)
    return 1


if __name__ == "__main__":
    sys.exit(main())
