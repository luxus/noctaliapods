#!/usr/bin/env bash
#
# Installer for the MagicPods Noctalia plugin and its MagicPodsCore daemon.
#
# It builds the daemon, installs it as a per-user systemd service, and links the
# Luau plugin into Noctalia's local plugin directory so it can be enabled from
# Settings -> Plugins.
#
# Inspired by tomycostantino/omarchpods, adapted for Noctalia v5.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!  ${NC} $*"; }
die() {
  echo -e "${RED}error:${NC} $*" >&2
  exit 1
}

# Repo root = two levels up from this script (integrations/noctalia/install.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLUGIN_SRC="${SCRIPT_DIR}/magicpods"

BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
PLUGIN_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/noctalia/plugins"

[ "$(id -u)" -ne 0 ] || die "do not run this installer as root"

command -v cmake >/dev/null 2>&1 || die "cmake is required to build the daemon"
command -v python3 >/dev/null 2>&1 || warn "python3 not found — the plugin's daemon bridge needs it at runtime"

# --- 1. Build the daemon -----------------------------------------------------
info "Building MagicPodsCore (this downloads and compiles dependencies)…"
BUILD_DIR="${REPO_ROOT}/build"
cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" --parallel "$(nproc 2>/dev/null || echo 2)"

DAEMON_BIN="${BUILD_DIR}/magicpodscore"
[ -x "${DAEMON_BIN}" ] || die "build did not produce ${DAEMON_BIN}"

# --- 2. Install the daemon binary --------------------------------------------
info "Installing daemon to ${BIN_DIR}/magicpodscore"
mkdir -p "${BIN_DIR}"
install -m755 "${DAEMON_BIN}" "${BIN_DIR}/magicpodscore"

# --- 3. Install and start the user service -----------------------------------
info "Installing systemd user service"
mkdir -p "${UNIT_DIR}"
install -m644 "${SCRIPT_DIR}/systemd/magicpodscore.service" "${UNIT_DIR}/magicpodscore.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now magicpodscore.service || warn "could not start the service automatically"
else
  warn "systemctl not found; start ${BIN_DIR}/magicpodscore manually"
fi

# --- 4. Link the plugin into Noctalia ----------------------------------------
info "Linking plugin into ${PLUGIN_DIR}/magicpods"
mkdir -p "${PLUGIN_DIR}"
ln -sfn "${PLUGIN_SRC}" "${PLUGIN_DIR}/magicpods"

cat <<EOF

$(echo -e "${GREEN}=== MagicPods installed ===${NC}")

Next steps in Noctalia:
  1. Open Settings -> Plugins.
  2. Enable "MagicPods" (it is discovered as a local source).
  3. Add the bar widget from the Add-widget picker, or open the panel with:
       noctalia msg panel-toggle steam3d/magicpods:panel

Daemon service:
  status:  systemctl --user status magicpodscore.service
  logs:    journalctl --user -u magicpodscore.service -f
EOF
