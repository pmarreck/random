// Canonical geometry is checked independently from terminal encodings.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const lib = (await import(pathToFileURL(process.argv[2]))).default;
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const fx = (m, e) => ({$: 'Fixed', m: wide(BigInt(m)), e: Number(e) >>> 0});
const word = w => BigInt.asIntN(64, BigInt(w.hi) << 32n | BigInt(w.lo));
const array = xs => {const out = []; while(xs.$.split('.').at(-1) === 'Con'){out.push(xs.head);xs=xs.tail;} return out;};
const shapes = [
	[1, '0', '1'], [1, '-1', '0.125'], [1, '5', '2.5'],
	[2, '0.125', '0'], [2, '8', '0'],
	[3, '0.000001', '0'], [3, '0.5', '0'], [3, '3', '0'], [3, '50', '0'], [3, '500000', '0'],
	[4, '-2', '0.5'], [4, '0', '1'], [4, '5', '3'],
	[5, '0.25', '0.5'], [5, '1', '1'], [5, '1', '3'], [5, '2', '2'], [5, '1048576', '0.125'],
	[6, '1', '0'], [6, '0.99', '0'], [6, '0.5', '0'], [6, '0.05', '0'], [6, '2^-64', '0'], [6, '2^-1000000', '0'],
].flatMap(shape => [2, 3, 17].map(n => [...shape, n]));
const lua = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local f=require('fixed'); local g=require('geometric');local v=require('distribution_view')
local names={'normal','exponential','poisson','log_normal','beta','geometric'}
local function num(m)return tostring(m):gsub('LL$','')end
for line in io.lines() do
 local kind,a,b,n=line:match('(%d+) ([^ ]+) ([^ ]+) (%d+)'); kind=tonumber(kind);n=tonumber(n)
 local am,ae=(kind==6 and g.parse_probability or f.parse)(a);local bm,be=f.parse(b)
 local h,count,lo,hi,discrete=v.curve(names[kind],{am,ae},{bm,be},n)
 io.write(num(am),':',ae,':',num(bm),':',be,';',num(lo[1]),':',lo[2],':',num(hi[1]),':',hi[2],';',discrete and '1' or '0',';',table.concat(h,','),'\\n')
end`], {input: shapes.map(s => s.join(' ')).join('\n') + '\n', encoding: 'utf8'});
assert.equal(lua.status, 0, lua.stderr);
const lines = lua.stdout.trimEnd().split('\n');
assert.equal(lines.length, shapes.length);
lines.forEach((line, i) => {
	const [parts, bounds, discrete, heights] = line.split(';');
	const [am, ae, bm, be] = parts.split(':');
	const r = lib.sample(shapes[i][0], fx(am, ae), fx(bm, be), shapes[i][3]);
	assert.equal(r.$, 'Done', JSON.stringify({shape: shapes[i], r}));
	const c = r.value;
	assert.equal(`${word(c.minimum.m)}:${c.minimum.e | 0}:${word(c.maximum.m)}:${c.maximum.e | 0}`, bounds, `bounds ${shapes[i]}`);
	assert.equal(typeof c.discrete, 'boolean');
	assert.equal(c.discrete ? '1' : '0', discrete);
	assert.equal(array(c.heights).join(','), heights, `heights ${shapes[i]}`);
});
for (const n of [0, 1, 4097]) assert.equal(lib.sample(1, fx(0, 0), fx(1n << 62n, 0), n).$, 'Fail');
assert.equal(lib.sample(0, fx(0, 0), fx(0, 0), 17).$, 'Fail');
assert.equal(lib.sample(1, fx(0, 0), fx(0, 0), 17).$, 'Fail');
console.log(`bend2 charts: ${shapes.length} independent exact model/height/bounds comparisons passed`);
