import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const modulePath = process.argv[2];
if (!modulePath) throw new Error("usage: node wasm_probe.mjs MODULE.wasm");

const wasi = new WASI({ version: "preview1" });
const bytes = await readFile(modulePath);
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});
wasi.initialize(instance);
const api = instance.exports;
if (!(api.memory instanceof WebAssembly.Memory)) throw new Error("memory is not exported");
if (api.randomz_wasi_fill(0, 0) !== 0) throw new Error("zero-length fill was rejected");
if (api.randomz_wasi_fill(0, 1) !== 1) throw new Error("null output was not rejected");

// Work only in a freshly grown page, beyond Zig's stack and static data.
const page = api.memory.grow(1) * 65536;
const seedAt = page;
const stateAt = page + 64;
const outputAt = page + 128;
const entropyAAt = page + 256;
const entropyBAt = page + 288;
const memory = new Uint8Array(api.memory.buffer);

memory.fill(0, seedAt, seedAt + 32);
memory[seedAt + 31] = 42;
if (api.randomz_drbg_init(stateAt, seedAt) !== 0) throw new Error("DRBG init failed");
if (api.randomz_drbg_fill(stateAt, outputAt, 64) !== 0) throw new Error("DRBG fill failed");

if (api.randomz_wasi_fill(entropyAAt, 32) !== 0 ||
    api.randomz_wasi_fill(entropyBAt, 32) !== 0) {
  throw new Error("WASI random_get failed");
}
const entropyA = memory.slice(entropyAAt, entropyAAt + 32);
const entropyB = memory.slice(entropyBAt, entropyBAt + 32);
if (entropyA.every((byte) => byte === 0) || entropyB.every((byte) => byte === 0)) {
  throw new Error("WASI random_get returned an all-zero block");
}
if (entropyA.every((byte, index) => byte === entropyB[index])) {
  throw new Error("two independent WASI random_get blocks were identical");
}

// A host entropy failure must cross the ABI as RANDOMZ_ERR_ENTROPY (2), never
// turn into a deterministic or all-zero fallback.  Use a second WASI context
// so Node permits initializing a second reactor instance.
const failingWasi = new WASI({ version: "preview1" });
const failingImports = {
  ...failingWasi.wasiImport,
  random_get: () => 5, // WASI errno IO
};
const { instance: failingInstance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: failingImports,
});
failingWasi.initialize(failingInstance);
const failingApi = failingInstance.exports;
const failingPage = failingApi.memory.grow(1) * 65536;
if (failingApi.randomz_wasi_fill(failingPage, 32) !== 2) {
  throw new Error("WASI random_get failure did not fail closed");
}

process.stdout.write(Buffer.from(memory.slice(outputAt, outputAt + 64)).toString("hex"));
