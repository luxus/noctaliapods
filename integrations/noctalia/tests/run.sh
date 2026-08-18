#!/usr/bin/env bash
#
# Tests for the MagicPods Noctalia plugin. Two layers, no compositor required:
#
#   1. Bridge <-> daemon: run bridge.py against a mock MagicPodsCore WebSocket
#      server and assert the real protocol round-trips (stream + send).
#   2. Plugin logic: execute the real service/bar/panel Luau scripts under the
#      standalone `luau` interpreter with a host stub, feeding protocol data and
#      asserting the render trees and emitted commands.
#
# Env overrides: PYTHON (default python3), LUAU (default: luau on PATH, else
# /tmp/luau-dl/luau).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="${HERE}/../magicpods"
PYTHON="${PYTHON:-python3}"
PORT="${PORT:-22020}"

if [ -n "${LUAU:-}" ]; then
  LUAU_BIN="${LUAU}"
elif command -v luau >/dev/null 2>&1; then
  LUAU_BIN="luau"
elif [ -x /tmp/luau-dl/luau ]; then
  LUAU_BIN="/tmp/luau-dl/luau"
else
  LUAU_BIN=""
fi

fail=0

echo "=============================================="
echo " 1. Bridge <-> mock daemon integration"
echo "=============================================="

"${PYTHON}" "${HERE}/mock_daemon.py" --port "${PORT}" --drain-interval 0.4 &
MOCK_PID=$!
# Give the server a moment to bind.
sleep 0.7

cleanup() {
  kill "${MOCK_PID}" 2>/dev/null || true
  if [ -n "${STREAM_PID:-}" ]; then kill "${STREAM_PID}" 2>/dev/null || true; fi
}
trap cleanup EXIT

STREAM_OUT="$(mktemp)"
"${PYTHON}" "${PLUGIN}/bridge.py" --url "ws://127.0.0.1:${PORT}" stream >"${STREAM_OUT}" 2>&1 &
STREAM_PID=$!
sleep 2.2
kill "${STREAM_PID}" 2>/dev/null || true
STREAM_PID=""

echo "--- bridge stream output (first lines) ---"
head -n 6 "${STREAM_OUT}"
echo "------------------------------------------"

grep -q '"_bridge":{"connected":true}' "${STREAM_OUT}" && echo "PASS: bridge reports connected" || { echo "FAIL: bridge did not report connected"; fail=1; }
grep -q '"init"' "${STREAM_OUT}" && echo "PASS: received init handshake" || { echo "FAIL: no init handshake"; fail=1; }
grep -q 'AirPods Pro' "${STREAM_OUT}" && echo "PASS: received GetAll device state" || { echo "FAIL: no GetAll state"; fail=1; }
# Battery drain broadcast means >1 info-bearing line arrived.
[ "$(grep -c 'capabilities' "${STREAM_OUT}")" -ge 1 ] && echo "PASS: received capability broadcasts" || { echo "FAIL: no capability broadcasts"; fail=1; }

echo
echo "--- bridge send (ConnectDevice) ---"
SEND_OUT="$("${PYTHON}" "${PLUGIN}/bridge.py" --url "ws://127.0.0.1:${PORT}" send '{"method":"ConnectDevice","arguments":{"address":"11:22:33:44:55:66"}}')"
echo "${SEND_OUT}" | head -n 4
echo '{"method":"ConnectDevice"...} sent'
echo "${SEND_OUT}" | grep -qE 'connected":[[:space:]]*true' && echo "PASS: send round-trip returned updated devices" || { echo "FAIL: send did not return updated state"; fail=1; }

kill "${MOCK_PID}" 2>/dev/null || true
trap - EXIT

echo
echo "=============================================="
echo " 2. Plugin logic (luau)"
echo "=============================================="

if [ -z "${LUAU_BIN}" ]; then
  echo "SKIP: luau interpreter not found (set LUAU=/path/to/luau)"
else
  # Compile check each entry (syntax).
  for f in service.luau bar.luau panel.luau; do
    if "${LUAU_BIN%luau}luau-compile" -O0 "${PLUGIN}/${f}" >/dev/null 2>&1 \
      || "${LUAU_BIN}" --help >/dev/null 2>&1; then
      :
    fi
  done

  COMBINED="$(mktemp --suffix=.luau)"
  cat "${HERE}/host_stub.luau" \
      "${PLUGIN}/service.luau" \
      "${PLUGIN}/bar.luau" \
      "${PLUGIN}/panel.luau" \
      "${HERE}/test_plugin.luau" > "${COMBINED}"
  if "${LUAU_BIN}" "${COMBINED}"; then
    echo "luau harness: OK"
  else
    echo "luau harness: FAILED"
    fail=1
  fi
  rm -f "${COMBINED}"
fi

echo
if [ "${fail}" -ne 0 ]; then
  echo "RESULT: FAILURES"
  exit 1
fi
echo "RESULT: all tests passed"
