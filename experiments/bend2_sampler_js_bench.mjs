// In-process public Bend facade, not a JS rewrite of its numeric algorithms.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {readFileSync} from 'node:fs';
assert.equal(typeof globalThis.gc, 'function', 'use --expose-gc');
assert.ok(!process.execArgv.some(x => /jitless|no-opt/.test(x)), 'optimized JS required');
const lib = (await import(pathToFileURL(resolve(process.env.RANDOM_BEND_LIBDIR, 'lib/javascript/random/index.mjs')))).default;
const text = process.argv.slice(2);
const [kind, n, repeats, , first, warm, seed] = text.map(Number);
const oracle = text[3] === '-';
const expected = oracle ? 0 : Number(text[3]);
assert.equal(text.length, 7);
for (const [value, lo, hi] of [[kind, 3, 11], [n, 1, 8192], [repeats, 1, 1000000],
	[expected, 0, 0xffffffff], [first, 0, 0xffffffff], [warm, 0, 0xffffffff], [seed, 0, 0xffffffff]])
	assert.ok(Number.isSafeInteger(value) && value >= lo && value <= hi);
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = n => ({$: 'Wide', hi: Number(BigInt.asUintN(64, n) >> 32n), lo: Number(n & 0xffffffffn)});
const done = r => {assert.equal(r.$, 'Done', 'public Bend program failed'); return r.value;};
const fixed = (m, e) => {const w = wide(m); return done(lib.fixed(w.hi, w.lo, e >>> 0));};
const one = fixed(1n << 62n, 0), zero = fixed(0n, 0), rate = fixed(1n << 62n, 2);
const lambda = fixed(5n << 60n, 2), mean = fixed(-(1n << 62n), -2), stddev = fixed(7n << 60n, 0);
const shape = fixed(3n << 61n, 1), quarter = fixed(1n << 62n, -2), sparse = fixed(1n << 62n, -100);
const initial = done(lib.new_seed(list([...Buffer.from(seed.toString(16).padStart(64, '0'), 'hex')])));
const mix = (h, v) => ((h << 5 | h >>> 27) ^ v) >>> 0;
const integerHash = (h, w) => mix(mix(h, w.lo), w.hi);
function work(count) {
	let state = initial, hash = 0;
	function sample(program) {
		const result = done(lib.run(state, program)); state = result.state; return result.value;
	}
	for (let repeat = 0; repeat < count; repeat++) {
		if (kind === 11) {
			for (let offset = 0; offset < n;) {
				const amount = Math.min(96, n - offset);
				let plan = done(lib.batch(wide(0n), wide(255n), wide(BigInt(amount)), 0));
				for (let i = 0; i < amount; i++) {
					const view = lib.batch_view(plan);
					assert.equal(view.$.split('.').at(-1), 'Item');
					hash = integerHash(hash, sample(view.program)); plan = view.after;
				}
				assert.equal(lib.batch_view(plan).$.split('.').at(-1), 'Finished');
				offset += amount;
			}
			continue;
		}
		for (let i = 0; i < n; i++) {
			let program;
			switch (kind) {
			case 3: program = lib.normal(zero, one); break;
			case 4: program = lib.normal_int(wide(0n), wide(255n)); break;
			case 5: program = lib.exponential(rate); break;
			case 6: program = lib.poisson(lambda); break;
			case 7: program = lib.log_normal(mean, stddev); break;
			case 8: program = lib.beta(one, shape); break;
			default: program = lib.geometric_sample(done(lib.geometric_prepare(kind === 9 ? quarter : sparse)));
			}
			const value = sample(program);
			if (kind >= 9) {
				let bytes = lib['Count.to_blip'](value);
				while (bytes.$.split('.').at(-1) === 'Con') {hash = mix(hash, bytes.head); bytes = bytes.tail;}
			} else if (kind === 4) hash = integerHash(hash, value);
			else if (kind === 6) hash = integerHash(hash, lib['Fixed.to_int_trunc'](value));
			else hash = mix(integerHash(hash, value.m), value.e);
		}
	}
	return {hash, position: String(state.hi * 2**32 + state.lo)};
}
if (oracle) {console.log(JSON.stringify(work(repeats))); process.exit(0);}
function settle() {
	let previous = Infinity;
	for (let i = 0; i < 32; i++) {
		globalThis.gc(); const current = process.memoryUsage().heapUsed;
		if (current >= previous) return;
		previous = current;
	}
	throw new Error('heap did not settle outside timing');
}
assert.equal(work(1).hash, first, 'incorrect first work');
console.log('READY');
assert.equal(work(3).hash, warm, 'incorrect warmup');
const cpu = [], wall = [];
let position;
for (let i = 0; i < 7; i++) {
	settle();
	const w0 = process.hrtime.bigint(), c0 = process.cpuUsage();
	const result = work(repeats);
	const c1 = process.cpuUsage(c0), w1 = process.hrtime.bigint();
	assert.equal(result.hash, expected, 'incorrect timed work'); position = result.position;
	const ct = (c1.user + c1.system) * 1000, wt = Number(w1 - w0);
	assert.ok(Number.isSafeInteger(ct) && Number.isSafeInteger(wt) && ct > 0 && wt > 0);
	cpu.push(Math.floor(ct / repeats)); wall.push(Math.floor(wt / repeats));
	assert.ok(cpu.at(-1) > 0 && wall.at(-1) > 0);
}
const hwm = /^VmHWM:\s+(\d+) kB$/m.exec(readFileSync('/proc/self/status', 'utf8'));
assert.ok(hwm, 'post-exec RSS unavailable');
console.log(JSON.stringify({schema: 'performance-measurement/v1', correct: true, build_mode: 'optimized',
	backend_build_mode: 'Node-V8-JIT', runtime: process.version, iterations: repeats, position, heap_settled: true,
	allocator_coverage: 'JS/native allocation counters unavailable; supplemental post-exec Linux VmHWM only',
	peak_rss_bytes: Number(hwm[1]) * 1024, rows: [{size: n, samples: {cpu_ns: cpu, wall_ns: wall}}]}));
