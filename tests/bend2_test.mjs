// External official vectors and the existing LuaJIT oracle own expected bytes.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const core = (await import(pathToFileURL(process.argv[2]))).default;
const fixtureBytes = readFileSync('tests/fixtures/blake3-test-vectors.json');
assert.equal(createHash('sha256').update(fixtureBytes).digest('hex'),
	'dcb91ea8accc77e6d6e632af7cdc1a99a9f3ae78cf648da595c7d064db32f624');
const fixture = JSON.parse(fixtureBytes);
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
function bytes(xs) {
	const out = [];
	while (xs.$ === 'Con') {
		assert.ok(Number.isInteger(xs.head) && xs.head >= 0 && xs.head <= 255);
		out.push(xs.head);
		xs = xs.tail;
	}
	assert.equal(xs.$, 'Nil');
	return Buffer.from(out);
}
let checks = 0;
const iv = core.iv();
const key = core.key_words(list([...Buffer.from(fixture.key)]));
const contextKey = core.key_words(list([...bytes(core.block_xof(
	list([...Buffer.from(fixture.context_string)]),iv,32,0,0)).subarray(0,32)]));
// This is explicitly the DRBG's <=64-byte hash subset, as in the Lean core.
for (const v of fixture.cases.filter(v => v.input_len <= 64)) {
	const input = list(Array.from({length: v.input_len}, (_, i) => i % 251));
	for (const [cv, flags, field] of [[iv, 0, 'hash'], [key, 16, 'keyed_hash'],
		[contextKey,64,'derive_key']]) {
		const out = bytes(core.block_xof(input, cv, flags, 0, 0));
		assert.equal(out.toString('hex'), v[field].slice(0, 128), `${field}/${v.input_len}`);
		checks++;
	}
}
const requests = [];
for (const seed of ['0'.repeat(64), '0'.repeat(62)+'2a', 'f'.repeat(64)]) {
	for (const pos of [0, 1, 31, 63, 64, 65, 127, 2**32-1, 2**32, 2**53-65]) {
		for (const count of [0, 1, 63, 64, 65]) requests.push([seed,pos,count]);
	}
}
const oracleCode = `package.path='./lib/?.lua;'..package.path
local b=require('blake3'); local d=require('drbg')
for line in io.lines() do
 local seed,pos,count=line:match('(%x+) (%d+) (%d+)')
 local r=d.new(b.hex_to_bin(seed),tonumber(pos))
 io.write(b.bin_to_hex(r:bytes(tonumber(count))), '\\n')
end`;
const oracleResult = spawnSync('luajit', ['-e', oracleCode], {
	input: requests.map(r => r.join(' ')).join('\n')+'\n', encoding: 'utf8',
});
assert.equal(oracleResult.status, 0, oracleResult.stderr);
const oracleLines = oracleResult.stdout.split('\n');
assert.equal(oracleLines.pop(), '');
assert.equal(oracleLines.length, requests.length);
const oracle = new Map(requests.map((r,i) => [r.join('/'), oracleLines[i]]));
for (const seed of ['0'.repeat(64), '0'.repeat(62)+'2a', 'f'.repeat(64)]) {
	const cv = core.seed_key(list([...Buffer.from(seed, 'hex')]));
	for (const pos of [0, 1, 31, 63, 64, 65, 127, 2**32-1, 2**32, 2**53-65]) {
		for (const count of [0, 1, 63, 64, 65]) {
			const hi = Math.floor(pos / 2**32), lo = pos % 2**32;
			const got = bytes(core.xof_at(cv, hi, lo, count));
			assert.equal(got.toString('hex'), oracle.get([seed,pos,count].join('/')), `seeded/${pos}/${count}`);
			checks++;
		}
	}
	const whole = bytes(core.xof_at(cv, 0, 0, 257));
	for (let split = 0; split <= 257; split++) {
		const a = bytes(core.xof_at(cv, 0, 0, split));
		const b = bytes(core.xof_at(cv, 0, split, 257-split));
		assert.deepEqual(Buffer.concat([a,b]), whole, `chunk split ${split}`);
		checks++;
	}
}
const done = value => {
	assert.equal(value.$, 'Done');
	return value.value;
};
const bad = (value, code) => {
	assert.deepEqual(value, {$: 'Fail', error: code});
	checks++;
};
for (const length of [0, 1, 31, 33, 64]) bad(core.new_seed(list(Array(length).fill(0))), 1);
bad(core.new_seed(list([...Array(31).fill(0), 256])), 1);
const original = done(core.new_seed(list(Array(32).fill(0))));
const read = done(core.read(original, 65));
assert.deepEqual([read.state.hi, read.state.lo], [0,65]);
assert.equal(bytes(read.bytes).toString('hex'), oracle.get(['0'.repeat(64),0,65].join('/')));
checks += 2;
const terminal = {...original, hi: 2097152, lo: 0};
assert.deepEqual(done(core.read(terminal,0)).state, terminal);
bad(core.read(terminal,1), 2);
bad(core.read({...terminal, lo: 1},0), 1);
bad(core.read({...terminal, hi: 4294967295},0), 1);
assert.deepEqual(done(core.read({...original, hi:0,lo:4294967295},1)).state,
	{...original,hi:1,lo:0});
const mask = (1n << 64n)-1n;
const wide = n => ({$: 'Wide', hi:Number((n & mask)>>32n), lo:Number(n & 0xffffffffn)});
const integer = w => (BigInt(w.hi)<<32n) | BigInt(w.lo);
const edgeWords = [0n,1n,255n,2n**32n-1n,2n**32n,2n**53n-1n,mask];
for (const a of edgeWords) for (const b of edgeWords) {
	assert.equal(integer(core.u64_add(wide(a),wide(b))), (a+b)&mask);
	assert.equal(integer(core.u64_sub(wide(a),wide(b))), (a-b)&mask);
	assert.equal(core.u64_lt(wide(a),wide(b)), a<b);
	if (b>0 && b<=2n**53n) assert.equal(integer(core.u64_mod(wide(a),wide(b))), a%b);
	checks++;
}
for (let a=0n;a<32n;a++) for (let b=1n;b<32n;b++) {
	assert.equal(integer(core.u64_mod(wide(a),wide(b))), a%b);
	checks++;
}
const limit = 2n**53n;
const bounds = [[0n,0n],[6n,6n],[-limit,-limit],[limit,limit],[0n,1n],[1n,6n],
	[-20n,20n],[0n,2147483648n],[0n,0xffffffffn],[0n,2n**32n],
	[-limit,-limit+5n],[limit-5n,limit],[0n,limit-1n],[-limit,-1n],
	[-(2n**40n),2n**40n],[-limit,-limit+2n**32n]];
const rangeInputs = [];
for (const seed of ['0'.repeat(64), '0'.repeat(62)+'2a', 'f'.repeat(64)]) {
	for (const [a,b] of bounds) rangeInputs.push([seed,a,b,0]);
}
// Independently found in the LuaJIT byte stream: first 64-bit draw at this
// offset exceeds the rejection bound for the inclusive 0..2^52 interval.
rangeInputs.push(['0'.repeat(64),0n,2n**52n,21544]);
const rangeOracle = spawnSync('luajit', ['-e', `package.path='./lib/?.lua;'..package.path
local b=require('blake3'); local d=require('drbg')
for line in io.lines() do
 local seed,a,z,pos=line:match('(%x+) ([%-0-9]+) ([%-0-9]+) (%d+)')
 local r=d.new(b.hex_to_bin(seed),tonumber(pos))
 for i=1,16 do
  io.write(string.format('%.0f:%.0f\\n',r:range(tonumber(a),tonumber(z)),r:position()))
 end
end`], {input: rangeInputs.map(r => r.join(' ')).join('\n')+'\n',encoding:'utf8'});
assert.equal(rangeOracle.status,0,rangeOracle.stderr);
const rangeLines = rangeOracle.stdout.trimEnd().split('\n');
assert.equal(rangeLines.length,rangeInputs.length*16);
let rangeIndex=0, sawRejection=false, sawWideRejection=false;
for (const [seed,a,b,pos] of rangeInputs) {
	let state={...done(core.new_seed(list([...Buffer.from(seed,'hex')]))),
		hi:Math.floor(pos/2**32),lo:pos%2**32};
	for (let i=0;i<16;i++) {
		const [v,expectedPos]=rangeLines[rangeIndex++].split(':');
		const sample=done(core.range(state,wide(a),wide(b)));
		assert.equal(integer(sample.value),BigInt(v)&mask, `range ${a}..${b}`);
		const next=sample.state.hi*2**32+sample.state.lo;
		assert.equal(next,Number(expectedPos));
		if (b===2147483648n && next-(state.hi*2**32+state.lo)>4) sawRejection=true;
		if (pos===21544 && i===0 && next-pos>8) sawWideRejection=true;
		state=sample.state;
		checks++;
	}
}
assert.ok(sawRejection,'oracle matrix must exercise rejection, not just successful first draws');
assert.ok(sawWideRejection,'forced wide input must consume more than one eight-byte draw');
for (const [a,b] of [[1n,0n],[limit+1n,limit+1n],[-limit-1n,-limit-1n],[-limit,0n],[-limit,limit]]) {
	const result=core.range(original,wide(a),wide(b));
	assert.deepEqual(result,{$:'Fail',error:{$:'Failure',code:1,state:original}});
	checks++;
}
assert.deepEqual(done(core.range(terminal,wide(6n),wide(6n))),
	{$:'Sample',state:terminal,value:wide(6n)});
assert.deepEqual(core.range(terminal,wide(0n),wide(1n)),
	{$:'Fail',error:{$:'Failure',code:2,state:terminal}});
console.log(`bend2 core: ${checks} independent vector/cursor/chunk/domain checks passed`);
