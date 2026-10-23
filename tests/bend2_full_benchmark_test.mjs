// Existing independent public APIs judge every measured backend and workload.
// Wrong-work controls must fail before a timing result can be admitted.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
const commands = {
	bendffi: [process.env.RANDOM_BEND_SAMPLER_BENCH],
	bendjs: ['node', '--expose-gc', 'experiments/bend2_sampler_js_bench.mjs'],
	zig: [process.env.RANDOM_BEND_ZIG_BENCH], rust: [process.env.RANDOM_BEND_RUST_BENCH],
	luajit: ['luajit', 'experiments/bend2_lua_bench.lua'], roc: [process.env.RANDOM_BEND_ROC_SAMPLER_BENCH],
};
function run(command, args) {
	assert.ok(command[0], 'missing required backend');
	const r = spawnSync(command[0], [...command.slice(1), ...args.map(String)], {encoding: 'utf8', timeout: 30000, maxBuffer: 1 << 20});
	assert.equal(r.error, undefined, String(r.error)); return r;
}
const names = [];
for (const cores of [1, 12]) for (const backend of Object.keys(commands))
	for (const kind of ['normal', 'normalint', 'exponential', 'poisson', 'lognormal', 'beta', 'geometric', 'sparse', 'batch'])
		for (const metric of ['cpu', 'wall']) names.push(`${backend}-${kind}-${metric}-${cores}`);
const config = JSON.parse(readFileSync('profiling-bend2-full.json', 'utf8'));
assert.equal(config.cases.length, 216);
assert.deepEqual(config.cases.map(c => c.name).sort(), names.sort());
assert.equal(new Set(config.cases.map(c => c.name)).size, 216);
for (const c of config.cases) {
	assert.equal(c.timeout_ms, 300000, 'full sampler deadline must cover the complete four-size case');
	assert.deepEqual(c.sizes, [256, 512, 1024, 2048]);
	assert.equal(c.metric, c.name.split('-')[2] + '_ns'); assert.equal(c.cores, Number(c.name.split('-')[3]));
}
const repair = JSON.parse(readFileSync('profiling-bend2-budget-repair.json', 'utf8'));
assert.equal(repair.cases.length, 31);
assert.equal(new Set(repair.cases.map(c => c.name)).size, 31);
for (const c of repair.cases) assert.deepEqual(c, config.cases.find(full => full.name === c.name),
	'deadline repair must preserve all measured work, samples, bounds and noise policy');
for (const [name, manifest] of [['bendffi', 'random-bend2-sampler-bench'], ['zig', 'random-zig-bend2-bench'],
	['rust', 'random-rust-bend2-bench'], ['roc', 'random-roc-bend2-sampler-bench']]) {
	assert.ok(commands[name][0]);
	const check = run(['sha256sum'], ['--check', '--status', resolve(dirname(commands[name][0]), '../share', manifest, 'source.sha256')]);
	assert.equal(check.status, 0, `stale ${name}: ${check.stderr}`);
}
let checks = 0;
for (const kind of [3, 4, 5, 6, 7, 8, 9, 10, 11]) for (const n of [1, 64]) {
	const oracle = repeats => {
		const lua = run(['luajit', 'experiments/bend2_expected.lua'], [kind, n, repeats, 42]);
		assert.equal(lua.status, 0, lua.stderr); const expected = JSON.parse(lua.stdout);
		for (const name of ['zig', 'rust', 'bendffi', 'bendjs', 'roc']) {
			const r = run(commands[name], [kind, n, repeats, '-', 0, 0, 42]);
			assert.equal(r.status, 0, `${name}: ${r.stderr}`);
			assert.deepEqual(JSON.parse(r.stdout), expected, `${name} ${kind}/${n} value/cursor mismatch`);
		}
		return expected;
	};
	const first = oracle(1), warm = oracle(3), two = oracle(2);
	// Retain the exact two-repeat value/cursor controls above. Timer admission
	// additionally uses at least 64 checked outputs for short-run accounting.
	// Aggregate verified work, never clamp or retry a nonpositive clock.
	const timedRepeats = n === 1 ? 64 : 2;
	const expected = timedRepeats === 2 ? two : oracle(timedRepeats);
	const args = [kind, n, timedRepeats, expected.hash, first.hash, warm.hash, 42];
	for (const [name, command] of Object.entries(commands)) {
		const r = run(command, args); assert.equal(r.status, 0, `${name} kind=${kind} size=${n} repeats=${timedRepeats}: ${r.stderr}`);
		const [ready, text, ...extra] = r.stdout.trimEnd().split('\n');
		assert.equal(ready, 'READY'); assert.equal(extra.length, 0);
		const data = JSON.parse(text);
		assert.equal(data.correct, true); assert.equal(data.position, expected.position);
		assert.equal(data.iterations, timedRepeats); assert.equal(data.rows[0].size, n);
		for (const metric of ['cpu_ns', 'wall_ns']) {
			assert.equal(data.rows[0].samples[metric].length, 7);
			assert.ok(data.rows[0].samples[metric].every(v => Number.isSafeInteger(v) && v > 0));
		}
		if (n === 1 && [3, 9, 11].includes(kind)) for (const index of [3, 4, 5]) {
			const bad = [...args]; bad[index] = (bad[index] + 1) >>> 0;
			assert.notEqual(run(command, bad).status, 0, `${name} accepted corrupted ${kind}/${index}`);
		}
		checks++;
	}
}
assert.equal(checks, 108);
const cliConfig = JSON.parse(readFileSync('profiling-bend2-full-cli.json', 'utf8'));
for (const c of cliConfig.cases) assert.equal(c.timeout_ms, 300000);
const cliNames = [];
for (const cores of [1, 12]) for (const backend of ['bend', 'zig', 'rust', 'lean', 'luajit', 'roc'])
	for (const kind of ['bytes', 'normalized', 'hex', 'base64', 'uniform', 'wide', 'normal', 'exponential', 'poisson', 'geometric', 'sparse', 'lognormal', 'beta'])
		cliNames.push(`${backend}-${kind}-cli-${cores}`);
assert.deepEqual(cliConfig.cases.map(c => c.name).sort(), cliNames.sort());
assert.equal(new Set(cliNames).size, 156);
const driver = process.env.RANDOM_BEND_FULL_CLI_DRIVER;
assert.ok(driver, 'missing checked whole-CLI driver');
// Frozen existing seed=42/d20 first value, not generated by Bend. The C driver
// must reject wrong output even in warmup, before exposing any timing JSON.
const checksum = (18n.toString().split('').reduce((n, d) => (n << 7n) + BigInt(d.charCodeAt(0)), 0n) << 7n) + 10n;
for (const name of ['BEND', 'ZIG', 'RUST', 'LEAN', 'LUA', 'ROC']) {
	const cli = process.env[`RANDOM_BEND_FULL_${name}_CLI`];
	assert.ok(cli, `missing ${name} CLI`);
	const args = [1, checksum.toString(), cli, '--seed', 42, '--count', 1, 'd20'];
	const measured = run([driver], args); assert.equal(measured.status, 0, measured.stderr);
	const data = JSON.parse(measured.stdout); assert.equal(data.correct, true);
	assert.equal(data.rows[0].checksum, checksum.toString());
	for (const metric of ['cpu_ns', 'wall_ns']) assert.ok(data.rows[0].samples[metric].every(v => Number.isSafeInteger(v) && v > 0));
	const corrupted = [...args]; corrupted[1] = (checksum + 1n).toString();
	assert.notEqual(run([driver], corrupted).status, 0, `${name} admitted wrong CLI work`);
}
console.log(`Bend nonlinear benchmark: ${checks} six-backend work/cursor controls and 54 wrong-work refusals passed`);
console.log('Full CLI benchmark: 156 case definitions and six checked whole-process timing/wrong-work controls passed');
