import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const sampler = (await import(pathToFileURL(process.argv[2]))).default;
// One compiled module graph owns its algebraic constructors and interpreter.
// Independent generated JS bundles are not a shared tagged-union ABI.
const draw = {run: sampler.run};
const core = {new_seed: sampler.new_seed};
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const integer = w => BigInt.asIntN(64, BigInt(w.hi) << 32n | BigInt(w.lo));
const limit = 1n << 53n, seed = '0'.repeat(62) + '2a';
const cases = [];
for (const op of ['range', 'normal_int']) {
	for (const [a, b] of [[0n, 0n], [6n, 6n], [-limit, -limit], [limit, limit],
		[-20n, 20n], [1n, 6n], [0n, 2147483648n], [0n, (1n << 32n)],
		[-limit, -limit + 5n], [limit - 5n, limit], [0n, limit - 1n], [-limit, -1n]])
		cases.push({op, a, b, pos: 0, seed});
}
cases.push({op: 'normal_int', a: -limit, b: limit, pos: 0, seed});
cases.push({op: 'range', a: 0n, b: 1n << 52n, pos: 21544, seed: '0'.repeat(64)});
const count = 32;
const oracle = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local b=require('blake3'); local d=require('drbg')
for line in io.lines() do
 local seed,op,a,z,pos=line:match('(%x+) ([%w_]+) ([%-0-9]+) ([%-0-9]+) (%d+)')
 local r=d.new(b.hex_to_bin(seed),tonumber(pos))
 for i=1,${count} do
  local v=r[op](r,tonumber(a),tonumber(z))
  io.write(string.format('%.0f:%.0f\\n',v,r:position()))
 end
end`], {input: cases.map(c => [c.seed, c.op, c.a, c.b, c.pos].join(' ')).join('\n') + '\n', encoding: 'utf8'});
assert.equal(oracle.status, 0, oracle.stderr);
const lines = oracle.stdout.trimEnd().split('\n');
assert.equal(lines.length, cases.length * count);
let offset = 0;
for (const c of cases) {
	const seeded = core.new_seed(list([...Buffer.from(c.seed, 'hex')]));
	assert.equal(seeded.$, 'Done');
	let state = {...seeded.value, lo: c.pos};
	for (let i = 0; i < count; i++) {
		let result;
		assert.doesNotThrow(() => { result = draw.run(state, sampler[c.op](wide(c.a), wide(c.b))); },
			`${c.op} ${c.a}..${c.b}/${i}`);
		assert.equal(result.$, 'Done', `${c.op}: ${JSON.stringify(result)}`);
		state = result.value.state;
		assert.equal(`${integer(result.value.value)}:${state.hi * 2**32 + state.lo}`,
			lines[offset++], `${c.op} ${c.a}..${c.b}/${i}`);
	}
}
for (const op of ['range', 'normal_int']) for (const [a, b] of [[1n, 0n],
	[-limit - 1n, 0n], [0n, limit + 1n], ...(op === 'range' ? [[-limit, limit]] : [])]) {
	const state = core.new_seed(list(Array(32).fill(0))).value;
	const result = draw.run(state, sampler[op](wide(a), wide(b)));
	assert.equal(result.$, 'Fail');
	assert.equal(result.error.code, 1);
	assert.equal(result.error.state.lo, 0, 'invalid parameters cannot consume entropy');
}
assert.ok(process.argv[3], 'native integer sampler matrix is required');
const args = cases.flatMap(c => {
	const a = wide(c.a), b = wide(c.b);
	return [c.seed.endsWith('2a') ? 1 : 0, c.op === 'range' ? 6 : 7, count,
		a.hi, a.lo, 0, b.hi, b.lo, 0, 0, c.pos].map(String);
});
const native = spawnSync(process.argv[3], ['--threads', '1', '--', ...args],
	{encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024});
assert.equal(native.error, undefined, native.error?.message);
assert.equal(native.status, 0, native.stderr);
const actual = native.stdout.split('\n');
assert.equal(actual.pop(), '');
assert.equal(actual.length, lines.length);
for (const [i, line] of lines.entries()) {
	const [text, cursor] = line.split(':');
	let m = BigInt(text), e = 0;
	if (m) {
		e = 62;
		while ((m < 0n ? -m : m) < 1n << 62n) { m *= 2n; e--; }
	}
	const w = wide(m), p = BigInt(cursor);
	assert.equal(actual[i], `${w.hi}:${w.lo}:${e >>> 0}:${p >> 32n}:${p & 0xffffffffn}`, `native integer case ${i}`);
}
console.log(`bend2 integer programs: ${lines.length} LuaJIT value/cursor checks in JS AND native passed`);
