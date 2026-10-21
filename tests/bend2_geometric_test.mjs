// Failures before success; exact existing recurrence and unlimited count bits.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const lib = (await import(pathToFileURL(process.argv[2]))).default;
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const fx = (m, e) => ({$: 'Fixed', m: wide(m), e: e >>> 0});
const done = result => {assert.equal(result.$, 'Done', JSON.stringify(result)); return result.value;};
const array = xs => {const out=[]; while(xs.$.split('.').at(-1)==='Con'){out.push(xs.head);xs=xs.tail;} return out;};
const params = [-1, -2, -3, -20, -62, -63, -100, -1000];
const cases = [];
for (const seed of ['0'.repeat(64), '0'.repeat(62) + '2a', 'f'.repeat(64)])
	for (const e of params) cases.push({seed, e});
const count = 12;
const oracle = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local b=require('blake3'); local d=require('drbg'); local c=require('unsigned_count')
for line in io.lines() do
 local seed,e=line:match('(%x+) ([%-0-9]+)'); e=tonumber(e)
 local r=d.new(b.hex_to_bin(seed))
 for i=1,${count} do
  local value=r:geometric(4611686018427387904LL,e)
  io.write(c.to_hex(value),':',b.bin_to_hex(c.to_blip(value)),':',string.format('%.0f',r:position()),'\\n')
 end
end`], {input: cases.map(c => `${c.seed} ${c.e}`).join('\n') + '\n', encoding: 'utf8'});
assert.equal(oracle.status, 0, oracle.stderr);
const expected = oracle.stdout.trimEnd().split('\n');
assert.equal(expected.length, cases.length * count);
let offset = 0;
for (const c of cases) {
	const prepared = done(lib.geometric_prepare(fx(1n << 62n, c.e)));
	let state = done(lib.new_seed(list([...Buffer.from(c.seed, 'hex')])));
	for (let i = 0; i < count; i++) {
		const result = done(lib.run(state, lib.geometric_sample(prepared)));
		state = result.state;
		const value = result.value;
		assert.equal(`${lib['Count.to_hex'](value)}:${Buffer.from(array(lib['Count.to_blip'](value))).toString('hex')}:${state.hi * 2**32 + state.lo}`,
			expected[offset++], `geometric p=2^${c.e}/${i}`);
	}
}
const state = done(lib.new_seed(list(Array(32).fill(0))));
const certain = done(lib.geometric_prepare(fx(1n << 62n, 0)));
const result = done(lib.run(state, lib.geometric_sample(certain)));
assert.equal(lib['Count.to_hex'](result.value), '0');
assert.equal(result.state.lo, 0, 'certain success must not request bytes');
for (const [m, e] of [[0n, 0], [-(1n << 62n), -1], [1n << 62n, 1], [1n, 0], [1n << 62n, -1000001]])
	assert.deepEqual(lib.geometric_prepare(fx(m, e)), {$: 'Fail', error: 1});
console.log(`bend2 geometric: ${expected.length} exact wide-count/BLIP/cursor checks passed`);
