// Shared-engine adapter: independent API checks, one declared calibration,
// complete raw samples. No performance-history policy lives in this file.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [name, sizesText, seedText] = process.argv.slice(2);
const match = /^(bendffi|bendjs|zig|rust|luajit|roc)-(normal|normalint|exponential|poisson|lognormal|beta|geometric|sparse|batch)-(cpu|wall)-(1|12)$/.exec(name ?? '');
assert.ok(match, 'invalid nonlinear profiling case');
const [, backend, kindName] = match;
const kind = ['normal', 'normalint', 'exponential', 'poisson', 'lognormal', 'beta', 'geometric', 'sparse', 'batch'].indexOf(kindName) + 3;
const sizes = sizesText.split(',').map(Number), seed = Number(seedText);
assert.deepEqual(sizes, [256, 512, 1024, 2048]);
assert.equal(seed, 42);
const commands = {
	bendffi: [process.env.RANDOM_BEND_SAMPLER_BENCH],
	bendjs: ['node', '--expose-gc', 'experiments/bend2_sampler_js_bench.mjs'],
	zig: [process.env.RANDOM_BEND_ZIG_BENCH], rust: [process.env.RANDOM_BEND_RUST_BENCH],
	luajit: ['luajit', 'experiments/bend2_lua_bench.lua'], roc: [process.env.RANDOM_BEND_ROC_SAMPLER_BENCH],
};
function run(command, args) {
	assert.ok(command[0], 'missing optimized artifact');
	const r = spawnSync(command[0], [...command.slice(1), ...args.map(String)], {encoding: 'utf8', timeout: 120000, maxBuffer: 1 << 20});
	assert.equal(r.error, undefined, String(r.error));
	assert.equal(r.status, 0, `${command[0]}: ${r.stderr}`);
	return r.stdout;
}
function expected(n, repeats) {
	const args = [kind, n, repeats, '-', 0, 0, seed];
	const zig = JSON.parse(run(commands.zig, args));
	assert.deepEqual(JSON.parse(run(commands.rust, args)), zig, 'Rust/Zig checksum or cursor mismatch');
	if (repeats <= 3) assert.deepEqual(JSON.parse(run(['luajit', 'experiments/bend2_expected.lua'], [kind, n, repeats, seed])), zig,
		'LuaJIT/native sampler mismatch');
	return zig;
}
function probe(n, repeats, value, first, warm) {
	const [ready, text, ...extra] = run(commands[backend], [kind, n, repeats, value.hash, first.hash, warm.hash, seed]).trimEnd().split('\n');
	assert.equal(ready, 'READY'); assert.equal(extra.length, 0);
	const data = JSON.parse(text);
	assert.equal(data.correct, true); assert.equal(data.position, value.position, 'timed sampler cursor mismatch');
	assert.equal(data.iterations, repeats); assert.equal(data.rows.length, 1); assert.equal(data.rows[0].size, n);
	for (const metric of ['cpu_ns', 'wall_ns']) {
		assert.equal(data.rows[0].samples[metric].length, 7);
		assert.ok(data.rows[0].samples[metric].every(v => Number.isSafeInteger(v) && v > 0));
	}
	return data;
}
const rows = [], observations = [];
for (const n of sizes) {
	const first = expected(n, 1), warm = expected(n, 3);
	const calibration = probe(n, 1, first, first, warm);
	const samples = [...calibration.rows[0].samples.wall_ns].sort((a, b) => a - b);
	const repeats = Math.max(1, Math.min(100000, Math.ceil(20000000 / samples[3])));
	const value = expected(n, repeats);
	const measurement = probe(n, repeats, value, first, warm);
	rows.push(measurement.rows[0]); observations.push({size: n, calibration, measurement, oracle: value});
}
console.log(JSON.stringify({schema: 'performance-measurement/v1', correct: true, build_mode: 'optimized',
	allocator_coverage: 'runtime/native allocations uninstrumented; no leak or no-allocation claim',
	clock: 'child CPU and monotonic wall; sampler+own DRBG; reset once per sample; one 20ms calibration; per-work-unit duration',
	backend, kind: kindName, seed, rows, observations}));
