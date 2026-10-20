// Mutate private fixture copies, never the checked-in implementation or oracle.
import assert from 'node:assert/strict';
import {cpSync,readFileSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {validate} from './bend2_spec_test.mjs';
const scratch=process.argv[2];
const good=spawnSync('bend',['bend/PROOF.bend','--verdict'],{encoding:'utf8',timeout:30000});
assert.equal(good.status,0,good.stderr+good.stdout);
assert.match(good.stdout,/^ALL PROOFS CHECK$/m);
for (const [name,from,to] of [
	['word-truncation','U32.and(U32.shrn(x, 16n), 255), U32.shrn(x, 24n)]','U32.and(U32.shrn(x, 16n), 255)]'],
	['zero-read-emits-byte','def xof_at(cv: CV, +hi: U32, +lo: U32, count: Nat) -> List<U32>:\n\tmatch count:\n\t\tcase 0n:\n\t\t\tNil{}',
	 'def xof_at(cv: CV, +hi: U32, +lo: U32, count: Nat) -> List<U32>:\n\tmatch count:\n\t\tcase 0n:\n\t\t\t[0]'],
]) {
	const dir=join(scratch,name);
	cpSync('bend',dir,{recursive:true});
	const path=join(dir,'Core.bend'),original=readFileSync(path,'utf8');
	assert.equal(original.split(from).length,2,`mutation must have exactly one target: ${name}`);
	writeFileSync(path,original.replace(from,to));
	const result=spawnSync('bend',[join(dir,'PROOF.bend'),'--verdict'],{encoding:'utf8',timeout:30000});
	assert.equal(result.error,undefined,`${name}: a timeout/infrastructure error is inconclusive`);
	assert.notEqual(result.status,0,`${name}: wrong implementation was accepted`);
	assert.match(result.stdout+result.stderr,/SOME PROOFS FAIL/);
}
// A law-only edit must trip the independent frozen-specification sentinel.
const spec=readFileSync('bend/LAWS.bend','utf8');
assert.equal(spec.split('== 64n').length,2);
const mutated=spec.replace('== 64n','== 60n');
assert.notEqual(mutated,spec);
// The actual gate verifies the immutable digest, not a hand-written predicate.
import {createHash} from 'node:crypto';
const expected=readFileSync('tests/fixtures/bend2-laws.sha256','utf8').split(' ')[0];
assert.equal(createHash('sha256').update(spec).digest('hex'),expected);
assert.notEqual(createHash('sha256').update(mutated).digest('hex'),expected);
const predicates=JSON.parse(readFileSync('tests/fixtures/bend2-spec.json','utf8'));
const core=readFileSync('bend/Core.bend','utf8');
const base=spawnSync('bend',['base'],{encoding:'utf8',timeout:10000});
assert.equal(base.status,0,base.stderr);
for (const validCore of [core,core.replace('a: U32, b: U32','a:U32, b:U32')]) {
	validate(predicates,validCore,base.stdout);
}
for (const invalidCore of [
	core.replace('type CV is Data:','type CV is Type:'),
	core.replace('Stream{key: CV, hi: U32, lo: U32}','Stream{key: CV, lo: U32, hi: U32}'),
	core.replace('Sample{state: Stream, value: Wide}','Sample{value: Wide, state: Stream}'),
]) assert.throws(()=>validate(predicates,invalidCore,base.stdout));
assert.throws(()=>validate(predicates,core,base.stdout+'\n'));
const brokenPredicate=base.stdout.replace('1n+List.length(a, A, t)','0n');
assert.notEqual(brokenPredicate,base.stdout);
assert.throws(()=>validate(predicates,core,brokenPredicate));
