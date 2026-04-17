#!/usr/bin/env bash
#
# deploy-ktty-agent.sh — run ktty-agent against the default (fly.io) relay.
#
# Lives in run-agent/ alongside the pre-built ktty-agent binary. All
# paths are relative to this script's directory.
#
# Usage:
#   ./deploy-ktty-agent.sh                   # prompts for PIN, prod relay
#   KTTY_PIN=12345678 ./deploy-ktty-agent.sh # non-interactive
#
# Override the relay URL via env var:
#   KTTY_RELAY_URL=ws://127.0.0.1:8080/ws ./deploy-ktty-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/ktty-agent"
RELAY_URL="${KTTY_RELAY_URL:-wss://ktty-relay.fly.dev/ws}"

if [[ ! -x "$BIN" ]]; then
    echo "Error: $BIN not found or not executable." >&2
    echo "" >&2
    echo "If you cloned this repo without the prebuilt binary, build it:" >&2
    echo "  (cd \"\$(dirname '$SCRIPT_DIR')/backend\" && cargo build --release -p ktty-agent)" >&2
    echo "  cp \"\$(dirname '$SCRIPT_DIR')/backend/target/release/ktty-agent\" \"$BIN\"" >&2
    echo "  chmod +x \"$BIN\"" >&2
    exit 1
fi

if [[ -n "${KTTY_PIN:-}" ]]; then
    pin="$KTTY_PIN"
else
    printf 'Enter PIN (8+ digits): ' >&2
    stty -echo
    read -r pin
    stty echo
    printf '\n' >&2
fi

if [[ "${#pin}" -lt 8 ]]; then
    echo "PIN must be at least 8 digits (got ${#pin})." >&2
    exit 1
fi

echo "Starting ktty-agent against $RELAY_URL"
exec bash -c "printf '%s\n' '$pin' | exec '$BIN' --relay-url '$RELAY_URL'"
