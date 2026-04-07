#!/bin/bash
# Build the KTTY agent and copy to parent directory.
# Run from the workspace directory: ./build-agent.sh

set -e

cd "$(dirname "$0")/backend"

echo "Building ktty-agent (debug)..."
cargo build -p ktty-agent

echo "Copying to parent directory..."
cp target/debug/ktty-agent ..

echo "Done: ../ktty-agent"
echo ""
echo "Usage: ./ktty-agent --relay-url wss://ktty-relay.fly.dev"
