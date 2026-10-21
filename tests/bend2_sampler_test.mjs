// Exact production samplers and cursor traces, not statistical tolerances.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const sampler = (await import(pathToFileURL(process.argv[2]))).default;
const draw = {run: sampler.run, steps: sampler.steps};
const core = {new_seed: sampler.new_seed};
const tables = {lookup: index => {const r = sampler.strip(index); assert.equal(r.$, 'Done'); return r.value;}};
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const integer = w => BigInt.asIntN(64, BigInt(w.hi) << 32n | BigInt(w.lo));
const fixed = (m, e) => ({$: 'Fixed', m: wide(BigInt(m)), e: e >>> 0});
const one = fixed(1n << 62n, 0), zero = fixed(0, 0);
function rational(n, shift = 0) {
	if (!n) return [0n, 0];
	let m = BigInt(n), e = 62 - shift;
	while ((m < 0n ? -m : m) < 1n << 62n) { m *= 2n; e--; }
	return [m, e];
}
const stripRows = [...readFileSync('lib/ziggurat_tables.lua', 'utf8')
	.matchAll(/\{(\d+)LL, (-?\d+), (\d+)LL, (-?\d+), (\d+)ULL\}/g)];
assert.equal(stripRows.length, 256);
for (let i = 0; i < 256; i++) {
	const strip = tables.lookup(i), [, xm, xe, ym, ye, k] = stripRows[i];
	assert.deepEqual([integer(strip.x.m).toString(), strip.x.e | 0, integer(strip.y.m).toString(),
		strip.y.e | 0, (BigInt(strip.k.hi) << 32n | BigInt(strip.k.lo)).toString()],
	[xm, Number(xe), ym, Number(ye), k]);
}
assert.deepEqual(sampler.strip(256), {$: 'Fail', error: 1});
const cases = [];
for (const seed of ['0'.repeat(64), '0'.repeat(62) + '2a', 'f'.repeat(64)]) {
	for (const [op, count] of [['uniform', 64], ['normal', 2048], ['exponential', 64],
		['poisson', 32], ['log_normal', 64], ['beta', 64]]) cases.push({seed, op, count,
		a: rational(op === 'normal' || op === 'log_normal' ? 0 : 1),
		b: rational(op === 'normal' || op === 'log_normal' || op === 'beta' ? 1 : 0)});
	for (const [op, count, a, b] of [
		['normal', 257, rational(-1, 2), rational(7, 2)],
		['exponential', 64, rational(1, 3), rational(0)],
		['exponential', 64, rational(17), rational(0)],
		['poisson', 64, rational(1, 4), rational(0)],
		['poisson', 64, rational(20), rational(0)],
		['log_normal', 64, rational(-2), rational(1, 1)],
		['beta', 64, rational(1, 2), rational(3, 2)],
		['beta', 64, rational(1), rational(3)],
		['beta', 64, rational(3), rational(4)],
	]) cases.push({seed, op, count, a, b});
}
const lua = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local b=require('blake3'); local d=require('drbg'); local fx=require('fixed'); local ffi=require('ffi')
local function integer(s)
 local neg=s:sub(1,1)=='-'; local x=0ULL
 for digit in s:gmatch('%d') do x=x*10ULL+tonumber(digit) end
 return neg and -ffi.cast('int64_t',x) or ffi.cast('int64_t',x)
end
for line in io.lines() do
 local seed,op,count,am,ae,bm,be=line:match('(%x+) ([%w_]+) (%d+) ([%-0-9]+) ([%-0-9]+) ([%-0-9]+) ([%-0-9]+)')
 am,ae,bm,be=integer(am),tonumber(ae),integer(bm),tonumber(be)
 local r=d.new(b.hex_to_bin(seed))
 for i=1,tonumber(count) do
  local m,e
  if op=='uniform' then m,e=r:uniform()
  elseif op=='normal' then m,e=r:normal(am,ae,bm,be)
  elseif op=='exponential' then m,e=r:exponential(am,ae)
  elseif op=='poisson' then m,e=fx.from_int(r:poisson(am,ae))
  elseif op=='log_normal' then m,e=r:log_normal(am,ae,bm,be)
  elseif op=='beta' then m,e=r:beta(am,ae,bm,be)
  else error('unknown case') end
  io.write(tostring(m):gsub('LL$',''),':',e,':',string.format('%.0f',r:position()),'\\n')
 end
end`], {input: cases.map(c => [c.seed, c.op, c.count, ...c.a, ...c.b].join(' ')).join('\n') + '\n',
	encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
assert.equal(lua.status, 0, lua.stderr);
const expected = lua.stdout.trimEnd().split('\n');
assert.equal(expected.length, cases.reduce((n, c) => n + c.count, 0));
let offset = 0, slowNormals = 0;
for (const c of cases) {
	const seeded = core.new_seed(list([...Buffer.from(c.seed, 'hex')]));
	assert.equal(seeded.$, 'Done');
	let state = seeded.value;
	const a = fixed(...c.a), b = fixed(...c.b);
	for (let i = 0; i < c.count; i++) {
		const before = state.hi * 2**32 + state.lo;
		const program = c.op === 'uniform' ? sampler.uniform()
			: c.op === 'normal' || c.op === 'log_normal' || c.op === 'beta'
				? sampler[c.op](a, b) : sampler[c.op](a);
		const result = draw.run(state, program);
		assert.equal(result.$, 'Done', `${c.op}/${i}: ${JSON.stringify(result)}`);
		state = result.value.state;
		const position = state.hi * 2**32 + state.lo;
		const value = result.value.value;
		assert.equal(`${integer(value.m)}:${value.e | 0}:${position}`, expected[offset++], `${c.op}/${i}`);
		if (c.op === 'normal' && position - before > 8) slowNormals++;
	}
}
assert.ok(slowNormals > 0, 'normal differential must actually exercise wedge/tail paths');
assert.ok(process.argv[3], 'native Bend sampler matrix is required');
const opcodes = {uniform: 0, normal: 1, exponential: 2, poisson: 3, log_normal: 4, beta: 5};
const nativeArgs = cases.flatMap(c => {
	const a = fixed(...c.a), b = fixed(...c.b), tag = c.seed.startsWith('f') ? 2 : c.seed.endsWith('2a') ? 1 : 0;
	return [tag, opcodes[c.op], c.count, a.m.hi, a.m.lo, a.e, b.m.hi, b.m.lo, b.e, 0, 0].map(String);
});
const native = spawnSync(process.argv[3], ['--threads', '1', '--', ...nativeArgs],
	{encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024});
assert.equal(native.error, undefined, native.error?.message);
assert.equal(native.status, 0, native.stderr);
const nativeLines = native.stdout.split('\n');
assert.equal(nativeLines.pop(), '');
assert.equal(nativeLines.length, expected.length, 'native matrix must be complete');
for (const [i, line] of expected.entries()) {
	const [m, e, position] = line.split(':'), w = wide(BigInt(m)), p = BigInt(position);
	assert.equal(nativeLines[i], `${w.hi}:${w.lo}:${Number(e) >>> 0}:${p >> 32n}:${p & 0xffffffffn}`,
		`native sampler case ${i}`);
}
console.log(`bend2 samplers: ${expected.length} exact production value/cursor checks in JS AND native; all 256 strips passed`);
