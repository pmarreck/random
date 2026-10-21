// Existing LuaJIT codecs are the independent oracle, including truncation,
// signed boundaries, large magnitudes and tiny-probability syntax.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const lib = (await import(pathToFileURL(process.argv[2]))).default;
const bytes = text => [...Buffer.from(text)].reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const signed = w => BigInt.asIntN(64, BigInt(w.hi) << 32n | BigInt(w.lo));
const fixed = (m, e) => ({$: 'Fixed', m: wide(m), e: e >>> 0});
const result = r => r.$ === 'Fail' ? 'invalid' : `${signed(r.value.m)}:${r.value.e | 0}`;
const cases = [
	...['', '+', '-', '.', '+.', '1e3', '0x10', '1.2.3', '1x', '1 2', '0', '-0', '+0', '1.', '.5', '-.5',
		' \t+123.456\r\n', '0.123456789012345678901234567890', '9223372036854775807', '9223372036854775808',
		'123456789012345678', '-9007199254740992.5', '1' + '0'.repeat(600), '9'.repeat(2001),
		'0'.repeat(2001), '1\0', 'π'].map(text => ({op: 'parse', text})),
	...['1', '0.5', '.25', '2^-1', '2^-1000', '2^-1000000', '2^+0', '2^1', '2^-1000001',
		'1e-1000', '2.5E-20', '1e+0', '1e1', '+1e-1', '1e-1e-1', '1e', '0', '-0.5', '1.1',
		'0'.repeat(2001) + '.5'].map(text => ({op: 'probability', text})),
];
const source = `package.path='./lib/?.lua;'..package.path
local f=require('fixed'); local g=require('geometric')
for line in io.lines() do
 local op,hex=line:match('(%w+) (.*)'); local text=hex:gsub('%x%x',function(x)return string.char(tonumber(x,16))end)
 local ok,m,e=pcall(op=='parse' and f.parse or g.parse_probability,text)
 if ok and m then io.write(tostring(m):gsub('LL$',''),':',e,'\\n') else io.write('invalid\\n') end
end`;
const oracle = spawnSync('luajit', ['-e', source], {input: cases.map(c => `${c.op} ${Buffer.from(c.text).toString('hex')}`).join('\n') + '\n', encoding: 'utf8'});
assert.equal(oracle.status, 0, oracle.stderr);
const expected = oracle.stdout.trimEnd().split('\n');
assert.equal(expected.length, cases.length);
cases.forEach((c, i) => assert.equal(result(lib[c.op](bytes(c.text))), expected[i], `${c.op}(${JSON.stringify(c.text.slice(0, 80))})`));
const formats = [];
for (const m of [0n, 1n << 62n, -(1n << 62n), (1n << 63n) - 1n, -((1n << 63n) - 1n)])
	for (const e of [-1000000, -1000, -63, -1, 0, 1, 53, 61, 62, 63, 100, 2043, 2044])
		for (const places of [0, 1, 6, 18]) if (m || !e) formats.push([m, e, places]);
formats.push([0n, 0, 0], [0n, 0, 18]);
const renderOracle = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local f=require('fixed'); local ffi=require('ffi')
local function integer(s) local neg=s:sub(1,1)=='-'; local n=0ULL
 for d in s:gmatch('%d') do n=n*10ULL+tonumber(d) end
 return neg and -ffi.cast('int64_t',n) or ffi.cast('int64_t',n) end
for line in io.lines() do local m,e,p=line:match('([%-0-9]+) ([%-0-9]+) (%d+)')
 local ok,text=pcall(f.tostring,integer(m),tonumber(e),tonumber(p))
 io.write(ok and text or 'invalid','\\n') end`], {input: formats.map(x => x.join(' ')).join('\n') + '\n', encoding: 'utf8'});
assert.equal(renderOracle.status, 0, renderOracle.stderr);
const texts = renderOracle.stdout.trimEnd().split('\n');
assert.equal(texts.length, formats.length);
formats.forEach(([m, e, p], i) => {
	const r = lib.render(fixed(m, e), p);
	assert.equal(r.$ === 'Fail' ? 'invalid' : r.value, texts[i], `render(${m},${e},${p})`);
});
for (const [text, n] of [['0', 0n], [' -20\t', -20n], ['+9007199254740992', 1n << 53n]]) {
	const r = lib.integer(bytes(text)); assert.equal(r.$, 'Done'); assert.equal(signed(r.value), n);
}
for (const text of ['', '+', '1.0', '9007199254740993', '-9007199254740993', '1\0'])
	assert.equal(lib.integer(bytes(text)).$, 'Fail', text);
assert.equal(lib.render(fixed(1n, 0), 6).$, 'Fail');
assert.equal(lib.render(fixed(1n << 62n, 0), 19).$, 'Fail');
console.log(`bend2 decimal: ${cases.length + formats.length} independent parse/format comparisons passed`);
