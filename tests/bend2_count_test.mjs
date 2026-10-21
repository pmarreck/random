// BigInt and frozen unsigned-BLIP fixtures are independent of Bend's limbs.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const count = (await import(pathToFileURL(process.argv[2]))).default;
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const array = xs => {
	const out = [];
	while (xs.$.split('.').at(-1) === 'Con') { out.push(xs.head); xs = xs.tail; }
	assert.equal(xs.$.split('.').at(-1), 'Nil');
	return out;
};
const done = r => {assert.equal(r.$, 'Done', JSON.stringify(r)); return r.value;};
const from = n => {
	const bytes = [];
	while (n) {bytes.push(Number(n & 255n)); n >>= 8n;}
	return done(count.from_bytes(list(bytes)));
};
const to = n => array(n.bytes).reduceRight((a, byte) => a * 256n + BigInt(byte), 0n);
let checks = 0;
for (const bits of [0, 1, 7, 8, 9, 31, 32, 53, 63, 64, 65, 127, 128, 129, 255, 256, 1000]) {
	for (const n of [0n, (1n << BigInt(bits)) - 1n, 1n << BigInt(bits)]) {
		const value = from(n);
		assert.equal(to(count.increment(value)), n + 1n);
		assert.equal(to(done(count.double_add(value, 0))), n * 2n);
		assert.equal(to(done(count.double_add(value, 1))), n * 2n + 1n);
		assert.equal(count.to_decimal(value), n.toString());
		assert.equal(count.to_hex(value), n.toString(16));
		assert.equal(to(done(count.from_decimal(n.toString()))), n);
		assert.equal(to(done(count.from_blip(count.to_blip(value)))), n);
		for (const tail of [0, 1, 7, 8, 9, 63, 64, 65, 137]) {
			const low = Array(Math.ceil(tail / 8)).fill(255);
			assert.equal(to(done(count.append_low_bits(value, list(low), tail))),
				(n << BigInt(tail)) + (1n << BigInt(tail)) - 1n);
			checks++;
		}
		checks += 7;
	}
}
for (const [n, hex] of [[0n, '00'], [127n, '7f'], [128n, '8180'], [256n, '820001'],
	[1n << 64n, '89' + '00'.repeat(8) + '01'], [1n << 128n, '91' + '00'.repeat(16) + '01'],
	[1n << 248n, 'a001' + '00'.repeat(31) + '01']]) {
	assert.equal(Buffer.from(array(count.to_blip(from(n)))).toString('hex'), hex);
	checks++;
}
for (const bad of ['', '-1', '+1', '1.0', '1e3', '0x10', ' 1', '1 '])
	assert.deepEqual(count.from_decimal(bad), {$: 'Fail', error: 1});
for (const bad of [[], [128], [128, 1], [129, 1], [129, 0], [130, 1], [130, 1, 0],
	[192, 1], [0, 0], [160, 0], [160, 128, 0]])
	assert.deepEqual(count.from_blip(list(bad)), {$: 'Fail', error: 1});
assert.deepEqual(count.double_add(from(1n), 2), {$: 'Fail', error: 1});
assert.deepEqual(count.from_bytes(list([256])), {$: 'Fail', error: 1});
assert.deepEqual(count.append_low_bits(from(1n), list([]), 1), {$: 'Fail', error: 1});
console.log(`bend2 counts: ${checks} BigInt and frozen BLIP fixtures passed`);
