#!/bin/bash
set -euo pipefail

REPO="Luisgarcav/zipet"
INSTALL_DIR="${ZIPET_INSTALL_DIR:-$HOME/.local/bin}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${CYAN}${BOLD}▸${RESET} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✔${RESET} $1"; }
fail()  { echo -e "${RED}${BOLD}✘${RESET} $1"; exit 1; }

# Detect OS and architecture
detect_target() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux)  os="linux" ;;
        Darwin) os="macos" ;;
        *)      fail "OS not supported: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *)             fail "Architecture not supported: $arch" ;;
    esac

    echo "${arch}-${os}"
}

TARGET="$(detect_target)"
info "Detected platform: ${BOLD}${TARGET}${RESET}"

# Get latest release URL
info "Fetching latest release..."
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/zipet-${TARGET}.tar.gz"

# Download
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading zipet for ${TARGET}..."
if command -v curl &>/dev/null; then
    curl -sfL "$DOWNLOAD_URL" -o "$TMPDIR/zipet.tar.gz" || fail "Download failed. Check if a release exists for ${TARGET}."
elif command -v wget &>/dev/null; then
    wget -q "$DOWNLOAD_URL" -O "$TMPDIR/zipet.tar.gz" || fail "Download failed. Check if a release exists for ${TARGET}."
else
    fail "Neither curl nor wget found. Install one and try again."
fi

# Extract
tar -xzf "$TMPDIR/zipet.tar.gz" -C "$TMPDIR" || fail "Failed to extract archive."

# Install
mkdir -p "$INSTALL_DIR"
mv "$TMPDIR/zipet" "$INSTALL_DIR/zipet"
chmod +x "$INSTALL_DIR/zipet"

ok "Installed zipet to ${BOLD}${INSTALL_DIR}/zipet${RESET}"

# Check if in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    info "⚠  ${INSTALL_DIR} is not in your PATH. Add it with:"
    echo ""
    echo "   echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
    echo ""
else
    ok "zipet is ready! Run ${BOLD}zipet init${RESET} to get started 🐾"
fi
