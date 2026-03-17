#!/bin/bash
# Install built-in packs to the zipet registry
# Run this after building zipet to populate the pack registry

REGISTRY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zipet/packs/registry"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKS_DIR="$SCRIPT_DIR/../packs"

mkdir -p "$REGISTRY_DIR"

echo "Installing zipet packs to $REGISTRY_DIR"

for pack_file in "$PACKS_DIR"/*.toml; do
    if [ -f "$pack_file" ]; then
        name=$(basename "$pack_file")
        cp "$pack_file" "$REGISTRY_DIR/$name"
        echo "  ✓ $name"
    fi
done

echo "Done! Use 'zipet pack ls' to see available packs."
