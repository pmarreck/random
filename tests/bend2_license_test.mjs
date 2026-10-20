// Pin the actual upstream notices carried by generated/runtime artifacts.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
const [root,name]=process.argv.slice(2);
const files=[['Bend-LICENSE','0beb288abd3d067e231f3fbe7df1f8ee37344061fc67f22018150a19e4b26c35']];
if(name==='random-bend2-proof-kernel') files.push(
	['Lean-LICENSE','8b28515ffffc5c0fe2807d8ae3735b00b324d9b7ce807dd63ff6ac8922fbce7e'],
	['Lean-LICENSES','00cce2ac071f63d470a287438a7c6bbc4334706be244384e9af4fc9ead11cdce']);
for(const [file,digest] of files) {
	const notice=readFileSync(resolve(root,'share/licenses',name,file));
	assert.equal(createHash('sha256').update(notice).digest('hex'),digest);
}
