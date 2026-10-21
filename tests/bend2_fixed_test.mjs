// Independent BigInt arithmetic and the existing LuaJIT numeric kernel are
// the judges. No floating-point tolerance can conceal a one-bit disagreement.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const compiled = (await import(pathToFileURL(process.argv[2]))).default;
const nativeCalls = [];
const opcodes = {add: 0, sub: 1, mul: 2, div: 3, norm: 4, shl: 5, shr: 6, mul128: 7,
	ln: 8, exp: 9, cos_turns: 10, sqrt: 11, pow: 12};
const wideText = w => `${w.hi}:${w.lo}`;
const fx = new Proxy(compiled, {get(target, name) {
	if (!(name in opcodes)) return target[name];
	return (...args) => {
		const result = target[name](...args);
		const binary = opcodes[name] < 4 || opcodes[name] >= 8;
		const a = binary ? args[0].m : args[0];
		const b = binary ? args[1].m : name === 'mul128' ? args[1] : {hi: 0, lo: 0};
		const ae = binary ? args[0].e : name === 'mul128' ? 0 : args[1];
		const be = binary ? args[1].e : 0;
		const text = result.$ === 'Fail' ? `error:${result.error}`
			: result.$ === 'Done' ? `${wideText(result.value.m)}:${result.value.e}`
			: name === 'mul128' ? `${wideText(result.upper)}:${wideText(result.lower)}` : wideText(result);
		nativeCalls.push({args: [opcodes[name], a.hi, a.lo, ae, b.hi, b.lo, be].map(String), text});
		return result;
	};
}});
const MASK = (1n << 64n) - 1n, TWO62 = 1n << 62n;
const wide = n => ({$: 'Wide', hi: Number((n & MASK) >> 32n), lo: Number(n & 0xffffffffn)});
const word = n => BigInt(n.hi) << 32n | BigInt(n.lo);
const signed = n => BigInt.asIntN(64, word(n));
const fixed = (m, e) => ({$: 'Fixed', m: wide(m), e: e >>> 0});
const output = result => {
	assert.equal(result.$, 'Done', JSON.stringify(result));
	return [signed(result.value.m), result.value.e | 0];
};
const norm = (m, e) => {
	if (m === 0n) return [0n, 0];
	const negative = m < 0n;
	let mag = negative ? -m : m;
	while (mag >= 1n << 63n) { mag >>= 1n; e++; }
	while (mag < TWO62) { mag <<= 1n; e--; }
	return [negative ? -mag : mag, e];
};
const add = ([a, ae], [b, be]) => {
	if (!a) return [b, be];
	if (!b) return [a, ae];
	if (ae < be) return add([b, be], [a, ae]);
	if (ae - be >= 63) return [a, ae];
	const shifted = b / (1n << BigInt(ae - be));
	if (!shifted) return [a, ae];
	return (a < 0n) === (shifted < 0n)
		? norm(a / 2n + shifted / 2n, ae + 1) : norm(a + shifted, ae);
};
const mul = ([a, ae], [b, be]) => {
	if (!a || !b) return [0n, 0];
	const mag = (a < 0n ? -a : a) * (b < 0n ? -b : b);
	const shift = mag >= 1n << 125n ? 63n : 62n;
	return [(a < 0n) !== (b < 0n) ? -(mag >> shift) : mag >> shift,
		ae + be + Number(shift - 62n)];
};
const div = ([a, ae], [b, be]) => norm(a * TWO62 / b, ae - be);
let checks = 0;
const edge = [0n, 1n, 65535n, 65536n, 0xffffffffn, 1n << 32n,
	(1n << 48n) - 1n, TWO62 - 1n, TWO62, (1n << 63n) - 1n, MASK];
for (const a of edge) {
	for (const shift of [0, 1, 15, 16, 31, 32, 33, 62, 63, 64, 65]) {
		assert.equal(word(fx.shr(wide(a), shift)), a >> BigInt(shift));
		assert.equal(word(fx.shl(wide(a), shift)), (a << BigInt(shift)) & MASK);
		checks += 2;
	}
	for (const b of edge) {
		const p = fx.mul128(wide(a), wide(b));
		assert.equal(word(p.upper) << 64n | word(p.lower), a * b);
		checks++;
	}
}
for (const m of [0n, 1n, -1n, TWO62 - 1n, TWO62, -TWO62,
	(1n << 63n) - 1n, -(1n << 63n)]) {
	for (const e of [-100, -1, 0, 1, 62, 100]) {
		assert.deepEqual(output(fx.norm(wide(m), e >>> 0)), norm(m, e));
		checks++;
	}
}
const values = [[0n, 0], ...[TWO62, TWO62 + 1n, TWO62 + 3n,
	(1n << 63n) - 1n].flatMap(m => [-63, -1, 0, 1, 32, 63].flatMap(e => [[m, e], [-m, e]]))];
const requests = [];
for (let i = 0; i < values.length; i++) {
	const a = values[i];
	for (const j of [0, 1, 2, (i + 17) % values.length, values.length - i - 1]) {
		const b = values[j];
		for (const [op, oracle] of [['add', add], ['sub', (x, [m, e]) => add(x, [-m, e])],
			['mul', mul], ...(b[0] ? [['div', div]] : [])]) {
			const want = oracle(a, b);
			assert.deepEqual(output(fx[op](fixed(...a), fixed(...b))), want,
				`${op}(${a}, ${b})`);
			requests.push([op, ...a, ...b, ...want]);
			checks++;
		}
	}
}
const luaSource = `package.path='./lib/?.lua;'..package.path
local ffi=require('ffi'); local fx=require('fixed')
local function integer(s)
 local neg=s:sub(1,1)=='-'; local x=0ULL
 for d in s:gmatch('%d') do x=x*10ULL+tonumber(d) end
 return neg and -ffi.cast('int64_t',x) or ffi.cast('int64_t',x)
end
for line in io.lines() do
 local op,a,ae,b,be=line:match('([%w_]+) ([%-0-9]+) ([%-0-9]+) ([%-0-9]+) ([%-0-9]+)')
 local m,e=fx[op](integer(a),tonumber(ae),integer(b),tonumber(be))
 io.write(tostring(m):gsub('LL$',''),':',e,'\\n')
end`;
const lua = spawnSync('luajit', ['-e', luaSource],
	{input: requests.map(r => r.slice(0, 5).join(' ')).join('\n') + '\n', encoding: 'utf8'});
assert.equal(lua.status, 0, lua.stderr);
const lines = lua.stdout.trimEnd().split('\n');
assert.equal(lines.length, requests.length);
requests.forEach((r, i) => assert.equal(lines[i], `${r[5]}:${r[6]}`, `LuaJIT oracle ${r.slice(0, 5)}`));
checks += requests.length;
const transcendental = [];
for (const m of [TWO62, TWO62 + 1n, (1n << 63n) - 1n]) {
	for (const e of [-300, -63, -32, -1, 0, 1, 32, 300]) {
		for (const op of ['ln', 'sqrt']) transcendental.push([op, m, e, TWO62, 0]);
		for (const power of [-2n, -1n, 0n, 1n, 2n, 10n])
			transcendental.push(['pow', m, e, ...norm(power, 62)]);
	}
	for (const sign of [-1n, 1n]) {
		for (const e of [-10, -1, 0, 1, 3]) transcendental.push(['exp', sign * m, e, TWO62, 0]);
		for (const e of [-100, -64, -63, -2, -1, 0, 1, 30, 50])
			transcendental.push(['cos_turns', sign * m, e, TWO62, 0]);
	}
}
for (const op of ['exp', 'sqrt', 'cos_turns']) transcendental.push([op, 0n, 0, TWO62, 0]);
const transLua = spawnSync('luajit', ['-e', luaSource],
	{input: transcendental.map(r => r.join(' ')).join('\n') + '\n', encoding: 'utf8'});
assert.equal(transLua.status, 0, transLua.stderr);
const transLines = transLua.stdout.trimEnd().split('\n');
assert.equal(transLines.length, transcendental.length);
for (const [i, [op, a, ae, b, be]] of transcendental.entries()) {
	const got = output(fx[op](fixed(a, ae), fixed(b, be)));
	assert.equal(`${got[0]}:${got[1]}`, transLines[i], `${op}(${a},${ae},${b},${be})`);
	checks++;
}
for (const [op, a, b, code] of [
	['mul', [TWO62, 2147483647], [TWO62, 1], 5],
	['mul', [TWO62, -2147483648], [TWO62, -1], 5],
	['div', [TWO62, 2147483647], [TWO62, -1], 5],
	['div', [TWO62, 0], [0n, 0], 5],
	['add', [1n, 0], [TWO62, 0], 1],
	['mul', [TWO62, 0], [0n, 2], 1],
]) {
	assert.deepEqual(fx[op](fixed(...a), fixed(...b)), {$: 'Fail', error: code});
	checks++;
}
// A negative intermediate exponent sum may overflow i32 even though the
// product's +1 renormalization brings the FINAL exponent back into range.
assert.deepEqual(output(fx.mul(fixed((1n << 63n) - 1n, -2147483648),
	fixed((1n << 63n) - 1n, -1))), [(1n << 63n) - 2n, -2147483648]);
assert.ok(process.argv[3], 'native Bend numeric probe is required, not a JS-only matrix');
const native = spawnSync(process.argv[3], ['--threads', '1', '--', ...nativeCalls.flatMap(c => c.args)],
	{encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024});
assert.equal(native.error, undefined, native.error?.message);
assert.equal(native.status, 0, native.stderr);
const nativeLines = native.stdout.split('\n');
assert.equal(nativeLines.pop(), '', 'native output must have its final newline');
assert.equal(nativeLines.length, nativeCalls.length, 'native matrix must be complete');
nativeCalls.forEach((c, i) => assert.equal(nativeLines[i], c.text, `native case ${i}: ${c.args.join(' ')}`));
console.log(`bend2 fixed: ${checks} exact limb/BigInt/LuaJIT checks and ${nativeCalls.length} native cases passed`);
