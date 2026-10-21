// Whole CLI cost with RAM-only output validation. Both clocks come from the
// existing checked wait4/monotonic driver; no startup subtraction or shell.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const [name, sizesText, seedText] = process.argv.slice(2);
const match = /^(bend|zig|rust|lean|luajit|roc)-(bytes|normalized|hex|base64|uniform|wide|normal|exponential|poisson|geometric|sparse|lognormal|beta)-cli-(1|12)$/.exec(name ?? '');
assert.ok(match, 'invalid full CLI profiling case');
const [, backend, kind] = match;
const sizes = sizesText.split(',').map(Number);
assert.deepEqual(sizes, ['bytes', 'hex', 'base64'].includes(kind) ? [8192, 16384, 32768, 65536] : [512, 1024, 2048, 4096]);
assert.equal(seedText, '42');
const commands = Object.fromEntries(['bend', 'zig', 'rust', 'lean', 'luajit', 'roc'].map(b =>
	[b, process.env[`RANDOM_BEND_FULL_${b === 'luajit' ? 'LUA' : b.toUpperCase()}_CLI`]]));
for (const cli of Object.values(commands)) assert.ok(cli, 'missing required CLI artifact');
const flags = {
	bytes: ['-b'], normalized: ['-b', '-n'], hex: ['-b', '--hex'], base64: ['-b', '--base64'],
	uniform: ['d20'], wide: ['-1000000000000..1000000000000'],
	normal: ['-n', '--mean=-0.25', '--stddev=1.75'], exponential: ['--exponential', '--rate=1.75'],
	poisson: ['--poisson', '--lambda=5'], geometric: ['--geometric', '--probability=0.25'],
	sparse: ['--geometric', '--probability=2^-100'], lognormal: ['--log-normal', '--mean=-0.25', '--stddev=1.75'],
	beta: ['--beta=3', '--alpha=1'],
};
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function run(command, args, encoding) {
	const r = spawnSync(command, args.map(String), {encoding, timeout: 120000, maxBuffer: 1 << 24});
	assert.equal(r.error, undefined, String(r.error)); assert.equal(r.status, 0, `${command}: ${r.stderr}`);
	return r;
}
function observed(cli, argv) {
	const r = run(cli, argv);
	const state = JSON.parse(r.stderr.toString('utf8'));
	assert.equal(state.sv, 3); assert.equal(state.rv, '0.4.0'); assert.match(state.next_pos, /^\d+$/);
	return {hash: sha(r.stdout), state, bytes: r.stdout};
}
function fold(bytes) {
	let result = 0n;
	const mask = (1n << 64n) - 1n;
	for (const byte of bytes) result = (((result << 7n | result >> 57n) + BigInt(byte)) & mask);
	return result.toString();
}
const rows = [], observations = [];
const driver = process.env.RANDOM_BEND_FULL_CLI_DRIVER;
assert.ok(driver, 'missing checked CLI timing driver');
for (const size of sizes) {
	const argv = ['--seed', seedText, '--count', String(size), ...flags[kind]];
	const oracle = observed(commands.luajit, argv);
	for (const other of new Set(['zig', 'rust', backend])) {
		const selected = observed(commands[other], argv);
		assert.equal(selected.hash, oracle.hash, `${other} payload mismatch`);
		assert.deepEqual(selected.state, oracle.state, `${other} state mismatch`);
	}
	const checksum = fold(oracle.bytes);
	const probe = run(driver,
		[size, checksum, commands[backend], ...argv], 'utf8');
	const data = JSON.parse(probe.stdout);
	assert.equal(data.correct, true); assert.equal(data.rows.length, 1); assert.equal(data.rows[0].size, size);
	assert.equal(data.rows[0].checksum, checksum);
	for (const metric of ['cpu_ns', 'wall_ns']) {
		assert.equal(data.rows[0].samples[metric].length, 7);
		assert.ok(data.rows[0].samples[metric].every(v => Number.isSafeInteger(v) && v > 0));
	}
	rows.push(data.rows[0]); observations.push({size, payload_sha256: oracle.hash, next_pos: oracle.state.next_pos,
		output_bytes: oracle.bytes.length, measurement: data});
}
console.log(JSON.stringify({schema: 'performance-measurement/v1', correct: true, build_mode: 'optimized',
	clock: 'wait4 child user+system CPU; parent monotonic spawn-to-exit wall including bounded pipe sink; seven fresh runs; no subtraction',
	allocator_coverage: 'fixed 64KiB parent sink; child/runtime allocations uninstrumented; no leak claim',
	backend, kind, seed: Number(seedText), executable_sha256: sha(readFileSync(commands[backend])),
	includes_startup: true, comparison_limit: 'CLI parsing, sampling, formatting and I/O together; not a pure sampler measurement',
	rows, observations}));
