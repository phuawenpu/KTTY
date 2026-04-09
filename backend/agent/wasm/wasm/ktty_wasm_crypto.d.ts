/* tslint:disable */
/* eslint-disable */

/**
 * Compute HMAC-SHA256.
 */
export function computeHmac(argon2_key: Uint8Array, data: Uint8Array): Uint8Array;

/**
 * Decrypt packed data (nonce || ciphertext || tag).
 */
export function decrypt(key: Uint8Array, packed: Uint8Array): Uint8Array;

/**
 * Derive a 32-byte key from PIN using Argon2id.
 */
export function deriveKey(pin: string): Uint8Array;

/**
 * Encrypt plaintext with XChaCha20-Poly1305.
 * Returns nonce(24) || ciphertext || tag(16).
 */
export function encrypt(key: Uint8Array, plaintext: Uint8Array): Uint8Array;

/**
 * Decapsulate: given decapsulation key (2400 bytes) + ciphertext (1088 bytes),
 * recover shared secret (32 bytes).
 */
export function mlkemDecapsulate(dk_bytes: Uint8Array, ciphertext: Uint8Array): Uint8Array;

/**
 * Encapsulate: given an encapsulation key (1184 bytes), produce
 * ciphertext(1088) || shared_secret(32).
 */
export function mlkemEncapsulate(ek_bytes: Uint8Array): Uint8Array;

/**
 * Generate ML-KEM 768 keypair.
 * Returns decapsulation_key || encapsulation_key concatenated.
 * dk = first 2400 bytes, ek = remaining 1184 bytes.
 */
export function mlkemGenerateKeypair(): Uint8Array;

/**
 * Generate Room ID (hex string) from a 32-byte derived key.
 */
export function roomId(derived_key: Uint8Array): string;

/**
 * Verify HMAC with constant-time comparison.
 */
export function verifyHmac(argon2_key: Uint8Array, data: Uint8Array, expected: Uint8Array): boolean;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly computeHmac: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly decrypt: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly deriveKey: (a: number, b: number) => [number, number, number, number];
    readonly encrypt: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly mlkemDecapsulate: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly mlkemEncapsulate: (a: number, b: number) => [number, number, number, number];
    readonly mlkemGenerateKeypair: () => [number, number];
    readonly roomId: (a: number, b: number) => [number, number, number, number];
    readonly verifyHmac: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number];
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
