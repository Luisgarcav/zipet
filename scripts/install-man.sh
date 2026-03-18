#!/usr/bin/env bash
# Install zipet man pages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAN_DIR="${SCRIPT_DIR}/../man"

# Default install prefix
PREFIX="${PREFIX:-$HOME/.local}"
MAN_PREFIX="${PREFIX}/share/man"

install_pages() {
    echo "Installing zipet man pages to ${MAN_PREFIX}/"

    mkdir -p "${MAN_PREFIX}/man1"
    mkdir -p "${MAN_PREFIX}/man5"

    for f in "${MAN_DIR}"/man1/*.1; do
        [ -f "$f" ] || continue
        install -m 644 "$f" "${MAN_PREFIX}/man1/"
        echo "  installed $(basename "$f")"
    done

    for f in "${MAN_DIR}"/man5/*.5; do
        [ -f "$f" ] || continue
        install -m 644 "$f" "${MAN_PREFIX}/man5/"
        echo "  installed $(basename "$f")"
    done

    echo ""
    echo "Done! Make sure ${MAN_PREFIX} is in your MANPATH."
    echo "You can verify with: man zipet"
    echo ""
    echo "If man can't find the pages, add to your shell config:"
    echo "  export MANPATH=\"${MAN_PREFIX}:\$MANPATH\""
}

uninstall_pages() {
    echo "Removing zipet man pages from ${MAN_PREFIX}/"
    rm -f "${MAN_PREFIX}/man1/zipet.1"
    rm -f "${MAN_PREFIX}/man1/zipet-workflow.1"
    rm -f "${MAN_PREFIX}/man1/zipet-pack.1"
    rm -f "${MAN_PREFIX}/man1/zipet-workspace.1"
    rm -f "${MAN_PREFIX}/man5/zipet-snippets.5"
    rm -f "${MAN_PREFIX}/man5/zipet.toml.5"
    echo "Done."
}

case "${1:-install}" in
    install)   install_pages ;;
    uninstall) uninstall_pages ;;
    *)
        echo "Usage: $0 [install|uninstall]"
        echo "  PREFIX=... $0 install   # custom prefix (default: ~/.local)"
        exit 1
        ;;
esac
