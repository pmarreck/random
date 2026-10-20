// Mutate private fixture copies, never the checked-in implementation or oracle.
import assert from 'node:assert/strict';
import {cpSync,readFileSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
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
