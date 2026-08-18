#!/usr/bin/env python3
"""A mock MagicPodsCore WebSocket daemon for testing the bridge and plugin.

It implements enough of the protocol (api-reference.md) to exercise the plugin
end to end without real Bluetooth hardware: init handshake, GetAll, Connect/
Disconnect, SetCapabilities, broadcasts, and a periodic battery drain so the
streaming path shows live updates.

Standard library only (server side of RFC 6455).
"""

import argparse
import base64
import hashlib
import json
import socket
import struct
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_TEXT = 0x1
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

lock = threading.Lock()
clients = []  # list of sockets currently connected

state = {
    "bluetooth": True,
    "devices": [
        {"name": "AirPods Pro", "address": "AA:BB:CC:DD:EE:FF", "vendor": 76, "model": 8207, "color": 0, "connected": True},
        {"name": "Galaxy Buds 3", "address": "11:22:33:44:55:66", "vendor": 117, "model": 9, "color": 0, "connected": False},
    ],
    "info": {
        "name": "AirPods Pro",
        "address": "AA:BB:CC:DD:EE:FF",
        "vendor": 76,
        "model": 8207,
        "color": 0,
        "connected": True,
        "capabilities": {
            "battery": {
                "single": {"battery": 0, "charging": False, "status": 0},
                "left": {"battery": 80, "charging": False, "status": 2},
                "right": {"battery": 72, "charging": False, "status": 2},
                "case": {"battery": 45, "charging": True, "status": 3},
                "readonly": True,
            },
            # 23 = Off(1) | Transparency(2) | Adaptive(4) | NoiseCancellation(16)
            "anc": {"selected": 16, "options": 23, "readonly": False},
            "conversationAwareness": {"selected": True, "readonly": False},
            "personalizedVolume": {"selected": False, "readonly": False},
        },
    },
}


def make_devices_msg():
    devices = []
    for d in state["devices"]:
        devices.append({k: v for k, v in d.items()})
    return {"headphones": devices}


def make_info_msg():
    if state["info"] and state["info"].get("connected"):
        return {"info": state["info"]}
    return {"info": {}}


def make_bt_msg():
    return {"defaultbluetooth": {"enabled": state["bluetooth"]}}


def make_getall_msg():
    return {
        "headphones": make_devices_msg()["headphones"],
        "defaultbluetooth": make_bt_msg()["defaultbluetooth"],
        "info": make_info_msg()["info"],
    }


def send_frame(sock, payload, opcode=OP_TEXT):
    data = payload.encode("utf-8") if isinstance(payload, str) else payload
    header = bytearray([0x80 | opcode])
    length = len(data)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack("!H", length)
    else:
        header.append(127)
        header += struct.pack("!Q", length)
    try:
        sock.sendall(bytes(header) + data)
    except OSError:
        pass


def broadcast(msg):
    text = json.dumps(msg)
    with lock:
        targets = list(clients)
    for c in targets:
        send_frame(c, text)


def recv_frame(sock):
    def recv_exactly(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    first = recv_exactly(1)
    if first is None:
        return None
    opcode = first[0] & 0x0F
    second = recv_exactly(1)
    if second is None:
        return None
    masked = second[0] & 0x80
    length = second[0] & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exactly(8))[0]
    mask = recv_exactly(4) if masked else b""
    payload = recv_exactly(length) if length else b""
    if payload is None:
        return None
    if masked and payload:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def handle_request(sock, text):
    try:
        req = json.loads(text)
    except json.JSONDecodeError:
        send_frame(sock, "")
        return
    method = req.get("method")
    args = req.get("arguments", {})

    if method == "GetAll":
        send_frame(sock, json.dumps(make_getall_msg()))
    elif method == "GetDevices":
        send_frame(sock, json.dumps(make_devices_msg()))
    elif method == "GetActiveDeviceInfo":
        send_frame(sock, json.dumps(make_info_msg()))
    elif method == "GetDefaultBluetoothAdapter":
        send_frame(sock, json.dumps(make_bt_msg()))
    elif method in ("EnableDefaultBluetoothAdapter", "DisableDefaultBluetoothAdapter"):
        state["bluetooth"] = method == "EnableDefaultBluetoothAdapter"
        broadcast(make_bt_msg())
    elif method in ("ConnectDevice", "DisconnectDevice"):
        addr = args.get("address")
        want = method == "ConnectDevice"
        for d in state["devices"]:
            if d["address"] == addr:
                d["connected"] = want
                if want:
                    state["info"]["address"] = d["address"]
                    state["info"]["name"] = d["name"]
                    state["info"]["connected"] = True
                elif state["info"].get("address") == addr:
                    state["info"]["connected"] = False
        send_frame(sock, json.dumps(make_devices_msg()))
        broadcast(make_devices_msg())
        broadcast(make_info_msg())
    elif method == "SetCapabilities":
        caps = args.get("capabilities", {})
        target = state["info"]["capabilities"]
        for name, value in caps.items():
            if name in target and isinstance(value, dict) and "selected" in value:
                target[name]["selected"] = value["selected"]
        broadcast(make_info_msg())
    else:
        send_frame(sock, "")


def handle_client(sock):
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = sock.recv(4096)
            if not chunk:
                return
            request += chunk
        key = ""
        for line in request.decode("latin-1").split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        sock.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("ascii")
        )

        with lock:
            clients.append(sock)

        # Init handshake, mirroring the real daemon.
        send_frame(sock, json.dumps({"init": {"api": 0, "version": "mock-1.0.0"}}))

        while True:
            frame = recv_frame(sock)
            if frame is None:
                break
            opcode, payload = frame
            if opcode == OP_CLOSE:
                break
            if opcode == OP_PING:
                send_frame(sock, payload, OP_PONG)
                continue
            if opcode == OP_TEXT:
                handle_request(sock, payload.decode("utf-8", "replace"))
    finally:
        with lock:
            if sock in clients:
                clients.remove(sock)
        try:
            sock.close()
        except OSError:
            pass


def battery_drain_loop(interval):
    """Simulate the daemon pushing live capability updates."""
    while True:
        time.sleep(interval)
        right = state["info"]["capabilities"]["battery"]["right"]
        if right["status"] == 2:
            right["battery"] = max(0, right["battery"] - 1)
            if state["info"].get("connected"):
                broadcast(make_info_msg())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2020)
    parser.add_argument("--drain-interval", type=float, default=0.0,
                        help="seconds between simulated battery updates (0 disables)")
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(8)
    print(f"mock daemon listening on ws://{args.host}:{args.port}", flush=True)

    if args.drain_interval > 0:
        threading.Thread(target=battery_drain_loop, args=(args.drain_interval,), daemon=True).start()

    try:
        while True:
            client, _ = server.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()


if __name__ == "__main__":
    main()
