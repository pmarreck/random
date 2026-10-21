// A pure byte-request program must work with independent source interpreters.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const draw = (await import(pathToFileURL(process.argv[2]))).default;
const core = (await import(pathToFileURL(process.argv[3]))).default;
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const array = xs => {
	const out = [];
	while (xs.$ === 'Con') { out.push(xs.head); xs = xs.tail; }
	assert.equal(xs.$, 'Nil');
	return out;
};
const done = result => { assert.equal(result.$, 'Done'); return result.value; };
// Generated modules qualify imported constructor tags; compare their complete
// data after removing only the import namespace, not any state/value fields.
const canonical = value => Array.isArray(value) ? value.map(canonical)
	: value && typeof value === 'object' ? Object.fromEntries(Object.entries(value)
		.map(([key, item]) => [key, key === '$' ? item.split('.').at(-1) : canonical(item)])) : value;
const equal = (a, b) => assert.deepEqual(canonical(a), canonical(b));
const state = done(core.new_seed(list(Array(32).fill(0))));
const raw = done(core.read(state, 12));
const sourceBytes = array(raw.bytes);
const program = () => draw.bind(draw.read(4), a => draw.bind(draw.read(8),
	b => draw.pure([...array(a), ...array(b)])));
const got = done(draw.run(state, program()));
equal(got.state, raw.state);
assert.deepEqual(got.value, sourceBytes);
const first = draw.steps(program()).next(list(sourceBytes.slice(0, 4)));
assert.equal(first.count, 8);
assert.deepEqual(first.next(list(sourceBytes.slice(4))).value, got.value);
const mapped = draw.bind(draw.pure(41), x => draw.pure(x + 1));
equal(done(draw.run(state, mapped)), {$: 'Outcome', state, value: 42});
const failed = draw.bind(draw.reject(5), () => { throw Error('must not execute'); });
equal(draw.run(state, failed), {$: 'Fail', error: {$: 'Failure', code: 5, state}});
const terminal = {...state, hi: 2097151, lo: 4294967288};
const overflow = draw.run(terminal, program());
equal(overflow, {$: 'Fail', error: {$: 'Failure', code: 2,
	state: {...terminal, lo: 4294967292}}});
const invalid = {...state, hi: 2097152, lo: 1};
equal(draw.run(invalid, draw.pure(42)),
	{$: 'Fail', error: {$: 'Failure', code: 1, state: invalid}});
equal(draw.run(invalid, draw.bind(draw.read(0), () => draw.pure(1))),
	{$: 'Fail', error: {$: 'Failure', code: 1, state: invalid}});
console.log('bend2 draw: pure/source-substitution/bind/failure-prefix checks passed');
