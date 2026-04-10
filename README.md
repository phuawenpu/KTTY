# KTTY — Secure Mobile Terminal Relay

> **Repo:** https://github.com/phuawenpu/KTTY  ·  **Live relay:** `wss://ktty-relay.fly.dev/ws`  ·  **PWA:** `https://phuawenpu.github.io/KTTY/`
>
> This README is intentionally exhaustive. It is the **only** persistent
> documentation for this project — everything you need to rebuild from a
> clean checkout, understand every file, debug crypto failures, or pick up
> the project cold months from now is in here. There is no separate wiki,
> no Notion doc, no Slack history. If a fact about this project doesn't
> live in the source tree or in this README, assume it doesn't exist.

KTTY is a post-quantum-encrypted mobile terminal that lets you reach a Linux
shell from your phone over an untrusted relay. The relay (running on Fly.io)
forwards encrypted bytes between phone and host but cannot read or tamper with
them. End-to-end secrecy comes from a fresh ML-KEM-768 (FIPS 203) key
exchange per session, then XChaCha20-Poly1305 for the bulk traffic.

```
┌──────────────────┐    WSS    ┌────────────────┐    WSS    ┌────────────────┐
│  Flutter client  │──────────▶│  Cloud relay   │──────────▶│  Linux agent   │
│  (Android / PWA) │           │   (Fly.io)     │           │  (your host)   │
│   xterm + UI     │◀──────────│ stateless fwd  │◀──────────│  PTY ↔ WS      │
└──────────────────┘           └────────────────┘           └────────────────┘
        │                              │                            │
        │  ML-KEM encapsulate          │  routes by room id only,   │  ML-KEM decapsulate
        │  XChaCha20 enc/dec           │  cannot decrypt anything   │  XChaCha20 enc/dec
        │  HMAC verify (MITM check)    │                            │  HMAC sign
        └──────────────────────────────┴────────────────────────────┘
                       Same Rust ml-kem 0.2 crate on both sides
```

There are three programs in this repo: a **Flutter app** (lib/), a **Linux
agent** (backend/agent/), and a **WebSocket relay** (backend/relay/). They all
share a Rust crypto crate (backend/common/) so the wire formats are guaranteed
to match. There are also two FFI shims that let the Flutter app call the same
Rust crypto: `backend/ffi-crypto/` for native (Android/iOS/desktop, via
`dart:ffi`) and `backend/wasm-crypto/` for the web/PWA build (via
`wasm-bindgen`).

---

## Why this README is so detailed

The Flutter side originally used `package:pqcrypto` for ML-KEM, which
implements an old CRYSTALS-Kyber draft. The Rust agent has always used the
`ml-kem = "0.2"` crate, which implements final FIPS 203. **These two
algorithms are not interoperable** — they produce different shared secrets
for the same inputs. The interop test in `tests/mlkem_interop/` proves this.
The result was a confusing "HMAC verification failed — possible MITM attack"
error during the handshake, even though there was no MITM. The fix was to
make the Flutter app call into the same Rust crate as the agent. The
ffi-crypto and wasm-crypto crates exist for that single reason.

If you ever see HMAC verification failing again, the very first thing to
check is that the Rust crypto on **both sides** is built from the same
`ml-kem` version. Run `cargo test -p ktty-common` — the
`test_mlkem_encapsulate_roundtrip` test pairs `mlkem_encapsulate` against the
agent's `decapsulate` path and will fail loudly if they drift apart.

## Threat model

KTTY is end-to-end encrypted with ML-KEM-768 + XChaCha20-Poly1305. The relay
is fully untrusted. Concretely:

**Protected against**
- A passive observer of the WSS traffic (including the relay operator,
  Fly.io, Cloudflare, your ISP) — sees only ciphertext envelopes and the
  room id; can't read PTY data or recover the session key.
- An active MITM at the relay (or anyone else with relay access) trying to
  swap their own ML-KEM key into the handshake — the agent signs the
  shared secret with HMAC-SHA256 keyed by the Argon2id-PIN-key, which a
  MITM does not have. The Flutter side rejects mismatched HMACs with
  "possible MITM attack".
- An attacker with the published APK or PWA build trying to find baked-in
  secrets — there are none. Both client and server compute the room id and
  session key from the user's PIN; nothing is shipped in the binaries.
- A web XSS that tries to inject its own scripts — the page ships a
  strict CSP (`default-src 'self'`, `script-src 'self' 'wasm-unsafe-eval'
  https://www.gstatic.com`, no `'unsafe-inline'`), so any inline `<script>`
  the attacker tries to inject is silently dropped by the browser. The
  WASM crypto is loaded from a same-origin file (`wasm-loader.js`), not
  inlined. Note: `window._kttyCrypto` is *not* deleted after Flutter
  boots — once the page is open, any code already running on the same
  origin (browser extensions, bookmarklets) can still call into the
  crypto module. The CSP is the real boundary, not the global.
- A bored user typing `ws://` instead of `wss://` — the dashboard URL
  field rejects anything that isn't `wss://`, and the Android manifest
  has `usesCleartextTraffic="false"` so the OS rejects it too.

**NOT protected against**
- Anyone who knows your PIN. The PIN is the only secret. Treat it like a
  password.
- An offline brute-force attacker who has observed your room id and is
  willing to spend CPU on Argon2id. The minimum PIN length is enforced at
  **8 digits** in both the agent and the Flutter dashboard. With Argon2id
  at M=64MB / T=3 / P=4, an 8-digit PIN takes months on a single core and
  ~weeks on a high-end GPU rig — but a 6-digit PIN would take hours.
  *Use long PINs.* The relay no longer logs the room id and the
  `/health` endpoint no longer leaks active room/peer counts.
- A compromised host. If something already has root on the machine
  running `ktty-agent`, it can read the PIN as you type it, snapshot the
  PTY, or replace the binary. KTTY is not a sandbox.
- An attacker with physical possession of an unlocked phone after a
  successful handshake — the session key sits in process memory.
- A user installing a malicious build from somewhere other than the
  source repo. Verify your APK / PWA build originates from a clean
  checkout.

**Defense in depth: relay-level auth tokens.** When a peer joins a room
the relay generates a 256-bit random token (`OsRng`, hex-encoded) and
hands it back. **Every** subsequent text message — including handshake
and boot — must carry that token in an `auth` field, and the relay
constant-time-compares before forwarding. There are no exempt message
types. This is *not* a security boundary against an attacker who has the
PIN (the PIN is the real secret), but it does stop a passive room
squatter from forging handshake material on behalf of an existing peer.

## Security history (v2 — 2026-04-10 audit)

The repo went public on 2026-04-10. A security audit immediately afterward
flagged five real issues, all now fixed in commit history (see
`git log --grep=security` and `git log --grep=Harden`):

- **Relay auth token was forgeable** (`format!("{:016x}{:032x}", id, nanos)`)
  and the relay exempted `action`, `handshake`, and `boot` messages from
  auth checks entirely, meaning an attacker could forge handshake
  material on behalf of any peer slot. **Fix:** 32-byte CSPRNG token,
  constant-time comparison via `subtle`, no exemptions other than the
  initial `join` (which goes through a separate code path with no token
  yet to check).
- **Trivial DoS on the relay** (unbounded mpsc channels, no WS frame size
  cap, no per-message length check). **Fix:** bounded `mpsc::channel(64)`,
  `WebSocketUpgrade::max_frame_size(64 KB).max_message_size(256 KB)`,
  oversized frames rejected before `serde_json::from_str`.
- **Agent printed the user's PIN to stderr.** **Fix:** logs digit count
  only.
- **Cleartext WebSocket allowed on Android** (`usesCleartextTraffic=true`)
  + the Flutter dashboard accepted `ws://`. **Fix:** manifest set to
  `false`, dashboard rejects any URL that doesn't start with `wss://`.
- **PWA had no CSP** — any third-party script could reach the WASM
  crypto exposed on `window._kttyCrypto`. **Fix:** strict `<meta>` CSP
  (`default-src 'self'`, `script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com`,
  `connect-src 'self' https://www.gstatic.com https://fonts.gstatic.com wss://ktty-relay.fly.dev wss://*.fly.dev`,
  `frame-ancestors 'none'`, no `'unsafe-inline'` for scripts). The
  gstatic whitelist is required because Flutter web's canvaskit
  renderer dynamically imports `canvaskit.js` and `canvaskit.wasm`
  from `https://www.gstatic.com/flutter-canvaskit/<engineRevision>/`.
  Because the CSP rejects inline scripts, the WASM crypto loader was
  also moved out of `index.html` into a same-origin
  [`web/wasm-loader.js`](web/wasm-loader.js) module.

Other hardening in the same change set:
- Build artifacts (`*.so`, `*.wasm`) are now built with
  `--remap-path-prefix` so they no longer leak the developer's home
  directory via embedded panic metadata. Run `strings` on them to verify.
- `.gitignore` defensively blocks common secret filenames (`.env*`,
  `*.pem`, `*.key`, `*.keystore`, `credentials.json`,
  `service-account*.json`, `.netrc`, `*.pat`, etc.) so a future
  `git add -A` can't accidentally publish a secret.
- `/health` endpoint no longer returns live room/peer counts.
- Relay no longer logs the joined room id (it's PIN-derived material —
  see threat model).
- **Minimum PIN length 8** enforced on both agent (`backend/agent/src/main.rs`)
  and Flutter dashboard (`lib/screens/dashboard_screen.dart`).

---

## Repository layout (every file)

### Top-level

| Path | Purpose |
|---|---|
| `pubspec.yaml` | Flutter manifest. Direct deps: `xterm`, `web_socket_channel`, `provider`, `speech_to_text`, `cryptography` (Argon2id/XChaCha20/HMAC in pure Dart), `ffi` (for the cdylib bridge). **No** `flutter_rust_bridge` and **no** `pqcrypto` — both were removed when ML-KEM moved to direct FFI. |
| `pubspec.lock` | Locked transitive deps. Regenerated by `flutter pub get`. |
| `analysis_options.yaml` | Dart lints. |
| `.metadata` | Flutter scaffolding metadata (don't edit). |
| `.gitignore` | Ignores Flutter build dirs, Rust `target/`, Android SDK/NDK, escape-sequence junk files left by detached terminals. |
| `build-agent.sh` | Copies the pre-built `backend/target/release/ktty-agent` binary to `../ktty-agent` for distribution. |
| `build-crypto.sh` | **The build script you'll use most.** Cross-compiles `ktty-ffi-crypto` for all four Android ABIs into `android/app/src/main/jniLibs/<abi>/`, and runs `wasm-pack build` for `ktty-wasm-crypto` into `web/wasm/`. Requires Rust + `cargo-ndk` + `wasm-pack` + Android NDK. |
| `README.md` | This file. |

### Flutter app — `lib/`

| Path | Purpose |
|---|---|
| `lib/main.dart` | App entrypoint. Calls `WidgetsFlutterBinding.ensureInitialized()`, then checks `NativeCrypto.isCryptoAvailable`. On native this means the cdylib loaded; on web it means the WASM module initialized in `index.html`. If either fails, shows the `_CryptoErrorApp` instead of the real UI. Locks portrait orientation, enables edge-to-edge, then runs `KttyApp`. |
| `lib/app.dart` | Top-level `MaterialApp`, theme, lifecycle observer for resume/pause (handles seamless reconnect on resume). |
| `lib/config/constants.dart` | App version, build-time flag, terminal sizing (80×24 default), reconnect backoff, ping interval. |
| `lib/models/connection_state.dart` | `enum ConnectionStatus { disconnected, connectingRelay, relayConnected, waitingForAgent, connected }`. |
| `lib/models/message_envelope.dart` | Dart model mirroring `EncryptedEnvelope` from the Rust common crate. |
| `lib/models/viewport_mode.dart` | Portrait vs landscape viewport sizing. |
| `lib/state/session_state.dart` | `ChangeNotifier` holding URL, PIN, status, relay reachability. Provided via `package:provider`. |
| `lib/state/keyboard_state.dart` | Holds the active layer (ABC=0, 123=1, SYM=2), shift/caps state. |
| `lib/state/viewport_state.dart` | Portrait/landscape mode for the terminal layout. |
| `lib/screens/dashboard_screen.dart` | PIN entry + Connect button + relay reachability indicator. The WebSocket URL field is shown only on native (so the user can point at a self-hosted relay) and **hidden on web** — the PWA always uses the default `wss://ktty-relay.fly.dev/ws` from the controller's initial value. On PWA there's a 5-attempt PIN rate limiter with 30s lockout. Both platforms enforce a minimum PIN length of 8 digits and reject any URL that doesn't start with `wss://`. The connection-indicator state on web comes from a real `/health` ping (see `ping_web.dart`); on native it's a `dart:io` HttpClient ping. |
| `lib/screens/terminal_screen.dart` | Terminal page. AppBar layout: logo (in `leading:`), then a `KttyTitle` whose colour reflects connection status, then a small status dot, then action buttons (font −/+, keyboard toggle, smart-invert, **info**, disconnect, rotate). The info button opens a `_StatsDialog` popup that ticks once a second and shows live keystroke RTT (last/avg/min/max over the last 100 samples), traffic counters, session uptime, and build/version. The smart-invert toggle wraps the `TerminalContainer` in a `ColorFiltered` widget with an `invert + hue-rotate(180°)` matrix so white↔black flip while red/green/yellow/blue highlights stay recognisably the same colour. The filter is scoped to the terminal subtree only — the appBar and keyboard stay dark regardless of mode. |
| `lib/screens/ping_native.dart` | Native `HttpClient`-based relay HTTP ping (replaces `wss://` → `https://` and tries `GET /`). |
| `lib/screens/ping_web.dart` | Web reachability probe. Calls `window.fetch` (via `dart:js_interop`) against the relay's `/health` endpoint and returns `true` on a 2xx. The relay must serve `Access-Control-Allow-Origin: *` on `/health` (it does — see `backend/relay/src/main.rs`) and the PWA's CSP `connect-src` must whitelist the relay's https origin. Selected over `ping_native.dart` via conditional import on `dart.library.js_interop`. |
| `lib/services/crypto/native_crypto.dart` | The dispatcher. Conditional import: `native_crypto_web.dart` on web, `native_crypto_ffi.dart` on native. Exposes a single `NativeCrypto` static class so the rest of the app doesn't care which platform it's on. |
| `lib/services/crypto/native_crypto_ffi.dart` | **Native crypto.** Argon2id, XChaCha20-Poly1305, HMAC-SHA256 are pure Dart via `package:cryptography` (those are standardized — no interop risk). `mlkemEncapsulate` calls into `libktty_ffi_crypto.so` via `dart:ffi`. The C ABI is fixed-size (1184-byte input, 1088-byte ct output, 32-byte ss output) so memory management is trivial. |
| `lib/services/crypto/native_crypto_web.dart` | **Web crypto.** All seven crypto functions are forwarded to `window._kttyCrypto.*`, which is set up in `web/index.html` from the WASM module. Uses `dart:js_interop` typed JS bindings. The PWA gets *all* crypto from Rust because Argon2 in pure Dart is too slow under JS, and consolidating in one place avoids any chance of subtle Dart-vs-Rust drift. |
| `lib/services/crypto/pin_utils.dart` | Thin wrapper around `NativeCrypto.deriveKey` and `NativeCrypto.roomId`. |
| `lib/services/crypto/crypto_service.dart` | Per-session encrypt/decrypt — wraps `NativeCrypto` with the established session key. |
| `lib/services/crypto/handshake_service.dart` | ML-KEM encapsulate + HMAC verify, also a thin wrapper over `NativeCrypto`. |
| `lib/services/websocket/websocket_service.dart` | The big one. Connection, handshake, reconnect logic, encrypted send/receive, sequence numbers, auth token handling, sync_req replay on reconnect. Reads `_lastUrl` / `_lastPin` to retry without user input. |
| `lib/services/websocket/ws_connect.dart` | Native WebSocket connect using `dart:io` `WebSocket` (no SSL cert override anymore — relay has a real cert). |
| `lib/services/websocket/ws_connect_web.dart` | Web WebSocket connect using `WebSocketChannel.connect`. Conditional-imported. |
| `lib/services/websocket/message_codec.dart` | JSON encode/decode helpers for the message envelopes. |
| `lib/services/terminal/terminal_service.dart` | Glues `xterm.dart` to the WS service. Local echo prediction (echoes printable keystrokes immediately, suppresses the duplicate when the server replays them), 50ms keystroke batching, ring-buffer sync request after reconnect, plain-text fallback when crypto isn't established. Also defines `TerminalStats`: a rolling-window (default 100 samples) counter of keystroke round-trip latencies plus cumulative bytes-sent / bytes-received / message counters and session-start timestamp. RTT is measured by hooking the local-echo predictor: each `_EchoEntry` carries the predicted-at timestamp, and when the matching byte arrives back from the server we feed `now - sentTimeMs` into the rolling buffer. This gives a true end-to-end keystroke latency measurement. The stats are surfaced to the user by the `_StatsDialog` in `terminal_screen.dart`. |
| `lib/widgets/terminal/terminal_container.dart` | xterm wrapper with pinch zoom (2-pointer gesture), drag-to-select, double-tap word capture. |
| `lib/widgets/terminal/connection_indicator.dart` | Two related widgets sharing one `statusColor(status, relayReachable)` helper: `ConnectionIndicator` is an 8×8 coloured dot, and `KttyTitle` is the word **KTTY** rendered in the same colour. The previous "Connected" / "Disconnected" text label was removed because it overlapped the font-size +/- buttons on a 360-dp portrait phone — the colour-coded title now carries the status instead. Red = disconnected, orange = connecting, yellow = handshake/sync, blue = relay reachable but idle, green = fully connected. |
| `lib/widgets/terminal/selection_handles.dart` | Android-style teardrop selection handles overlay with a Copy button. |
| `lib/widgets/keyboard/custom_keyboard.dart` | The on-screen keyboard. Three layers (ABC, 123, SYM) plus a swipe drawer for arrows/function keys. Sends keys via a callback to `terminal_service`. |
| `lib/widgets/keyboard/keyboard_layer.dart` | One layer of the keyboard — renders rows of keys. |
| `lib/widgets/keyboard/key_button.dart` | Single key — handles tap, long-press, swipe, mic (for speech-to-text on Space). |
| `lib/widgets/keyboard/key_definitions.dart` | The actual key layouts for ABC/123/SYM and the function-key drawer. |
| `lib/widgets/keyboard/control_cluster.dart` | Top row of the in-app keyboard: `Tab Esc Ctrl CAPS ↑ ↓ ← → ⌨`. (Tab and Esc are in this order — Tab gets the leftmost slot because it's the more common key.) The single `CAPS` key replaces the previous `ab`/`Aa` pair (one-shot shift is still available via the up-arrow on the qwerty bottom row). The keyboard-hide icon at the right end is a duplicate of the appBar's keyboard toggle, kept here for thumb-reachability. |
| `lib/widgets/clipboard/clipboard_buttons.dart` | Copy + Paste icon buttons in the keyboard toolbar row. Paste sends text via `sendText` directly (not as fake keystrokes). The previous Mark Start / Mark End buttons (which toggled an explicit selection mode) are gone — xterm's drag-to-select gives the same selection workflow with no extra UI. |
| `lib/mock/mock_ws_server.dart` | In-process mock relay for unit tests. |

### Native cdylib — `backend/ffi-crypto/`

| Path | Purpose |
|---|---|
| `backend/ffi-crypto/Cargo.toml` | Declares `ktty-ffi-crypto` as `cdylib` + `staticlib`. Depends only on `ktty-common`. Edition 2024. |
| `backend/ffi-crypto/src/lib.rs` | Two `extern "C"` functions: `ktty_mlkem_encapsulate(ek*, ct_out*, ss_out*) -> i32` (0 = success, negative = failure) and `ktty_ffi_crypto_version() -> u32` (used by the Dart side as a load-probe). The function takes fixed-size 1184/1088/32-byte buffers so the Dart `dart:ffi` side never has to deal with Rust-allocated memory. |

### WASM module — `backend/wasm-crypto/`

| Path | Purpose |
|---|---|
| `backend/wasm-crypto/Cargo.toml` | Declares `ktty-wasm-crypto` as `cdylib`. Pulls in `wasm-bindgen`, `js-sys`, and `getrandom` with the `js` feature (so the Rust crypto can use `crypto.getRandomValues` from the browser). Excluded from the main workspace (`backend/Cargo.toml` has `exclude = ["wasm-crypto"]`) because it has a different target (wasm32) and dep set. |
| `backend/wasm-crypto/src/lib.rs` | `#[wasm_bindgen]` exports for all seven crypto operations: `deriveKey`, `roomId`, `encrypt`, `decrypt`, `mlkemEncapsulate`, `computeHmac`, `verifyHmac`. The JS-side names are camelCase (via `js_name = ...`) so they match the Dart `@JS('window._kttyCrypto.*')` bindings. `mlkemEncapsulate` returns `ct ‖ ss` concatenated; the Dart side splits the last 32 bytes off as the shared secret. |

### Shared crypto crate — `backend/common/`

| Path | Purpose |
|---|---|
| `backend/common/Cargo.toml` | Pulls in `argon2`, `chacha20poly1305`, `hmac`, `sha2`, `ml-kem = "0.2"`, `rand`. **The single source of truth** for which crypto crate version both ends of the handshake use. |
| `backend/common/src/lib.rs` | `pub mod constants; pub mod crypto; pub mod messages;` |
| `backend/common/src/constants.rs` | `STATIC_SALT`, Argon2 cost parameters (`M=65536`, `T=3`, `P=4`, output 32), `NONCE_LEN = 24`, `MAC_LEN = 16`. The Flutter side hard-codes these same numbers — keep them in sync. |
| `backend/common/src/crypto.rs` | The actual crypto: `derive_key` (Argon2id), `room_id` (hex of derived key), `encrypt`/`decrypt` (XChaCha20-Poly1305 with packed nonce), `compute_hmac`/`verify_hmac` (HMAC-SHA256 with constant-time compare), and **`mlkem_encapsulate`** (the function this whole repo's history pivots around). Includes a `test_mlkem_encapsulate_roundtrip` test that pairs encapsulate against the agent's decapsulate path — run it whenever you touch the crypto. |
| `backend/common/src/messages.rs` | Serde structs for the wire protocol: `JoinMessage`, `HandshakeOffer` (sends ML-KEM public key), `HandshakeReply` (sends ciphertext), `EncryptedEnvelope` (`{seq, type, payload, auth?}`), `BootSignal`. |

### Linux agent — `backend/agent/`

| Path | Purpose |
|---|---|
| `backend/agent/Cargo.toml` | `tokio`, `tokio-tungstenite`, `rustls`, `portable-pty`, `ml-kem`, `clap`, etc. Builds the `ktty-agent` binary. |
| `backend/agent/build.rs` | Stamps `KTTY_BUILD_TIME` into the binary at compile time so the version line includes a build timestamp. |
| `backend/agent/src/main.rs` | CLI entry: reads `--relay-url` (or `KTTY_RELAY_URL` env), prompts for PIN on stdin, derives the Argon2 key, computes room id, then enters the main loop: spawn PTY (via tmux), connect to relay, run a session, on disconnect reconnect (preserving the PTY across drops). |
| `backend/agent/src/pty.rs` | `PtyHandle::spawn_tmux` — spawns `tmux new -s ktty` so the user has a real session manager (lets you detach/reattach without losing state). Provides `read`, `write`, `resize`, `kill`. |
| `backend/agent/src/ring_buffer.rs` | 2 MB ring buffer of recent PTY output bytes plus per-byte sequence numbers. On reconnect the Flutter side sends `sync_req` and the agent replays everything since its last known seq, re-encrypted with the new session key. This is what gives you a "no flicker" reconnect even after the phone has been backgrounded for hours. |
| `backend/agent/src/session.rs` | The brain. Joins room, runs the ML-KEM handshake (send public key, receive ciphertext, decapsulate, send HMAC over the shared secret), then bridges PTY ↔ WebSocket: PTY output → `crypto::encrypt` → relay; relay → `crypto::decrypt` → PTY input. Detects peer disconnect/rejoin, handles `sync_req`, evicts stale state on shell exit. |

### Cloud relay — `backend/relay/`

| Path | Purpose |
|---|---|
| `backend/relay/Cargo.toml` | `axum 0.8` (ws feature), `tokio`, `serde_json`, `futures-util`, `rand` + `hex` (for the CSPRNG auth token), `subtle` (constant-time token compare). |
| `backend/relay/src/main.rs` | Single-file Axum service. Maintains a `HashMap<room_id, Room>` with up to 2 peers per room. On `join` it generates a 256-bit `OsRng` auth token and replies with it. On every subsequent text frame it constant-time-validates the token (no exempt message types — handshake/boot are checked too) and forwards the bytes to the other peer in the room. WebSocket frames are capped at 64 KB and total messages at 256 KB. Per-peer outbound channels are bounded at 64 messages so a stalled writer can't OOM the relay. Has a 60s stale-peer TTL, 30s background eviction, 10s write timeout, pong responses to client pings, and least-active peer eviction when a room hits the cap. The `/health` endpoint returns `{"status":"ok"}` only — no live counts. **Sees only ciphertext, never logs the room id.** |
| `backend/Dockerfile` | `FROM rust:1.94-bookworm AS builder` → builds `ktty-relay` → `FROM debian:bookworm-slim` runtime. Used by `fly deploy`. |
| `backend/fly.toml` | Fly.io config: `app = 'ktty-relay'`, region `sin` (Singapore), `min_machines_running = 1`, `auto_stop_machines = 'off'`, health check on `GET /health`, 256 MB shared CPU. |
| `backend/Cargo.toml` | Workspace manifest: members `common`, `relay`, `agent`, `ffi-crypto`. Excludes `wasm-crypto`. |
| `backend/Cargo.lock` | Locked deps for the whole workspace. |

### Pre-built Rust artifacts (committed)

| Path | What |
|---|---|
| `android/app/src/main/jniLibs/arm64-v8a/libktty_ffi_crypto.so` | aarch64 cdylib (490K) |
| `android/app/src/main/jniLibs/armeabi-v7a/libktty_ffi_crypto.so` | armv7 cdylib (341K) |
| `android/app/src/main/jniLibs/x86_64/libktty_ffi_crypto.so` | x86_64 cdylib (479K, for emulator) |
| `android/app/src/main/jniLibs/x86/libktty_ffi_crypto.so` | i686 cdylib (472K, for old emulators) |
| `web/wasm/ktty_wasm_crypto.js` | wasm-bindgen JS shim (16K) |
| `web/wasm/ktty_wasm_crypto_bg.wasm` | wasm-opt-optimized binary (108K) |

These are committed so a fresh checkout can build the APK and the PWA without
needing the Rust toolchain. Re-run `./build-crypto.sh` after touching anything
in `backend/common/`, `backend/ffi-crypto/`, or `backend/wasm-crypto/`.

### Web shell — `web/`

| Path | Purpose |
|---|---|
| `web/index.html` | Page shell. Holds the strict CSP `<meta>` tag and loads `wasm-loader.js` *before* `flutter_bootstrap.js`. Does not contain any inline scripts (the CSP doesn't permit them). |
| `web/wasm-loader.js` | External WASM loader. Imports `./wasm/ktty_wasm_crypto.js`, calls `init()`, then assigns the module namespace object directly to `window._kttyCrypto` and sets `window._kttyCryptoReady = true`. The `await init()` is at the **top level of an ES module** — that's the load-bearing detail, because top-level await blocks any subsequent `<script>` tag from running, so Flutter's `flutter_bootstrap.js` can't start until the WASM bindings are in place. Without that ordering, Flutter's `main.dart` would call `NativeCrypto.deriveKey` against an empty `window._kttyCrypto` and the resulting key would not match the agent's room id (the user-visible symptom is "Wrong PIN"). This file lives outside `index.html` because the CSP forbids inline scripts. **Also unregisters any old `/KTTY/`-scoped service worker on every page load** — without that proactive cleanup, the Flutter SW happily serves a stale `main.dart.js` even in fresh incognito windows, and visitors get permanently stuck on the previous deploy. |
| `web/manifest.json` | PWA manifest (name, icons, theme, display mode). |
| `web/favicon.png`, `web/icons/Icon-*.png` | App icons (192/512 plus maskable). |

### Android scaffold — `android/`

| Path | Purpose |
|---|---|
| `android/app/build.gradle.kts` | Standard Flutter Gradle setup. No NDK ABI filters → Gradle bundles all four `jniLibs/<abi>/` automatically. |
| `android/app/src/main/AndroidManifest.xml` | Permissions: `INTERNET`, `RECORD_AUDIO` (for speech-to-text). |
| `android/app/src/main/kotlin/com/ktty/ktty/MainActivity.kt` | Standard `FlutterActivity`. |
| `android/app/src/main/res/...` | Launcher icons + launch background. |
| `android/build.gradle.kts`, `android/settings.gradle.kts`, `android/gradle.properties`, `android/gradle/wrapper/gradle-wrapper.properties` | Gradle/Flutter scaffolding. |

### Linux desktop scaffold — `linux/`

Stock Flutter Linux runner. Not the focus of this project but compiles
because the cdylib is built for x86_64 too.

### Tests — `tests/mlkem_interop/`

The standalone interop test that *proved* `package:pqcrypto` and
`ml-kem 0.2` were not interoperable. Kept around as documentation.

| Path | Purpose |
|---|---|
| `tests/mlkem_interop/rust_baseline/src/main.rs` | Rust binary that generates an ML-KEM-768 keypair, encapsulates a shared secret, prints all values as hex. |
| `tests/mlkem_interop/dart_test/bin/dart_test.dart` | Dart program that takes the same key + ciphertext from the Rust side and tries to decapsulate them with `package:pqcrypto`. The shared secrets do not match. The diagnostic prints: *"The Dart pqcrypto package produces different shared secrets than Rust ml-kem... You must use FFI bindings to the same Rust crate."* |

---

## Cryptographic protocol (read this if you touch crypto)

1. **PIN derivation** — both sides run Argon2id over the user PIN with the
   static salt `KTTY STATIC SALT VERSION 1` and parameters
   `M=65536, T=3, P=4, len=32`. The 32-byte output is the *Argon2 key*. Its
   hex encoding is the *room id*. Two devices with the same PIN end up in the
   same room without ever sending the PIN over the wire.
2. **Join** — Flutter sends `{"action":"join","room_id":"<hex>"}` to the
   relay. The relay assigns a peer slot, returns an auth token. The agent
   already joined the same room earlier. The relay only knows room ids and
   tokens — it never sees the Argon2 key or the PIN.
3. **ML-KEM-768 handshake** — the agent generates an ML-KEM-768 keypair,
   sends the encapsulation (public) key as base64. Flutter calls
   `mlkem_encapsulate(ek)` (in Rust, via FFI on native or via WASM on web),
   gets back `(ciphertext, shared_secret)`, sends the ciphertext to the
   agent. The agent calls `decapsulate(ct)` and gets the same shared secret.
4. **HMAC verification** — the agent computes
   `HMAC-SHA256(argon2_key, shared_secret)` and sends it. Flutter recomputes
   it locally and constant-time-compares. If it doesn't match, an attacker
   has tampered with the handshake (or, much more commonly, the two sides
   are running incompatible ML-KEM crates — see the "Why this README is so
   detailed" section above).
5. **Bulk traffic** — every PTY packet is encrypted with
   XChaCha20-Poly1305 keyed by the shared secret. The wire format is
   `nonce(24) ‖ ciphertext ‖ tag(16)` packed into a base64 `payload` field
   inside an `EncryptedEnvelope` JSON object.

The relay is fully untrusted. It can drop packets, reorder them, or inject
its own — none of those break secrecy, only liveness. The HMAC step makes
sure it can't substitute its own handshake material either.

---

## Build prerequisites

**Native Rust toolchain (any host):**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-linux-android armv7-linux-androideabi \
    x86_64-linux-android i686-linux-android wasm32-unknown-unknown
cargo install cargo-ndk wasm-pack
```

**Android NDK:** install via Android Studio's SDK Manager or download from
the NDK page. `build-crypto.sh` reads `$ANDROID_NDK_HOME`. Tested with
NDK 28.2.13676358.

**Flutter SDK:** stable channel, Dart 3.11+. The repo includes a vendored
Flutter SDK at `flutter/` (gitignored) — point `$PATH` at `flutter/bin` if
you don't have one installed system-wide.

**Fly.io CLI** (for relay deploys):

```bash
curl -L https://fly.io/install.sh | sh
fly auth login
```

---

## Building from a fresh clone

```bash
git clone https://github.com/phuawenpu/KTTY.git
cd KTTY

# 1. Rust: build the agent + compile the cdylib + WASM
cargo build --release -p ktty-agent       # → backend/target/release/ktty-agent
./build-crypto.sh                          # → jniLibs + web/wasm

# 2. Flutter: install deps
flutter pub get

# 3. Run tests (highly recommended)
cargo test -p ktty-common                  # includes the ML-KEM roundtrip
flutter analyze                            # warnings only, no errors expected

# 4. Build the APK
flutter build apk --release \
    --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"
# → build/app/outputs/flutter-apk/app-release.apk

# 5. Build the PWA
flutter build web --release \
    --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"
# → build/web/
```

If `./build-crypto.sh` complains about a missing target or cargo-ndk, redo
the rustup steps above. If it complains about `ANDROID_NDK_HOME`, export it:

```bash
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/28.2.13676358
```

---

## Running everything end-to-end

### Step 1 — Cloud relay (already deployed)

A relay is already running at `wss://ktty-relay.fly.dev/ws`. It's free-tier
Fly.io in Singapore. To redeploy after changing `backend/relay/`:

```bash
cd backend
fly deploy
```

`backend/Dockerfile` is set up to copy `common/`, `relay/`, `agent/`, and
`ffi-crypto/` into the build context. The relay binary doesn't actually
depend on `ffi-crypto`, but cargo refuses to load the workspace without
it because it's a workspace member. If you ever add another workspace
member, add a `COPY` line for it too.

To run a relay locally for development:

```bash
cd backend
cargo run --release -p ktty-relay -- 8080
# → listens on ws://localhost:8080/ws
```

### Step 2 — Linux agent on your host

```bash
./backend/target/release/ktty-agent --relay-url wss://ktty-relay.fly.dev/ws
# or use a local relay:
./backend/target/release/ktty-agent --relay-url ws://localhost:8080/ws
# or set via env:
KTTY_RELAY_URL=wss://ktty-relay.fly.dev/ws ./ktty-agent
```

It will print `Enter PIN (8+ digits):`. **Minimum is 8 digits** — the agent
will refuse anything shorter (see threat model). It runs Argon2id (a few
seconds) and confirms the digit count without printing the PIN itself. Then
it spawns a tmux session called `ktty` and waits for a Flutter client to
join.

A pre-built copy of the binary is dropped at `../ktty-agent` (relative to
the workspace) by `./build-agent.sh`.

### Step 3 — Flutter client

**On Android:**

1. Install the APK from `build/app/outputs/flutter-apk/app-release.apk` (or
   run `flutter run --release --device-id <ID>`).
2. Open the app. The dashboard shows the WebSocket URL field
   (pre-filled with `wss://ktty-relay.fly.dev/ws`) and a PIN field.
3. Tap the URL field to confirm/edit, tap the PIN field, type the same
   digits the agent prompted for, hit Connect.
4. ML-KEM handshake runs (a few hundred ms), then the terminal opens.

**On the PWA:**

1. Serve `build/web/` over HTTPS (Fly, GitHub Pages, Netlify, or
   `python -m http.server` on `localhost`).
2. Open it in a modern browser. The page first imports the WASM crypto
   module — if your browser doesn't support WebAssembly, the app shows the
   crypto-error screen instead of the dashboard.
3. Same flow: enter the URL + PIN, hit Connect.

---

## Deploying the PWA to GitHub Pages

The recommended pattern uses a `git worktree` so you don't have to nuke
the working tree of the `main` branch:

```bash
# 1. Build with the right base href
flutter build web --release \
    --base-href "/KTTY/" \
    --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"

# 2. Fetch the existing gh-pages branch and check it out into a worktree
git fetch origin gh-pages:gh-pages
git worktree add /tmp/ktty-gh-pages gh-pages

# 3. Replace its contents with the fresh build, commit, push
cd /tmp/ktty-gh-pages
find . -maxdepth 1 -mindepth 1 -not -name '.git' -exec rm -rf {} +
cp -r /path/to/repo/build/web/. .
git add -A
git commit -m "Deploy PWA"
git push origin gh-pages

# 4. Cleanup
cd -
git worktree remove /tmp/ktty-gh-pages --force
git branch -D gh-pages   # optional — keeps your local branch list tidy
```

Then enable GitHub Pages in repo settings → Pages → branch `gh-pages` → root.

The `--base-href "/KTTY/"` is critical because the site lives at
`phuawenpu.github.io/KTTY/`, not at the domain root. Without it, the app
will 404 on its own assets.

After deploying, hard-reload (Ctrl+Shift+R) once on every device that has
the old PWA cached, or unregister the service worker manually — Flutter's
service worker aggressively caches `main.dart.js` and `index.html`.

---

## Common failure modes

| Symptom | Probable cause | Fix |
|---|---|---|
| `HMAC verification failed — possible MITM attack` | Either (a) Flutter and agent are using different ML-KEM implementations, or (b) someone is genuinely tampering with your handshake. The relay-level auth tokens are constant-time-checked and there are no exempt message types, so a passive room squatter on the relay cannot trigger this. | Confirm `lib/services/crypto/native_crypto_ffi.dart` calls `_mlkemEncapsulate` (the FFI one), not `pqcrypto`. Run `cargo test -p ktty-common test_mlkem`. Run `./build-crypto.sh` and rebuild the APK. |
| `PIN must be at least 8 digits` | You typed a PIN shorter than 8. | Use a longer PIN. The minimum is enforced on both agent and Flutter; see threat model. |
| `Relay URL must use wss://` | You typed `ws://` in the dashboard URL field. | Use `wss://`. Cleartext is rejected because it lets a network attacker observe your room id (PIN-derived material). |
| `Auth token mismatch from peer` in relay logs | A client sent a text message without including the auth token the relay handed back at join time, OR with the wrong token. With the v2 fix this can also indicate that you're running a *new* relay against an *old* agent/client that doesn't include `auth` on handshake messages. | Rebuild and redeploy both ends from the same commit. |
| PWA shows **"Crypto Module Unavailable"** | The WASM loader didn't run. Most common causes: (a) `web/wasm-loader.js` is missing from the deployed `gh-pages` branch — check `curl -I https://phuawenpu.github.io/KTTY/wasm-loader.js`. (b) The CSP in `web/index.html` is blocking `wasm-loader.js` (e.g. you removed `'self'` from `script-src`). (c) `web/wasm/ktty_wasm_crypto.{js,wasm}` is missing — re-run `./build-crypto.sh`. (d) Browser cached the old service worker — hard-reload (Ctrl+Shift+R). | Verify the loader file is reachable, the CSP allows `'self'` for scripts, and `web/wasm/` is populated. Rebuild with `flutter build web --release --base-href "/KTTY/"`. |
| PWA shows **"Wrong PIN"** even with the correct PIN | Either the PWA was built without the load-order fix and is racing the WASM init, OR you're testing against an agent built before the auth-token-on-handshake change. | Confirm `web/wasm-loader.js` uses **top-level `await init()`** (not a fire-and-forget IIFE). Confirm the agent binary was built from commit `8715ffe42` or later (run `--version` if you've added one, or just rebuild). |
| PWA loads but shows blank page | CSP is blocking Flutter's canvaskit renderer. The `script-src` and `connect-src` directives must include `https://www.gstatic.com`, and `font-src` should include `https://fonts.gstatic.com`. | Use the CSP from the current `web/index.html` as a reference. Don't tighten `script-src` to `'self'` only — canvaskit lives on gstatic. |
| PWA "Disconnected" indicator stays red even when the relay is up | The `/health` cross-origin probe failed. Either the relay's `/health` handler is missing the `Access-Control-Allow-Origin` header (regression in `backend/relay/src/main.rs`), or the CSP `connect-src` is missing the relay's https origin, or the relay is genuinely unreachable. | `curl -H "Origin: https://phuawenpu.github.io" -i https://ktty-relay.fly.dev/health` should show `access-control-allow-origin: *`. If not, check `health_handler` in the relay. If the header is fine, check the CSP includes `https://ktty-relay.fly.dev` in `connect-src`. |
| PWA shows the previous deploy after a new push | A stale Flutter service worker is intercepting fetches for `main.dart.js`. The SW killer in `web/wasm-loader.js` runs on every load and unregisters `/KTTY/`-scoped workers, so this should self-heal on the second visit. If you're stuck on the *first* visit after a deploy, open DevTools → Application → Service Workers → Unregister, then reload. | The killer code is in `web/wasm-loader.js` — don't remove it. If you need to deploy without a killer (e.g. testing), the user is one DevTools click away from being able to load the new build. |
| `dart:ffi`: `Failed to load dynamic library "libktty_ffi_crypto.so"` | The cdylib wasn't bundled into the APK for the device's ABI. | Run `./build-crypto.sh` to repopulate `android/app/src/main/jniLibs/` for all 4 ABIs, then rebuild the APK. Confirm with `unzip -l app-release.apk \| grep libktty`. |
| PWA stuck on the "Crypto Module Unavailable" screen | `web/wasm/ktty_wasm_crypto.{js,wasm}` missing or corrupted. | Run `./build-crypto.sh` (wasm-pack section), confirm the files exist, hard-reload the browser to dump the service worker cache. |
| `flutter pub get` complains about `ktty_bridge` | An old `pubspec.yaml` from before the Rust-FFI removal. | The current `pubspec.yaml` has no `ktty_bridge` dep. Check you're on a clean `main`. |
| Agent prints `No agent found` from the Flutter side | Wrong PIN, agent not running, or agent on a different relay URL. | Confirm both sides use the same relay URL and the same PIN digits. The room id is `hex(argon2(pin))` — both must compute to the same string. |
| Connection drops after backgrounding the phone for >2min | Expected. The Flutter app suppresses reconnects in the background to save battery; on resume it does a seamless reconnect via `sync_req` so you shouldn't see a flash. If you do, check `lib/app.dart`'s lifecycle handler. |
| Relay returns 502 | Fly machine is sleeping. `auto_start_machines = true` brings it back on the next request — just retry. |

---

## Development workflow

```bash
# Edit Rust crypto                       → rerun ./build-crypto.sh
# Edit Rust agent or relay               → cargo build --release -p <pkg>
# Edit Flutter Dart code                 → flutter run / hot-reload
# Edit Rust message types in `messages.rs` → also update the Dart models in
#                                            lib/models/message_envelope.dart
#                                            and lib/services/websocket/message_codec.dart
```

The Argon2 parameters in `backend/common/src/constants.rs` and the matching
constants in `lib/services/crypto/native_crypto_ffi.dart` and
`lib/services/crypto/native_crypto_web.dart` (via the WASM crate) **must
stay in sync** — if they drift, room ids won't match and clients won't find
each other.

---

## Versioning

`backend/agent/src/main.rs` has `const VERSION: u32 = 7;`
`lib/config/constants.dart` has `const int kAppVersion = 7;`

Bump these together when you make a wire-protocol change.

---

## Development log — what happened, in order

If you're picking this project up after a long break (or after another
developer), this section is the orientation manual. It explains the state
of the source tree by walking through the changes that produced it. Read
this **before** you start editing.

### Phase 1 — initial Flutter + Rust scaffold (commits up to `cda8cd9ad`)

The first commits stand up a working three-process system: Flutter app
talks to a Rust agent through a Rust relay deployed on Fly. The Rust crypto
crate (`backend/common`) was added with `ml-kem = "0.2"` from day one. The
agent has always used FIPS 203 ML-KEM. The Flutter side used
`package:pqcrypto` for ML-KEM and `package:cryptography` for everything
else.

This *seemed* to work in early testing because the developer was running
the agent and the Flutter client without an HMAC verification step on
every handshake — early commits skipped the HMAC check. Once the HMAC
step was wired in (commit `7e8b0b59c` "Connection reliability overhaul,
terminal UX, ML-KEM interop test"), the developer immediately discovered
the pqcrypto-vs-ml-kem mismatch via the standalone interop test in
`tests/mlkem_interop/`. The interop test's diagnostic output explicitly
recommended switching to FFI bindings to the Rust crate.

Commit `7e8b0b59c` refactored the Flutter side to call `NativeCrypto`
through a `native_crypto.dart` dispatcher — but the actual native
implementation file (`native_crypto_ffi.dart`) was never committed. The
developer's local working tree had a hand-generated bridge that called
into a Rust cdylib, but it was untracked and lost when the workspace
was cleaned.

### Phase 2 — Web/PWA support and the broken pqcrypto detour (commits `1ad6ec7fb` → `eabe6c7df`)

The developer added Flutter web/PWA support. To unblock both targets at
once, they wrote stub `native_crypto_ffi.dart` (throws "FFI not
available") and `native_crypto_web.dart` (calls `window._kttyCrypto.*`
from a yet-to-be-built WASM module), plus a stub `frb_generated.dart`
that imitates `flutter_rust_bridge`.

A few commits later (`7b56a5de7` "Pure Dart crypto for Android, simplify
PWA auth") the developer replaced the stub `native_crypto_ffi.dart` with
a *pure-Dart* implementation that called `package:pqcrypto`'s ML-KEM
directly. This compiled, the APK ran, the dashboard rendered, the user
could connect to the relay — but every handshake failed at HMAC
verification with "possible MITM attack". The shared secrets produced by
Dart pqcrypto (CRYSTALS-Kyber draft) and Rust ml-kem (FIPS 203) were
mathematically different, exactly as the interop test had warned.

### Phase 3 — restore Rust ML-KEM, this time for real (commit `e39f16d71`)

The fix:

1. Added `mlkem_encapsulate` to `backend/common/src/crypto.rs` so the
   agent and the Flutter side can both call it. Wrote a roundtrip test
   that pairs `mlkem_encapsulate` against the agent's `decapsulate` path.
2. Created **`backend/ffi-crypto/`** as a `cdylib` exposing one C ABI
   function `ktty_mlkem_encapsulate(ek*, ct_out*, ss_out*) -> i32`.
   Fixed-size buffers (1184 / 1088 / 32) so there's no Rust-allocated
   memory crossing the FFI boundary.
3. Created **`backend/wasm-crypto/`** as a `wasm-bindgen` crate that
   exposes all seven crypto functions on `window._kttyCrypto.*` for the
   PWA. Excluded from the main workspace (different target, different
   dep set).
4. Rewrote `lib/services/crypto/native_crypto_ffi.dart` so
   `mlkemEncapsulate` calls into `libktty_ffi_crypto.so` via `dart:ffi`.
   The rest of the file (Argon2id / XChaCha20 / HMAC) stayed in pure
   Dart via `package:cryptography` — those are standardized algorithms
   with no draft variants.
5. Wrote **`build-crypto.sh`** that runs `cargo ndk` for all four
   Android ABIs and `wasm-pack build` for the PWA, dropping outputs
   into `android/app/src/main/jniLibs/<abi>/` and `web/wasm/`
   respectively.
6. Removed the now-obsolete `flutter_rust_bridge`, `ktty_bridge`, and
   `pqcrypto` dependencies from `pubspec.yaml`. Deleted the
   `lib/src/rust/`, `rust_builder/`, and `rust/` directories.
7. **Committed the pre-built `.so` and `.wasm` artifacts** so a fresh
   checkout can build the APK and PWA without needing the Rust toolchain
   installed.
8. Verified end-to-end with `cargo test -p ktty-common` (the ML-KEM
   roundtrip test passes).

### Phase 4 — security audit and hardening (commit `8715ffe42`)

The repo went public. An immediate security audit (driven by Claude)
found five real issues. All fixed in commit `8715ffe42`:

1. **Forgeable relay auth token + auth-check exemptions for
   `handshake`/`boot`/`action`** → CSPRNG token via `OsRng`,
   constant-time compare via `subtle`, no exempt message types other
   than the very first `join`. Both agent and Flutter now attach the
   relay-issued auth token to handshake messages.
2. **Trivial relay DoS** (unbounded mpsc, no WS frame size cap, no
   per-message length check) → bounded `mpsc::channel(64)`,
   `WebSocketUpgrade::max_frame_size(64 KB).max_message_size(256 KB)`,
   oversized frames rejected before parsing. `/health` endpoint
   stripped to `{"status":"ok"}`.
3. **Agent printed PIN to stderr** → digit count only.
4. **Cleartext WebSocket allowed on Android + Flutter accepted `ws://`**
   → manifest set `usesCleartextTraffic="false"`, dashboard rejects any
   URL not starting with `wss://`. Minimum PIN length 8 enforced on
   both ends to make offline cracking of the room id infeasible.
5. **PWA had no CSP** — any third-party script could reach the WASM
   crypto on `window._kttyCrypto`. Added a strict `<meta>` CSP tag,
   `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
   The first cut also wrapped the global with `Object.freeze` and used
   a fire-and-forget IIFE to load the WASM — both turned out to be
   bugs (see Phase 5).

Plus build hardening: `build-crypto.sh` sets `RUSTFLAGS=--remap-path-prefix=...`
so committed `.so`/`.wasm` artifacts no longer leak the developer's home
directory. `.gitignore` defensively blocks common secret filenames so a
future `git add -A` can't accidentally publish a `.env` or keystore.

### Phase 5 — PWA fallout fix-ups (commits `6f727b3cd`, `dcdf8b3db`, `775a6954c`)

Phase 4 broke the PWA in three different ways. Each had to be debugged
in turn against the live deployment, because none of them showed up
in the local `flutter build web` (the build always succeeded — it was
runtime behaviour that was wrong).

1. **WASM load order race** (`6f727b3cd`). The original `index.html`
   used top-level `await loadCrypto()`, which blocks subsequent
   `<script>` tags from running. The Phase 4 rewrite replaced it with
   a fire-and-forget `(async () => { ... })()` IIFE. That meant
   `flutter_bootstrap.js` could (and did) start running before the
   WASM module had bound itself onto `window._kttyCrypto`. When
   Flutter's `main.dart` called `NativeCrypto.deriveKey` during the
   race window, it got back garbage — the agent and PWA computed
   different room ids and the user saw "Wrong PIN" with a correct
   PIN. Restored the top-level `await` pattern. Also dropped the
   `Object.freeze` wrapper at the same time — copying wasm-bindgen
   exports onto a wrapper object can produce subtly wrong behaviour
   because the bindings rely on the module-namespace identity.
2. **CSP blocked Flutter's canvaskit renderer** (also `6f727b3cd`).
   Flutter web's canvaskit renderer dynamically imports
   `canvaskit.js` and fetches `canvaskit.wasm` from
   `https://www.gstatic.com/flutter-canvaskit/<engineRevision>/`,
   and may fall back to fonts on `https://fonts.gstatic.com`. The
   original CSP had `'self'` only — both blocked. Whitelisted
   `https://www.gstatic.com` in `script-src`/`connect-src` and
   `https://fonts.gstatic.com` in `font-src`. Added `blob:` to
   `worker-src` for canvaskit's web worker.
3. **CSP blocked the inline WASM loader** (`775a6954c`). Even with
   the gstatic whitelist and the load-order fix, the live PWA still
   showed "Crypto Module Unavailable". Reason: the WASM loader was an
   inline `<script type="module">` block. The CSP has no
   `'unsafe-inline'` for `script-src`, so the browser silently
   refused to execute it. Moved the loader into a same-origin
   `web/wasm-loader.js` file (covered by `'self'`) and reference it
   from `index.html`. This is the file structure now.

Plus a Dockerfile fix in `dcdf8b3db`: the relay's Dockerfile only
copied `common/`, `relay/`, and `agent/` into the build context, but
the workspace now declares `ffi-crypto/` as a member, so cargo failed
to load the workspace at all. Added `COPY ffi-crypto/ ./ffi-crypto/`
to the Dockerfile. The relay binary doesn't depend on `ffi-crypto`,
but cargo needs the manifest present.

### Phase 6 — public deployment (live as of this writing)

- Relay redeployed via `flyctl deploy` from `backend/` to
  `ktty-relay.fly.dev`. Image
  `registry.fly.io/ktty-relay:deployment-01KNV63BZPQ2C3F266FD60SNDT`,
  26 MB. Health check live: `curl https://ktty-relay.fly.dev/health`
  returns `{"status":"ok"}`. This deployment has the CSPRNG auth
  tokens, no message-type exemptions, bounded channels, 64 KB frame
  cap, and the trimmed `/health` endpoint.
- PWA redeployed to GitHub Pages. The `gh-pages` branch holds the
  output of `flutter build web --release --base-href "/KTTY/"` plus
  the `wasm-loader.js` and the rebuilt WASM. Live at
  https://phuawenpu.github.io/KTTY/.
- The root `main` branch has all source changes committed. The
  repo's `tests/mlkem_interop/` test passes.
- The agent binary at `backend/target/release/ktty-agent` is the
  build that includes the auth-token-on-handshake change. Run it
  with `--relay-url wss://ktty-relay.fly.dev/ws` (or set the
  `KTTY_RELAY_URL` env var). Use a PIN of 8 or more digits.

### Phase 8 — UI polish, PWA UX, and the long tail of CDN/SW caching

The PWA was technically working after Phases 5–6 but had a string of
small UX problems that needed cleanup before it could be considered
shippable. All fixed in this batch:

1. **Top app bar overflowed by 5px** on a 360-dp portrait phone.
   Reduced the `KTTY` title font (17 → 13), the logo (22 → 18), and
   the connection-indicator text (13 → 10) plus dot (8 → 6). Tightened
   inter-element spacing.
2. **Control cluster row overflowed by 29px**. Three changes that net
   to no change in button count but eliminate the overflow:
   - Collapsed the separate `ab` (one-shot shift) and `Aa` (caps lock)
     buttons into a single `CAPS` toggle. The bottom-row `↑` on the
     qwerty layer is still the one-shot shift if you only need one
     capital, so nothing was lost.
   - Moved the keyboard-hide button up out of the toolbar row into
     the control cluster, taking the slot freed by the merge.
   - Added a `_buildIconKey` helper for icon-only keys.
3. **Removed Mark Start / Mark End buttons** from the clipboard row
   in the keyboard toolbar. xterm's drag-to-select gives the same
   selection workflow without an explicit marking mode. Copy + Paste
   stay.
4. **Hid the WebSocket URL field on the PWA** dashboard. The field
   only renders when `!kIsWeb`, so the native APK still shows it
   (for self-hosted relays) and the PWA only shows the PIN field.
   The default `wss://ktty-relay.fly.dev/ws` is still held in the
   controller's initial value.
5. **Connection indicator on PWA was always red** because
   `lib/screens/ping_web.dart` was a stub that returned `true` and
   `_pingRelay()` was gated behind `!kIsWeb`. Now `ping_web.dart`
   does a real `window.fetch` against `<relay>/health` via
   `dart:js_interop`, the gate is dropped, and the relay's `/health`
   handler in `backend/relay/src/main.rs` returns
   `Access-Control-Allow-Origin: *` so the cross-origin probe
   succeeds. CSP `connect-src` was also widened to include
   `https://ktty-relay.fly.dev` and `https://*.fly.dev` (the
   `wss://` entries were already there for the actual session).
6. **Stale Flutter service worker** kept serving the previous build's
   `main.dart.js` even in fresh incognito windows. Added a SW killer
   to `web/wasm-loader.js` that runs on every page load and
   unregisters any `/KTTY/`-scoped service worker. Flutter's loader
   then re-registers a fresh one against the latest assets. One
   extra round-trip on first paint, no more "stuck on stale build"
   failures.

### Phase 9 — smart-invert "light mode" terminal toggle

Implemented the smart-invert toggle that had been sketched as a future
plan in the README. `lib/screens/terminal_screen.dart` now carries a
`bool _invertedTheme` plus a static `_smartInvertMatrix` and a tiny
`_maybeInvert(child)` helper that conditionally wraps any child in a
`ColorFiltered`. Both `TerminalContainer` build sites (the
keyboard-visible and keyboard-hidden branches) go through that
helper, and there's a new `IconButton` in the appBar between the
keyboard toggle and the disconnect button. Tap it to flip between
dark and light terminal backgrounds; ANSI colours stay
recognisable because the matrix composes `invert(1)` with
`hue-rotate(180°)` (the same trick CSS dark-mode shims use).

The actual matrix coefficients come from the W3C `hue-rotate`
spec with sRGB luma weights (R=0.213, G=0.715, B=0.072) at θ=180°,
composed with a `1 - x` invert and the constant column scaled to
Flutter's 0–255 colour-channel space. White exactly maps to black
and black exactly maps to white; saturated reds/greens/blues
shift slightly in luminance but remain unambiguously their original
hue.

### Phase 10 — header de-clash, status-coloured title, stats popup, Tab/Esc swap

Three independent UI changes that all landed in the same commit
(`da51c1ed2`):

1. **Header overlap fix.** On a 360-dp portrait phone the font-size
   +/- buttons in the appBar were overlapping the long
   "Connected" / "Disconnected" text label that lived next to the
   KTTY title. Two changes resolved this without losing any
   information:
   - Removed the text label entirely from `ConnectionIndicator`. It
     is now just an 8×8 colour dot.
   - Made the `KTTY` title text *itself* carry the connection
     status, by colouring it with the same `statusColor()` helper
     the dot uses (red disconnected → orange connecting → yellow
     handshake/sync → blue relay reachable → green connected). Two
     widgets, `ConnectionIndicator` and the new `KttyTitle`, both
     live in `lib/widgets/terminal/connection_indicator.dart`.
   - The KTTY logo image moved out of the title row into the
     AppBar's `leading:` slot so the title sits flush left, freeing
     a few extra pixels of action-row real estate.

2. **Session stats popup.** Added an `Icons.info_outline` button to
   the appBar between the smart-invert toggle and the disconnect
   button. Tapping it opens `_StatsDialog`, a modal that ticks once
   a second and shows live keystroke RTT (last/avg/min/max over the
   last 100 samples), traffic counters (bytes + messages), and
   session metadata (status, uptime, build, version).

   The latency tracking is finally correct. The previous code in
   `terminal_service.dart` had a `_pendingTimestamps` map that tried
   to correlate by sequence number, but the agent's outgoing seq
   numbers don't line up with the client's input seq numbers, so
   it was effectively measuring noise. The new approach hooks into
   the existing local-echo predictor: each `_EchoEntry` carries the
   timestamp at which we predicted the echo, and when the matching
   byte arrives back from the server we feed `now - sentTimeMs`
   into the rolling buffer. This is true end-to-end latency from
   the moment the user presses a key to the moment that exact byte
   echoes back through `flutter → relay → agent → bash → agent →
   relay → flutter`. Caveat: only printable ASCII (0x20–0x7E) is
   measured because only those bytes pass through the local-echo
   predictor; control sequences like Tab/Esc/arrows are not
   timed.

3. **Tab/Esc swap in the control cluster.** Per the user's
   preference, Tab gets the leftmost slot in the control cluster
   row because it's the more common key. New row:
   `Tab Esc Ctrl CAPS ↑ ↓ ← → ⌨`.

### Phase 11 — picking up where this left off

Future work is in the [Outstanding work](#outstanding-work--known-limitations)
section below. The two big-ticket items are an HKDF-based key separation
(audit M2, requires a coordinated v3 wire-format bump) and per-IP
connection limits on the relay (audit L4).

---

## Build environment expectations

This repo was developed on a Fedora 43 host with the following layout
(none of these paths are baked into the repo — they're just where the
developer happened to install things):

| Tool | Where it lived | Notes |
|---|---|---|
| Flutter SDK | `flutter/` inside the repo (gitignored) | Stable channel, Dart 3.11+. You can use a system-installed Flutter; the vendored copy is just convenience. |
| Rust toolchain | `~/.rustup/toolchains/stable-x86_64-unknown-linux-gnu` | Installed via `rustup`. Rust 1.85+ is required for edition 2024. |
| Android NDK | `~/Android/Sdk/ndk/28.2.13676358` | Installed via Android Studio's SDK Manager. Set `$ANDROID_NDK_HOME` to this when running `build-crypto.sh`. |
| `cargo-ndk`, `wasm-pack` | `~/.cargo/bin/` (or this repo's `.cargo/bin/`) | Both are `cargo install`-able. |
| Android SDK + build-tools | `~/Android/Sdk/` | Needed for the actual `flutter build apk` step. Not needed for `build-crypto.sh`. |

The developer originally had **no Rust toolchain on the host machine**
when this project started — the Rust agent and relay were built inside a
Docker container (see `backend/Dockerfile`). The pre-built `ktty-agent`
binary was then copied out via `build-agent.sh`. After the security work
in Phases 3 and 4, the developer installed Rust on the host and now
builds everything locally. Either approach works — what matters is that
the binary on disk in `backend/target/release/ktty-agent` matches the
source tree.

### Pushing to GitHub

This repo lives at `https://github.com/phuawenpu/KTTY.git`. There's no
SSH key configured on the dev machine — pushes go over HTTPS. The
recommended setup:

```bash
gh auth login   # one-time, sets up a credential helper
git push origin main
```

If you don't have `gh` and just have a Personal Access Token, the
one-shot way to push without configuring a credential helper is:

```bash
git push https://USERNAME:TOKEN@github.com/phuawenpu/KTTY.git main
```

Be aware that the token ends up in your shell history. Rotate it
afterwards or use a credential helper instead.

---

## Outstanding work / known limitations

Items left over from the 2026-04-10 security audit and subsequent
PWA work, ranked by priority. Each entry is sized to be picked up
cold next session — the goal, the files to touch, the steps, and
the verification are all written out so you don't have to
reconstruct context.

**Priority key:**
- **P0** — Security gap or trivial high-impact fix. Do soon.
- **P1** — Crypto hygiene or quality work that should ship before
  any "v3" wire-format bump.
- **P2** — Polish, observability, refactors. Pick up when bored or
  when something else forces you back into the file.

### P0 — do these soon

#### 1. Add a `SECURITY.md` with a disclosure contact (audit hygiene)

**Goal:** Make it possible for a security researcher who finds a
vulnerability in KTTY to report it to you privately instead of
opening a public GitHub issue. Cheapest item on the list — about
five minutes of work.

**Files:** new file `SECURITY.md` at the repo root.

**Steps:**
1. Create `SECURITY.md` with these sections:
   - **Supported versions** — single line: only the `main` branch
     is supported.
   - **Reporting a vulnerability** — give an email address (or a
     GitHub Security Advisory link, see
     `https://github.com/phuawenpu/KTTY/security/advisories/new`)
     and ask for 7 days before disclosure.
   - **Threat model** — link to the existing "Threat model" section
     of `README.md`.
   - **Out of scope** — list things that are explicitly *not* bugs:
     short PINs are crackable offline, the relay can drop traffic,
     malicious clients with a valid PIN can do anything bash allows,
     etc. Pull bullets straight from the README's "NOT protected
     against" list.
2. In `README.md`, add a one-line link from the "Threat model"
   section to `SECURITY.md`.
3. Enable the GitHub Security Advisories feature on the repo
   (Settings → Security → Advisories → Enable).

**Verify:** Open `SECURITY.md` on the GitHub web UI; you should
see a "Report a vulnerability" button appear automatically.

---

#### 2. Per-IP connection limits on the relay (audit L4)

**Goal:** Stop a single attacker from opening thousands of
WebSocket upgrades and exhausting the Fly VM's file descriptors
or memory before they've even joined a room. The relay today has
no per-IP cap at all — only the bounded mpsc channels and frame
size cap, both of which kick in *after* the upgrade.

**Files:** `backend/relay/src/main.rs`,
`backend/relay/Cargo.toml`.

**Steps:**
1. Add `dashmap = "6"` to `backend/relay/Cargo.toml` (or
   `tower = { version = "0.5", features = ["limit"] }` if you
   prefer the middleware approach — both work, dashmap is
   simpler to reason about).
2. **Approach A — manual per-IP counter (recommended):**
   ```rust
   use dashmap::DashMap;
   use std::net::IpAddr;
   use std::sync::atomic::{AtomicU32, Ordering};

   const MAX_CONNS_PER_IP: u32 = 8;

   type ConnLimits = Arc<DashMap<IpAddr, AtomicU32>>;
   ```
   Pass it through `with_state(...)` alongside the existing
   `RoomMap`. In `ws_handler`, extract the client IP from the
   `ConnectInfo<SocketAddr>` extractor (Axum gives you this if
   you wire it up at `axum::serve(...).into_make_service_with_connect_info::<SocketAddr>()`).
   Increment the counter on accept; reject the upgrade with a
   `503` if the count is already at the cap; decrement in a
   guard-on-drop wrapper inside `handle_socket`.
3. **Approach B — `tower::limit::ConcurrencyLimitLayer`:** simpler
   wiring (just `.layer(...)` on the Router), but it's a *global*
   concurrency cap, not per-IP. Use only as a stopgap.
4. Pick a reasonable cap. 8 connections per IP is generous (one
   for the active session + a few for reconnect races) but blocks
   a thousands-of-connections attack.
5. Update the README's threat-model section to mention the new
   limit.

**Verify:** Locally run `cargo run -p ktty-relay -- 8080`. From
another terminal, open 10 connections in parallel:
```bash
for i in $(seq 1 10); do
  websocat ws://localhost:8080/ws &
done
wait
```
The first 8 should connect; connections 9 and 10 should be
rejected at the upgrade. Check the relay log for the rejection
messages.

**Caveat:** Behind Fly's proxy, the perceived client IP is the Fly
edge IP, not the real client. You probably want to look at the
`Fly-Client-IP` header (Fly's documented forwarded-for header)
instead of the TCP socket address. Check
`https://fly.io/docs/networking/request-headers/` for the exact
header name when implementing.

---

#### 3. HKDF-based key separation (audit M2)

**Goal:** Today the same Argon2id-derived 32-byte key is used as
the room id (visible to the relay), the XChaCha20-Poly1305
encryption key, AND the HMAC-SHA256 key for the ML-KEM
verification step. Textbook key-separation violation. Not
directly exploitable — HMAC-SHA256 and XChaCha20 are independent
primitives — but it means an offline crack of the PIN reveals the
encryption key directly. Splitting via HKDF gives proper domain
separation.

**Files:** `backend/common/src/crypto.rs`,
`backend/common/src/constants.rs`,
`backend/agent/src/main.rs`,
`backend/agent/src/session.rs`,
`lib/services/crypto/native_crypto_ffi.dart`,
`backend/wasm-crypto/src/lib.rs`,
`lib/services/crypto/pin_utils.dart`.

**The new derivation:**
```
master       = Argon2id(pin, STATIC_SALT, m=64MB, t=3, p=4, len=32)
encrypt_key  = HKDF-SHA256-Expand(master, info=b"ktty-encrypt-v8", L=32)
mac_key      = HKDF-SHA256-Expand(master, info=b"ktty-mac-v8",     L=32)
room_key     = HKDF-SHA256-Expand(master, info=b"ktty-room-id-v8", L=32)
room_id      = hex(room_key)
```

**Steps:**
1. **Pick the HKDF crate.** `hkdf = "0.12"` is the standard Rust
   crate (already a transitive dep of several others in the
   workspace). On the Dart side, `package:cryptography` already
   provides `Hkdf`.
2. **Add a new function to `backend/common/src/crypto.rs`:**
   ```rust
   pub struct DerivedKeys {
       pub master: [u8; 32],
       pub encrypt: [u8; 32],
       pub mac: [u8; 32],
       pub room_key: [u8; 32],
       pub room_id: String,
   }

   pub fn derive_keys(pin: &str) -> Result<DerivedKeys, CryptoError> {
       let master = derive_key(pin)?;
       let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(None, &master);
       let mut encrypt = [0u8; 32];
       let mut mac = [0u8; 32];
       let mut room_key = [0u8; 32];
       hkdf.expand(b"ktty-encrypt-v8", &mut encrypt).unwrap();
       hkdf.expand(b"ktty-mac-v8",     &mut mac).unwrap();
       hkdf.expand(b"ktty-room-id-v8", &mut room_key).unwrap();
       let room_id = hex::encode(room_key);
       Ok(DerivedKeys { master, encrypt, mac, room_key, room_id })
   }
   ```
   Add a roundtrip test for it.
3. **Agent side** (`backend/agent/src/main.rs` and
   `backend/agent/src/session.rs`): replace `derived_key` with
   `derived_keys: DerivedKeys`. Use `derived_keys.encrypt` for
   `crypto::encrypt`/`decrypt`, `derived_keys.mac` for
   `compute_hmac`/`verify_hmac`, and `derived_keys.room_id` for
   the join.
4. **Flutter native side** (`native_crypto_ffi.dart`): mirror the
   Rust HKDF derivation in pure Dart via `package:cryptography`'s
   `Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(...)`.
   Expose the same `DerivedKeys`-shaped record. Update
   `pin_utils.dart` to return the record.
5. **Flutter web side**: add `deriveKeys` to
   `backend/wasm-crypto/src/lib.rs` exporting the same function
   from `ktty-common`. Update `native_crypto_web.dart` to call it.
6. **Update `EncryptedEnvelope` consumers**: `crypto_service.dart`
   and `handshake_service.dart` need to know which subkey to use.
7. **Bump versions** in lockstep:
   - `backend/agent/src/main.rs` → `const VERSION: u32 = 8;`
   - `lib/config/constants.dart` → `const int kAppVersion = 8;`
8. **Pre-deployment**: this is a breaking wire-format change. Old
   client + new agent (or vice versa) will compute different
   room IDs and fail to find each other. Plan a coordinated
   release: redeploy the relay (no change), redeploy the agent on
   every host, then push the new APK and PWA.

**Verify:**
1. `cargo test -p ktty-common` — the new `derive_keys` test must
   pass and the existing roundtrip tests must still pass.
2. End-to-end: on a fresh install, connect with a known PIN. The
   room id should be different from the v7 derivation (because
   the HKDF info string is different), but Flutter and agent
   should still meet because both compute the same new value.
3. Run `cargo build --release -p ktty-agent` and
   `./build-crypto.sh` to refresh all artifacts.

**Caveat:** Don't reuse the v7 `STATIC_SALT` constant if you ever
want to retire v7 entirely — bump it to `KTTY STATIC SALT VERSION 2`
so that v7 and v8 PINs are *different* derivations even with the
same input. This is overkill for KTTY's threat model but good
hygiene.

---

#### 4. Mandatory URL-encrypt flow (audit H2 follow-up)

**Goal:** The agent already has a `--encrypt-url` mode that produces
a hex token sealing the relay URL with the user's PIN. Today it's
optional and the dashboard accepts a free-form `wss://` URL,
which means a user who's been socially engineered into typing a
malicious URL hands their room id to a MITM. Make the encrypted
URL the default flow; the free-form field becomes an "advanced"
option.

**Files:** `backend/agent/src/main.rs`,
`lib/screens/dashboard_screen.dart`,
`lib/services/websocket/websocket_service.dart`,
`lib/services/crypto/pin_utils.dart`.

**Steps:**
1. **Agent side**: confirm `--encrypt-url` already produces a
   hex-encoded `crypto::encrypt(derived_key, relay_url)`. The
   user runs it once with their PIN to produce a token they can
   paste into the PWA / APK.
2. **Flutter side**: change the dashboard to show two fields:
   - Default: a single "Connection token" field (the encrypted URL
     hex).
   - Behind an "Advanced" expansion: a free-form "Relay URL" + PIN
     pair, the existing flow.
3. **Decryption in `websocket_service.dart`**: when the user
   provides a token, derive the key from the PIN, decrypt the
   token via `NativeCrypto.decrypt(derivedKey, hexDecode(token))`,
   and use the resulting URL string as the WS endpoint. On
   decryption failure, surface a clear error ("Wrong PIN or
   corrupted token") instead of progressing to the connect.
4. **Dashboard validation**: token must be a valid hex string
   long enough to contain at least the nonce + tag (24 + 16 = 40
   bytes = 80 hex chars).
5. **Update README + dashboard help text** to explain the new
   default flow.

**Verify:**
1. `./ktty-agent --encrypt-url --relay-url wss://ktty-relay.fly.dev/ws`
   then enter a PIN. It prints a hex token.
2. Paste the token + same PIN into the new dashboard token field.
   Connect should succeed.
3. Paste the token + a wrong PIN. Should fail with the friendly
   error.
4. The "Advanced" expansion should still allow the old free-form
   flow for self-hosted relays.

**Caveat:** This adds a manual copy-paste step every time the
user installs the app. Mitigate with a QR code: render the token
as a QR on the agent's stdout (use the `qrcode` Rust crate), and
add a QR scanner button to the dashboard (use
`mobile_scanner` Flutter package). That's a follow-up — ship the
plain token first.

---

### P1 — should ship before any v3 release

#### 5. `sync_req` rate limit (audit M5)

**Goal:** A peer can repeatedly send `sync_req` to the agent,
forcing it to re-encrypt up to 2 MB of PTY history each time.
This is inside an authenticated session so it's not a pre-auth
DoS, but it's still a free amplification primitive for any
attacker who has the PIN. Bound it.

**Files:** `backend/agent/src/session.rs`.

**Steps:**
1. Add `last_sync_req_at: Option<tokio::time::Instant>` to the
   bridge state in `session.rs`.
2. In the message handler that recognises `sync_req`, check the
   delta from the previous sync request:
   ```rust
   const MIN_SYNC_INTERVAL: Duration = Duration::from_secs(5);
   if let Some(last) = last_sync_req_at {
       if last.elapsed() < MIN_SYNC_INTERVAL {
           eprintln!("[agent] Dropping rate-limited sync_req");
           continue; // skip the replay
       }
   }
   last_sync_req_at = Some(tokio::time::Instant::now());
   ```
3. Also add a sanity cap on the requested `last_seq`: if the
   client asks for a replay starting at `last_seq < current_seq -
   ring_buffer_size`, reply with an error envelope instead of
   silently sending nothing.

**Verify:** From a connected client, fire `sync_req` twice in
quick succession. The second one should be dropped per the agent
log line.

**Caveat:** The legitimate client only sends `sync_req` once on
reconnect (see `terminal_service.dart#_requestSync`), so a 5-
second cap is conservative — reconnects don't happen that fast in
practice. If you ever add a "force resync" button to the UI, make
sure it doesn't violate the cap.

---

#### 6. Constants drift detection (Rust ↔ Dart)

**Goal:** Make it impossible for the Argon2 / XChaCha20 / HMAC
parameters to silently diverge between the Rust and Dart sides of
the protocol. Today they're hard-coded literals in two places;
nothing fails loudly if they get out of sync. A drift would
silently produce different room IDs and the user would just see
"No agent found" with no clue why.

**Files:** `backend/common/src/constants.rs`,
`lib/services/crypto/native_crypto_ffi.dart`,
`backend/wasm-crypto/src/lib.rs` (already pulls from common, so OK),
new file `tests/constants_drift_test.dart` or extension to existing
`backend/common/src/crypto.rs` tests.

**Constants that must stay in sync:**
- `STATIC_SALT` (string `"KTTY STATIC SALT VERSION 1"`)
- `ARGON2_M_COST` (65536)
- `ARGON2_T_COST` (3)
- `ARGON2_P_COST` (4)
- `ARGON2_OUTPUT_LEN` (32)
- `NONCE_LEN` (24)
- `MAC_LEN` (16)

**Steps:**
1. **Cleanest approach** — move the Dart-side constants out of
   `native_crypto_ffi.dart` into a small `constants.dart` file in
   `lib/services/crypto/`, then make a `cargo test` that reads
   that file and parses the integer literals out, comparing them
   to the Rust constants in `backend/common/src/constants.rs`.
   Sketch:
   ```rust
   #[test]
   fn dart_constants_match_rust() {
       let dart = std::fs::read_to_string("../../lib/services/crypto/constants.dart").unwrap();
       assert!(dart.contains(&format!("argon2MCost = {}", ARGON2_M_COST)));
       assert!(dart.contains(&format!("argon2TCost = {}", ARGON2_T_COST)));
       // ... and so on
       assert!(dart.contains(&format!("staticSalt = '{}'", std::str::from_utf8(STATIC_SALT).unwrap())));
   }
   ```
2. **Wire it into CI** — add `cargo test -p ktty-common` to any
   CI configuration you ever set up. (No CI today; this becomes
   a manual `cargo test` for now.)
3. **Update both files** if any constant ever changes — bump the
   `STATIC_SALT` version string ("KTTY STATIC SALT VERSION 2")
   too, since changing parameters is effectively a key-derivation
   wire-format change.

**Verify:** Intentionally change one Dart constant by 1 and run
`cargo test -p ktty-common` — it must fail. Revert and re-run; it
must pass.

**Caveat:** This is a string-grep test, not a real type check. A
fancier version would generate the Dart constants file from the
Rust constants at build time (e.g. via a build.rs script that
writes `constants.dart` from a template). Worth considering if
the constants ever multiply.

---

#### 7. Drop `window._kttyCrypto` after Flutter has booted (audit H3 follow-up)

**Goal:** Reduce the attack surface of the WASM crypto exposed to
the page. Today the global lives forever; ideally it's only present
during Flutter's initialisation and is removed once `runApp()` has
executed, leaving any future XSS / extension code with no global
to grab.

**Why it's tricky:** The Flutter JS interop bindings in
`lib/services/crypto/native_crypto_web.dart` use
`@JS('window._kttyCrypto.deriveKey')` etc. — those annotations are
parsed by `dart:js_interop`. It's not documented whether the
binding is *captured* at module-eval time (in which case removing
the global later is safe) or *resolved on every call* (in which case
removing it would break the app the moment a key derivation
happened).

**Files:** `web/wasm-loader.js`, `lib/main.dart`,
`lib/services/crypto/native_crypto_web.dart`.

**Steps:**
1. **Investigate first** — write a tiny test in the live PWA console
   to see what happens. Open https://phuawenpu.github.io/KTTY/,
   wait for the dashboard, then in DevTools console:
   ```js
   const saved = window._kttyCrypto;
   delete window._kttyCrypto;
   // Try to connect with a PIN — does deriveKey still work?
   ```
   If the connect flow still works with the global gone, the JS
   interop is binding-time-captured and we're safe to delete it.
   If it throws "TypeError: window._kttyCrypto is undefined", it's
   resolving per-call and option (a) below applies.
2. **Option (a) — bindings are per-call:** keep the global but stash
   it on a non-enumerable Symbol property instead of a string key,
   so an attacker who doesn't know the symbol can't reach it. Update
   `native_crypto_web.dart` to use the symbol-based path.
3. **Option (b) — bindings are capture-time:** add a one-shot
   "Flutter is up" callback. The cleanest hook is in `lib/main.dart`
   inside `runApp(...)`'s post-frame callback:
   ```dart
   if (kIsWeb) {
     SchedulerBinding.instance.addPostFrameCallback((_) {
       // After the first frame, the JS interop has captured what it
       // needs from window._kttyCrypto. Delete the global so it's
       // not reachable by extensions / XSS.
       js_interop.callMethod('eval'.toJS, ['delete window._kttyCrypto;'.toJS]);
     });
   }
   ```
   (You'd need to import `dart:js_interop` for the JS-side
   `delete`. The CSP allows `wasm-unsafe-eval` not `unsafe-eval`,
   so you might need to do this from `wasm-loader.js` instead via a
   `setTimeout` after Flutter signals readiness.)
4. **Update README threat model.** Replace the current honest
   admission ("`delete window._kttyCrypto` remains future work")
   with the new shipped behaviour.

**Verify:** Hard-reload the PWA, open DevTools console, type
`window._kttyCrypto`. If it returns `undefined`, you're done. Then
type a PIN and connect — the handshake must still succeed (the
proof that the bindings were captured before the delete).

---

#### 8. Document non-overlap requirement on `ktty_mlkem_encapsulate` (audit L5)

**Goal:** Make the C-ABI contract for the FFI crypto entry-point
explicit so a future caller can't accidentally introduce undefined
behaviour.

**Why it matters:** The function uses `std::ptr::copy_nonoverlapping`
to write the ciphertext and shared secret outputs. If a caller ever
passes overlapping pointers (e.g. the ek input and the ct output
sharing memory), it's instant UB. Today's callers — `dart:ffi` on
Android via three distinct `calloc` allocations and the WASM build
— always pass disjoint buffers, so it's sound, but the contract
isn't written down anywhere.

**Files:** `backend/ffi-crypto/src/lib.rs`

**Steps:**
1. Add a `# Safety` doc-comment block above the existing comment on
   `ktty_mlkem_encapsulate`. Required guarantees:
   - `ek` points to ≥ 1184 readable bytes
   - `ct_out` points to ≥ 1088 writable bytes
   - `ss_out` points to ≥ 32 writable bytes
   - **All three regions are pairwise non-overlapping**
   - All three pointers are valid for the duration of the call
2. While you're in the file, also document `ktty_ffi_crypto_version`
   as `# Safety: none — pure read-only constant return`.
3. Optionally add a debug-only `debug_assert!` that the input slice
   length is exactly 1184 (currently it's hard-coded via
   `from_raw_parts(ek, 1184)`).

**Verify:** `cargo build -p ktty-ffi-crypto`. Then re-run
`./build-crypto.sh` to refresh the committed `.so` files (the
behavior is unchanged, but the fingerprint will differ). Run
`cargo test -p ktty-common` to make sure nothing else regressed.

---

### P2 — polish, observability, refactors

Pick these up when bored, or when you're already in the file for
another reason. None of them are blocking and none are
security-critical.

#### 9. Shard the global rooms `Mutex` on the relay (audit M4)

**Goal:** Today every WebSocket message processed by the relay
acquires `rooms.lock().await` up to three times (auth check,
forward, activity update). With a `tokio::sync::Mutex` wrapping
the entire `HashMap<String, Room>`, a single chatty client can
serialise the entire relay across all rooms — every other peer
waits behind the lock. The fix is to shard so each room has its
own lock and operations on different rooms don't contend.

**Files:** `backend/relay/src/main.rs`, `backend/relay/Cargo.toml`.

**Steps:**
1. Add `dashmap = "6"` to `backend/relay/Cargo.toml` if it's not
   already there from item 2.
2. Change the type alias:
   ```rust
   // Old:
   // type RoomMap = Arc<Mutex<HashMap<String, Room>>>;
   // New:
   type RoomMap = Arc<dashmap::DashMap<String, Arc<tokio::sync::Mutex<Room>>>>;
   ```
3. Update every `rooms.lock().await` site:
   - `rooms.entry(room_id.clone()).or_insert_with(|| Arc::new(Mutex::new(Room::new())))`
     to get-or-insert the room handle.
   - Then `room_arc.lock().await` to get into that one room's
     state. The lock is now per-room, so concurrent traffic in
     other rooms doesn't block.
4. The background eviction task currently iterates the whole map
   under one lock. Rewrite it to walk `rooms.iter()` (DashMap's
   iterator yields shard-locked references) and lock each
   `Arc<Mutex<Room>>` individually.
5. The forward-to-other-peer path needs to look up its target
   peer in the SAME room, so just hold that one room's lock for
   the duration. No cross-room locks ever.
6. Drop the `tokio::sync::Mutex` wrapper around the outer map —
   `DashMap` is internally sharded so it doesn't need an outer
   lock at all.

**Verify:** Run the existing relay tests if you have any
(`cargo test -p ktty-relay`). Locally start the relay, connect
two clients to two *different* rooms, and use one of them to
flood data. The other should see no latency increase. (Without
the shard fix, the second client would feel the contention.)

**Caveat:** This is a non-trivial refactor of the relay's
locking discipline. Take a backup of `backend/relay/src/main.rs`
before starting and do it in one focused session. The compiler
will catch most mistakes (`MutexGuard` doesn't implement `Send`
across `await` points unless the lock is held briefly), but
behavioural bugs around eviction order are easy to introduce.

---

#### 10. Measure RTT for non-printable input (Tab/Esc/arrows)

**Goal:** The session-stats popup currently only times keystrokes
in the printable ASCII range (0x20–0x7E) because that's the only
path that goes through the local-echo predictor. Tab, Esc, and
the arrow keys take an unmeasured detour. Add a separate
sequence-correlated path so the popup reflects *all* input
latency, not just the printable subset.

**Files:** `lib/services/terminal/terminal_service.dart`,
`backend/agent/src/session.rs`,
`backend/common/src/messages.rs`,
`backend/agent/src/main.rs`,
`lib/config/constants.dart`.

**Steps:**
1. **Decide on the correlation key.** Options:
   - **(a) per-message timestamps in the envelope** — add an
     optional `client_send_ms` field to the `pty` envelope. The
     agent ignores it; on the way back, the agent's PTY-output
     envelope includes the *client* timestamp of the *last input*
     it processed before this output, so the client can compute
     RTT on receipt. This requires an agent change and a
     wire-format extension (back-compat: old clients omit the
     field, agent omits the echo, client gets no measurement —
     graceful degrade).
   - **(b) opaque correlation token** — client adds a 4-byte
     `cid` field to each input envelope; agent echoes the most
     recently received `cid` on its next output envelope. Same
     idea, smaller wire impact, slightly fiddlier semantics.
2. **Pick (a)**. It's simpler and the wire impact is one extra
   integer field. Update `EncryptedEnvelope` in
   `backend/common/src/messages.rs` to include
   `#[serde(skip_serializing_if = "Option::is_none")] pub client_send_ms: Option<i64>`.
3. **Agent side** (`backend/agent/src/session.rs`): keep a
   `last_client_send_ms: Option<i64>` field on the bridge state.
   On every input envelope, update it. On every output envelope
   the agent generates from PTY data, copy it through to the
   outbound envelope's `client_send_ms` field, then clear the
   stored value (or keep stamping until the next input arrives).
4. **Client side** (`terminal_service.dart`): in `_sendPty`, set
   `client_send_ms = DateTime.now().millisecondsSinceEpoch` on
   the outbound envelope. In `_handleMessage` for `type == 'pty'`,
   if the incoming envelope has `client_send_ms`, compute
   `now - client_send_ms` and feed it to a *separate* stats bucket
   (`stats.noteControlRtt(...)` or just merge with the existing
   `noteRtt`).
5. **Decide on bucketing.** Probably best to split: keep the
   echo-based RTT as "round-trip from local-echo prediction" and
   add a new "round-trip from input timestamp" metric in the
   popup. They measure subtly different things.
6. **Wire format version bump.** This is technically a wire change.
   Bump `VERSION` in `backend/agent/src/main.rs` and `kAppVersion`
   in `lib/config/constants.dart` together. Old clients against
   new agents → field is ignored, no measurement. New clients
   against old agents → field is sent and ignored, no
   measurement. Graceful both ways.

**Verify:** Connect, type a few normal keys, then press
Tab/Esc/arrow several times. Open the stats popup. The Tab/Esc
RTT should be in the same ballpark as the printable RTT (within
the noise floor of one keystroke).

**Caveat:** Clock skew between client and agent is irrelevant for
RTT measurement because both timestamps come from the *client*
clock. As long as Dart's `DateTime.now()` is monotonic, this works.

---

#### 11. Persist smart-invert toggle and stats across app restarts

**Goal:** The smart-invert (light/dark) terminal toggle currently
resets to dark on every app launch. Some users will want sticky
preferences. Same for the session-stats baseline — currently the
rolling RTT buffer is in-memory only and clears on disconnect.

**Files:** `pubspec.yaml`, `lib/state/session_state.dart` (or new
file), `lib/screens/terminal_screen.dart`, `lib/main.dart`.

**Steps:**
1. Add `shared_preferences: ^2.3.0` (or current latest) to the
   `dependencies` block of `pubspec.yaml`. Run `flutter pub get`.
2. Create or extend a settings holder. Simplest: add to the
   existing `SessionState` change-notifier in `lib/state/session_state.dart`:
   ```dart
   bool _invertedTheme = false;
   bool get invertedTheme => _invertedTheme;
   Future<void> setInvertedTheme(bool v) async {
     _invertedTheme = v;
     notifyListeners();
     final prefs = await SharedPreferences.getInstance();
     await prefs.setBool('invertedTheme', v);
   }
   Future<void> loadSettings() async {
     final prefs = await SharedPreferences.getInstance();
     _invertedTheme = prefs.getBool('invertedTheme') ?? false;
     notifyListeners();
   }
   ```
3. In `lib/main.dart`, call `await SessionState.loadSettings()` (or
   make it part of the constructor) before `runApp` so the initial
   state is correct on the first frame.
4. In `lib/screens/terminal_screen.dart`, replace the local
   `_invertedTheme` boolean with `context.watch<SessionState>().invertedTheme`,
   and replace `_toggleInvert` with
   `context.read<SessionState>().setInvertedTheme(!current)`.
5. Drop the now-unused local field and method.

**Stats persistence (optional second step):** if you also want
the latency stats to survive app restarts (so you can see "average
over the last 100 keystrokes" across multiple sessions), serialise
the `_rttSamples` list into prefs on each `noteRtt` call. Be
careful with frequency — write at most once per N seconds via a
debounce timer, not on every keystroke, or you'll thrash the
SharedPreferences disk file.

**Verify:** Toggle smart-invert, kill the app, relaunch. The
toggle should still be in the previous state. Same for stats if
you implemented that part.

**Caveat:** `SharedPreferences` isn't encrypted. Don't ever stash
the user's PIN there — only UI preferences and non-sensitive
metrics. The PIN is already correctly held only in `_lastPin` in
`websocket_service.dart`, in memory, and zeroed on disconnect.

---

#### 12. Tracked lockfiles for the test crates

**Goal:** Make `tests/mlkem_interop/` reproducible by committing
its lockfiles. They're currently gitignored.

**Files:** `tests/mlkem_interop/dart_test/pubspec.lock`,
`tests/mlkem_interop/rust_baseline/Cargo.lock`, plus the relevant
`.gitignore` entries.

**Steps:**
1. Check `tests/mlkem_interop/dart_test/.gitignore` — it has `pubspec.lock`
   in it (from the standard Dart `.gitignore` template). For *bin*
   crates the lock file should be committed; only *library* crates
   should ignore it. The interop test is a bin crate, so:
   ```bash
   cd tests/mlkem_interop/dart_test
   sed -i '/^pubspec.lock$/d' .gitignore  # remove the ignore
   cd /home/pan/Code4/KTTY/workspace
   dart pub get --directory tests/mlkem_interop/dart_test
   git add tests/mlkem_interop/dart_test/.gitignore tests/mlkem_interop/dart_test/pubspec.lock
   ```
2. Same dance for the Rust baseline:
   ```bash
   cd tests/mlkem_interop/rust_baseline
   # Cargo.lock is probably ignored at the repo-root .gitignore
   # via the broad backend/target/ rule — verify with
   git check-ignore -v tests/mlkem_interop/rust_baseline/Cargo.lock
   # If it's ignored, add an explicit `!Cargo.lock` exception. If it's
   # ignored only because the file doesn't exist yet, just:
   cargo generate-lockfile  # or `cargo build --offline=false`
   git add tests/mlkem_interop/rust_baseline/Cargo.lock
   ```
3. Commit with message
   `tests: track interop lockfiles for reproducibility`.

**Verify:** `git status` should show no untracked lockfiles in
`tests/mlkem_interop/`. `cargo run -p rust_baseline` and
`dart run tests/mlkem_interop/dart_test/bin/dart_test.dart` should
both still work.

---

#### 13. Repo layout cleanup — move toolchains out of the repo root

**Goal:** Stop the repo root from doubling as the developer's
project home. Today `flutter/`, `android-sdk/`, `.cargo/`,
`.rustup/`, `.npm-global/`, `.fly/`, `.config/`, etc. all live
inside the repo (gitignored). One careless `git clean -fdx` would
delete all of those.

**Files:** the repo root `.gitignore` would shrink considerably,
but no source files change. This is mostly a filesystem reorg.

**Steps:**
1. Make a new directory **outside** the repo:
   ```bash
   mkdir -p ~/Code4/KTTY-tools
   ```
2. Move the toolchains there:
   ```bash
   cd /home/pan/Code4/KTTY/workspace
   for d in flutter android-sdk .cargo .rustup .npm-global .fly .config .cache; do
     [ -e "$d" ] && mv "$d" ~/Code4/KTTY-tools/
   done
   ```
3. Add `~/Code4/KTTY-tools/flutter/bin` etc. to your shell's PATH
   (or symlink them into `~/.local/bin` / `/usr/local/bin`).
4. Update the **Build environment expectations** table in `README.md`
   to reflect the new paths.
5. Strip the now-unused entries from `.gitignore`:
   ```
   flutter/
   android-sdk/
   .android/
   .config/
   .cache/
   .cargo/
   .rustup/
   .npm/
   .npm-global/
   .fly/
   .local/
   ```
6. Smoke-test by running `flutter pub get` and `cargo test -p
   ktty-common` from the repo root with the new PATH — both must
   still work.

**Verify:** `ls -la /home/pan/Code4/KTTY/workspace` should show
only source directories (`backend/`, `lib/`, `web/`, `android/`,
`linux/`, `tests/`, etc.) plus the small top-level files
(`README.md`, `pubspec.yaml`, etc.). No tooling directories.

**Caveat:** This is a destructive-feeling operation even though
it's just `mv`. Take a backup of the workspace first
(`tar czf ~/ktty-backup.tar.gz workspace/`) so a rollback is one
`tar xzf` away.

---

## License

Not specified in this repo. Treat as private/internal until a license file
is added.
