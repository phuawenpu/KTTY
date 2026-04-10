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
- A web XSS or hostile browser extension trying to call into the WASM
  crypto via `window._kttyCrypto` — the global is wrapped in
  `Object.freeze`, the page ships a strict CSP (`default-src 'self'`),
  and `wasm-unsafe-eval` is the only relaxation.
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
- **`window._kttyCrypto` reachable to any script on the PWA origin and no
  CSP.** **Fix:** strict `<meta>` CSP (`default-src 'self'`,
  `script-src 'self' 'wasm-unsafe-eval'`, `connect-src 'self' wss://*.fly.dev`,
  `frame-ancestors 'none'`), and the global is wrapped with
  `Object.freeze` so its methods can't be hot-swapped.

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
| `lib/screens/dashboard_screen.dart` | URL + PIN entry, "Connect" button, ping indicator. URL field is read-only on native (custom keyboard handles input) but editable on web (uses native browser input). On PWA there's a 5-attempt rate limiter with 30s lockout. |
| `lib/screens/terminal_screen.dart` | Terminal page: xterm view, custom keyboard at the bottom, swipeable control cluster, keyboard-hide toggle. |
| `lib/screens/ping_native.dart` | Native `HttpClient`-based relay HTTP ping (replaces `wss://` → `https://` and tries `GET /`). |
| `lib/screens/ping_web.dart` | Web stub — always returns `true` (browsers can't do raw TCP probes). Selected via conditional import. |
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
| `lib/services/terminal/terminal_service.dart` | Glues `xterm.dart` to the WS service. Local echo prediction (echoes printable keystrokes immediately, suppresses the duplicate when the server replays them), 50ms keystroke batching, ring-buffer sync request after reconnect, plain-text fallback when crypto isn't established. |
| `lib/widgets/terminal/terminal_container.dart` | xterm wrapper with pinch zoom (2-pointer gesture), drag-to-select, double-tap word capture. |
| `lib/widgets/terminal/connection_indicator.dart` | Top-bar dot showing relay/agent status. |
| `lib/widgets/terminal/selection_handles.dart` | Android-style teardrop selection handles overlay with a Copy button. |
| `lib/widgets/keyboard/custom_keyboard.dart` | The on-screen keyboard. Three layers (ABC, 123, SYM) plus a swipe drawer for arrows/function keys. Sends keys via a callback to `terminal_service`. |
| `lib/widgets/keyboard/keyboard_layer.dart` | One layer of the keyboard — renders rows of keys. |
| `lib/widgets/keyboard/key_button.dart` | Single key — handles tap, long-press, swipe, mic (for speech-to-text on Space). |
| `lib/widgets/keyboard/key_definitions.dart` | The actual key layouts for ABC/123/SYM and the function-key drawer. |
| `lib/widgets/keyboard/control_cluster.dart` | Ctrl/Tab/Esc/arrow row above the main keyboard. |
| `lib/widgets/clipboard/clipboard_buttons.dart` | Copy/paste/mark buttons. Paste sends text via `sendText` directly (not as fake keystrokes). |
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
| `web/index.html` | Loads `wasm/ktty_wasm_crypto.js` *before* Flutter, calls `init()`, stamps the exported functions onto `window._kttyCrypto`, and sets `window._kttyCryptoReady = true`. The Flutter `native_crypto_web.dart` reads that flag to decide whether to launch or show the crypto-error screen. |
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

```bash
flutter build web --release \
    --base-href "/KTTY/" \
    --dart-define="BUILD_TIME=$(date -u +'%Y-%m-%d %H:%M UTC')"
# Push build/web to a `gh-pages` branch:
cd build/web
git init
git add .
git commit -m "Deploy PWA"
git branch -M gh-pages
git remote add origin https://github.com/phuawenpu/KTTY.git
git push -f origin gh-pages
```

Then enable GitHub Pages in repo settings → Pages → branch `gh-pages` → root.

The `--base-href "/KTTY/"` is critical because the site lives at
`phuawenpu.github.io/KTTY/`, not at the domain root. Without it, the app
will 404 on its own assets.

---

## Common failure modes

| Symptom | Probable cause | Fix |
|---|---|---|
| `HMAC verification failed — possible MITM attack` | Either (a) Flutter and agent are using different ML-KEM implementations, or (b) someone is genuinely tampering with your handshake. The relay-level auth tokens are constant-time-checked and there are no exempt message types, so a passive room squatter on the relay cannot trigger this. | Confirm `lib/services/crypto/native_crypto_ffi.dart` calls `_mlkemEncapsulate` (the FFI one), not `pqcrypto`. Run `cargo test -p ktty-common test_mlkem`. Run `./build-crypto.sh` and rebuild the APK. |
| `PIN must be at least 8 digits` | You typed a PIN shorter than 8. | Use a longer PIN. The minimum is enforced on both agent and Flutter; see threat model. |
| `Relay URL must use wss://` | You typed `ws://` in the dashboard URL field. | Use `wss://`. Cleartext is rejected because it lets a network attacker observe your room id (PIN-derived material). |
| `Auth token mismatch from peer` in relay logs | A client sent a text message without including the auth token the relay handed back at join time, OR with the wrong token. With the v2 fix this can also indicate that you're running a *new* relay against an *old* agent/client that doesn't include `auth` on handshake messages. | Rebuild and redeploy both ends from the same commit. |
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
5. **PWA had no CSP and `window._kttyCrypto` was a wide-open hot-swap
   target** → strict CSP `<meta>` tag, `Object.freeze` on the global,
   `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.

Plus build hardening: `build-crypto.sh` sets `RUSTFLAGS=--remap-path-prefix=...`
so committed `.so`/`.wasm` artifacts no longer leak the developer's home
directory. `.gitignore` defensively blocks common secret filenames so a
future `git add -A` can't accidentally publish a `.env` or keystore.

### Phase 5 — picking up where this left off

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

The 2026-04-10 audit flagged a number of additional issues that are
**not** fixed in the current commit. They were deferred either because
they require a coordinated wire-protocol bump (so the agent and client
have to be redeployed in lockstep) or because they're performance work
rather than security boundaries. Tackle them in a future v3 commit:

### Wants a coordinated v3 wire-format bump

- **HKDF-based key separation (audit M2).** Today the same Argon2id-derived
  32-byte key is used as the room id (visible to the relay), the
  XChaCha20-Poly1305 encryption key, *and* the HMAC-SHA256 key for the
  ML-KEM verification step. Textbook key-separation violation. Not
  exploitable on its own — HMAC-SHA256 and XChaCha20 are independent
  primitives — but it means cracking the PIN reveals the encryption key
  directly. **Fix:** derive three subkeys with HKDF-SHA256:
  ```
  master      = Argon2id(pin, STATIC_SALT)
  room_key    = HKDF-Expand(master, info="ktty-room-id", L=32)
  encrypt_key = HKDF-Expand(master, info="ktty-encrypt", L=32)
  mac_key     = HKDF-Expand(master, info="ktty-mac",     L=32)
  room_id     = hex(room_key)
  ```
  Touch points: `backend/common/src/crypto.rs`, the agent's session key
  init in `backend/agent/src/session.rs`, and `lib/services/crypto/`
  on the Flutter side. Bump `VERSION` to 8.

- **Mandatory URL-encrypt flow (audit H2 follow-up).** The agent already
  has a `--encrypt-url` mode that produces a hex token sealing the relay
  URL with the user's PIN. This eliminates one trust dimension on the
  client side (the user no longer has to type the URL correctly). Today
  it's optional and the dashboard accepts a free-form `wss://` URL.
  **Fix:** make the dashboard accept *only* an encrypted URL token by
  default; the free-form field becomes an "advanced" option.

### Performance / scalability (security-adjacent but not exploitable)

- **Shard the global rooms `Mutex` (audit M4).** Every WebSocket message
  acquires `rooms.lock().await` up to three times. A chatty client can
  serialize the entire relay. **Fix:** swap `Arc<Mutex<HashMap<...>>>`
  for `Arc<DashMap<String, Arc<Mutex<Room>>>>` so locks are per-room.

- **Per-IP connection limits (audit L4).** A single attacker can open
  thousands of WebSocket upgrades and exhaust the Fly VM's file
  descriptors before they've even joined a room. **Fix:** add a
  `tower::limit::ConcurrencyLimitLayer`, or track per-IP counts in an
  `Arc<DashMap<IpAddr, AtomicU32>>` and reject upgrades over a threshold.

- **`sync_req` rate limit (audit M5).** A peer can repeatedly request
  ring buffer replays, forcing the agent to re-encrypt up to 2 MB of
  PTY history each time. Inside an authenticated session so not a
  pre-auth DoS, but worth bounding. **Fix:** at most one `sync_req`
  per N seconds per peer in `backend/agent/src/session.rs`.

### Polish

- **Document non-overlap requirement on `ktty_mlkem_encapsulate`
  (audit L5).** Current callers always allocate three distinct buffers
  via `calloc`, so the `copy_nonoverlapping` is sound — but the C ABI
  contract isn't documented. Add a `# Safety` clause to
  `backend/ffi-crypto/src/lib.rs`.

- **Add a `SECURITY.md` with disclosure contact.** For a public crypto
  repo this is table stakes. Should also link to this README's threat
  model section.

- **Drop `window._kttyCrypto` after Flutter has booted (audit H3
  follow-up).** Right now we expose it to the page for the lifetime of
  the session because the Flutter JS interop holds an indirect reference
  through bound externs. Investigate whether we can `delete
  window._kttyCrypto` once `runApp` has executed. The closure-bound JS
  interop bindings should keep working after the global is gone.

- **Constants drift detection.** The Argon2 parameters in
  `backend/common/src/constants.rs` and the literal values in
  `lib/services/crypto/native_crypto_ffi.dart` are duplicated. Add a
  `cargo test` or build-time check that fails if they ever diverge.

- **Tracked lockfiles for the test crates.** `tests/mlkem_interop/dart_test/pubspec.lock`
  and `tests/mlkem_interop/rust_baseline/Cargo.lock` are gitignored —
  for bin crates the lock files should be committed for reproducibility.

- **Repo layout cleanup.** The repo root currently doubles as the
  developer's project home (it contains `flutter/`, `android-sdk/`,
  `.cargo/`, `.npm-global/`, etc., all gitignored). One bad
  `git clean -fdx` would nuke all of those. Move the toolchains one
  directory up so the git repo is a proper subdirectory.

---

## License

Not specified in this repo. Treat as private/internal until a license file
is added.
