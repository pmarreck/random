// No repository imports or CLI dependency: use the installed coherent graph.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const random = (await import(pathToFileURL(process.argv[2]))).default;
const list = xs => xs.reduceRight((tail, head) => ({$: 'Con', head, tail}), {$: 'Nil'});
const wide = lo => ({$: 'Wide', hi: 0, lo});
const seed = random.new_seed(list([...Array(31).fill(0), 42]));
assert.equal(seed.$, 'Done');
const drawn = random.run(seed.value, random.range(wide(1), wide(20)));
assert.equal(drawn.$, 'Done');
assert.deepEqual([drawn.value.value.hi, drawn.value.value.lo], [0, 18]);
assert.equal(drawn.value.state.hi, 0);
assert.equal(drawn.value.state.lo, 4);
const half = random.probability(list([...Buffer.from('0.5')]));
assert.equal(half.$, 'Done');
const prepared = random.geometric_prepare(half.value);
assert.equal(prepared.$, 'Done');
assert.equal(random.run(drawn.value.state, random.geometric_sample(prepared.value)).$, 'Done');
// A refused program must preserve the state and remain a Rejected constructor
// in THIS graph, rather than be mistaken for another module's byte request.
const refused = random.run(seed.value, random.exponential({$: 'Fixed', m: wide(0), e: 0}));
assert.equal(refused.$, 'Fail');
assert.equal(refused.error.code, 1);
assert.deepEqual(refused.error.state, seed.value);
console.log('Installed Bend source/JavaScript SDK consumer passed');
