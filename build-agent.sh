#!/bin/bash
# Copy the pre-built KTTY agent release binary to the parent directory.
# Run from the workspace directory: ./build-agent.sh
#
# The release binary is pre-compiled inside the container.
# No Rust compiler needed on the host.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/backend/target/release/ktty-agent"
DEST="$SCRIPT_DIR/../ktty-agent"

if [ ! -f "$SRC" ]; then
    echo "Error: Release binary not found at $SRC"
    echo "Build it inside the container first: cd backend && cargo build --release -p ktty-agent"
    exit 1
fi

cp "$SRC" "$DEST"
chmod +x "$DEST"

echo "Copied to: $DEST"
ls -lh "$DEST"
echo ""
echo "Usage: $DEST --relay-url wss://ktty-relay.fly.dev"
