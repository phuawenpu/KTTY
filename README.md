# KTTY - Secure Mobile Terminal Relay

## Overview
KTTY is a secure mobile terminal emulator built with Flutter that connects to a Linux host agent via an untrusted cloud relay. All terminal data is end-to-end encrypted using post-quantum cryptography (ML-KEM 768 + XChaCha20-Poly1305). The cloud relay is a stateless message forwarder that cannot read or tamper with terminal data.

## Architecture

```
Flutter App  <--WSS-->  Cloud Relay (Fly.io)  <--WSS-->  Linux Agent
  (phone)               (message forwarder)              (PTY + shell)
```

- **Flutter App**: Custom keyboard, terminal emulator (xterm.dart), ML-KEM handshake via Rust FFI
- **Cloud Relay**: Rust/Axum WebSocket relay with room-based routing, auth tokens, stale peer cleanup
- **Linux Agent**: Rust binary that spawns a PTY (via tmux), bridges PTY I/O over encrypted WebSocket

## Core Features
- **Post-Quantum Encryption**: ML-KEM 768 key exchange + XChaCha20-Poly1305 via Rust FFI (flutter_rust_bridge)
- **Custom Programmer Keyboard**: Multi-layer (ABC/123/SYM), swipe drawers, control cluster (Ctrl, Tab, Esc, arrows)
- **Speech-to-Text**: Long-press Space key to dictate (Android speech recognition)
- **Seamless Reconnection**: Agent stays connected to relay across Flutter disconnects; 45s heartbeat timeout detects dead connections; ring buffer replays PTY history on reconnect
- **Local Echo**: Instant keystroke display with 50ms batched send and server echo suppression
- **Pinch Zoom**: Two-finger zoom on terminal
- **Double-Tap Word Capture**: Double-tap a word in terminal output to type it at the cursor

## Running

### Prerequisites
- Flutter SDK (stable channel, Dart 3.11+)
- Rust toolchain (for agent, relay, and Flutter FFI bridge)
- Android device or emulator

### 1. Cloud Relay

Already deployed at `wss://ktty-relay.fly.dev`. To redeploy:

```bash
cd backend
fly deploy
```

To run locally:

```bash
cd backend/relay
cargo run -- 8080
```

### 2. Linux Agent

```bash
# Build
cd backend/agent
cargo build --release

# Run (connects to deployed relay)
./target/release/ktty-agent --relay-url wss://ktty-relay.fly.dev

# Or with a local relay
./target/release/ktty-agent --relay-url ws://localhost:8080
```

The agent prompts for a numeric PIN. Use the same PIN in the Flutter app.

### 3. Flutter App

```bash
# Install dependencies
flutter pub get

# Run debug build on connected device
flutter run --debug --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"

# Build release APK
flutter build apk --release --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"

# Install on specific device
flutter run --release --device-id <DEVICE_ID> --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"
```

### Connection Flow

1. Start the agent on your Linux host — it prints a room ID and waits
2. Open the Flutter app, enter the relay URL (`wss://ktty-relay.fly.dev/ws`) and the same PIN
3. ML-KEM handshake establishes a shared secret; all subsequent traffic is encrypted
4. Terminal session is live — type on the custom keyboard, output appears in real-time

## Project Structure

```
lib/                          Flutter app
  app.dart                    App lifecycle, reconnection
  config/constants.dart       Version, terminal config
  screens/
    dashboard_screen.dart     Connection page (URL + PIN entry)
    terminal_screen.dart      Terminal + keyboard layout
  services/
    crypto/                   Rust FFI crypto (ML-KEM, XChaCha20, Argon2id)
    terminal/                 Terminal I/O, local echo, ring buffer sync
    websocket/                WebSocket connection, handshake, reconnect
  widgets/
    keyboard/                 Custom keyboard (ABC/123/SYM layers, control cluster)
    terminal/                 Terminal container, selection handles, pinch zoom
    clipboard/                Copy/paste/mark buttons
rust/                         Rust FFI bridge crate (ktty_bridge)
backend/
  agent/                      Linux agent (PTY, ML-KEM, encrypted WS bridge)
  relay/                      Cloud relay (Axum, room routing, auth tokens)
  common/                     Shared Rust crate (crypto, message types)
```

## Interface Contract

**Room Join (unencrypted)**
```json
{"action": "join", "room_id": "<SHA-256 of derived key>"}
```

**Encrypted Data Envelope**
```json
{"seq": 1, "type": "pty", "payload": "<Base64 XChaCha20 ciphertext>"}
```

Message types: `pty` (terminal I/O), `resize`, `sync_req`, `sync_warn`, `sys_kill`, `disconnect`
