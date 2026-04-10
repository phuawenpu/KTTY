#!/bin/bash
# Build the Rust crypto artifacts that the Flutter app needs:
#
#   1. backend/ffi-crypto -> libktty_ffi_crypto.so for each Android ABI,
#      copied to android/app/src/main/jniLibs/<abi>/
#   2. backend/wasm-crypto -> web/wasm/ktty_wasm_crypto.{js,wasm}
#
# This must be run inside the build container (or anywhere with Rust +
# cargo-ndk + wasm-pack installed). The host machine doesn't have a Rust
# toolchain.
#
# Required tools:
#   - rustc + cargo (rust 1.85+ for edition 2024)
#   - cargo-ndk (cargo install cargo-ndk)
#   - Android NDK with ANDROID_NDK_HOME set
#   - wasm-pack (curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh)
#   - rust target wasm32-unknown-unknown (rustup target add wasm32-unknown-unknown)
#   - rust targets for android (rustup target add aarch64-linux-android \
#     armv7-linux-androideabi x86_64-linux-android i686-linux-android)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$SCRIPT_DIR/backend"

echo "==> Building ktty-ffi-crypto for Android (cdylib)"
cd "$BACKEND"
cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86_64 \
    -t x86 \
    -o "$SCRIPT_DIR/android/app/src/main/jniLibs" \
    build --release -p ktty-ffi-crypto

echo "==> Building ktty-wasm-crypto for web (wasm-bindgen)"
cd "$BACKEND/wasm-crypto"
wasm-pack build \
    --release \
    --target web \
    --out-dir "$SCRIPT_DIR/web/wasm" \
    --out-name ktty_wasm_crypto

# wasm-pack writes a package.json we don't need; remove it so the web folder
# stays tidy.
rm -f "$SCRIPT_DIR/web/wasm/package.json" \
      "$SCRIPT_DIR/web/wasm/.gitignore" \
      "$SCRIPT_DIR/web/wasm/README.md"

echo ""
echo "==> Done. Artifacts:"
ls -lh "$SCRIPT_DIR/android/app/src/main/jniLibs"/*/libktty_ffi_crypto.so 2>/dev/null || true
ls -lh "$SCRIPT_DIR/web/wasm/" 2>/dev/null || true
