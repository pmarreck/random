// Native codegen must agree with the independent oracle, not just the JS lane.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const exe=process.argv[2];
let checks=0;
for (const seed of [0,1,42,4294967295]) for (const count of [0,1,63,64,65,257,4096]) {
	const expected=spawnSync('luajit',['-e',`package.path='./lib/?.lua;'..package.path
local b=require('blake3');local d=require('drbg')
local material=b.hex_to_bin(string.format('%064x',${seed}))
io.write(b.bin_to_hex(d.new(material):bytes(${count})))`],{encoding:'utf8'});
	assert.equal(expected.status,0,expected.stderr);
	const result=spawnSync(exe,['--threads','1',String(seed),String(count)],{encoding:'utf8'});
	assert.equal(result.status,0,result.stderr);
	assert.equal(result.stderr,'');
	assert.equal(result.stdout,expected.stdout+(count ? '\n' : ''),`native bytes seed=${seed} count=${count}`);
	checks++;
}
for (const args of [[],['nope','1'],['1','4097'],['1','1','extra'],
	['4294967296','1'],['-1','1'],['1','4294967296'],['1','-1']]) {
	const result=spawnSync(exe,['--threads','1',...args],{encoding:'utf8'});
	assert.notEqual(result.status,0);
	assert.equal(result.stdout,'');
	assert.ok(JSON.parse(result.stderr).error);
	checks++;
}
console.log(`bend2 native: ${checks} byte/adapter checks passed`);
