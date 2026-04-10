// External WASM crypto loader. This file exists (instead of an inline
// <script type="module"> in index.html) because the strict CSP blocks
// inline scripts unless we whitelist them by hash or allow
// 'unsafe-inline' — both of which are worse than just shipping a tiny
// loader file. The script element in index.html simply does:
//
//     <script type="module" src="wasm-loader.js"></script>
//
// Top-level await inside this module blocks any subsequent <script>
// tag from executing, so flutter_bootstrap.js can't run until
// window._kttyCrypto is fully populated. That ordering is critical —
// without it Flutter's main.dart calls NativeCrypto.deriveKey before
// the WASM bindings exist and the resulting handshake produces a wrong
// key (looks like "Wrong PIN" or "Crypto module unavailable" to the
// user, depending on which check fires first).

import init, * as crypto from './wasm/ktty_wasm_crypto.js';

// Defensively unregister any old Flutter service worker on every load.
// We had a few rounds of "the deploy is correct but the user still sees
// the previous build" — that's the SW caching the old main.dart.js. By
// proactively unregistering on every visit, we let Flutter's loader
// re-register a fresh worker against the latest assets. This adds one
// network round-trip on first paint, which is a fine tradeoff for not
// being permanently stuck on a stale build.
if ('serviceWorker' in navigator) {
  try {
    const regs = await navigator.serviceWorker.getRegistrations();
    for (const r of regs) {
      // Only nuke our own; other origins' SWs are isolated anyway.
      if (r.scope.includes('/KTTY/')) {
        await r.unregister();
        console.log('[KTTY] Unregistered stale service worker:', r.scope);
      }
    }
  } catch (e) {
    console.warn('[KTTY] SW unregister failed (non-fatal):', e);
  }
}

try {
  await init();
  // Assign the module namespace object directly. Don't try to copy
  // function references onto a wrapper — wasm-bindgen exports rely on
  // the module-namespace identity, and a copied wrapper can produce
  // subtly wrong results that look like a key mismatch. The CSP is
  // the real defence-in-depth here.
  window._kttyCrypto = crypto;
  window._kttyCryptoReady = true;
  console.log('[KTTY] WASM crypto loaded');
} catch (e) {
  window._kttyCryptoReady = false;
  console.error('[KTTY] WASM crypto failed:', e);
}
