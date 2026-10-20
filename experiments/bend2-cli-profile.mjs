// Spawn-to-exit output work, distinct from warmed CPU and spawn-to-ready probes.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const [name,size,seed]=process.argv.slice(2);
const match=/^(bend-native|zig|rust|luajit)-cli-(1|12)$/.exec(name??'');
assert.ok(match);assert.equal(size,'4096');assert.equal(seed,'42');
const backend=match[1];
const commands={
	'bend-native':[process.env.RANDOM_BEND_PROBE,'42','4096'],
	zig:[process.env.RANDOM_BEND_ZIG_CLI],rust:[process.env.RANDOM_BEND_RUST_CLI],
	luajit:[process.env.RANDOM_BEND_LUA_CLI],
};
const command=commands[backend];assert.ok(command[0],'missing pinned CLI');
if(backend!=='bend-native') command.push('-d','--seed','42','--binaryoutput','--hex','--count','4096');
function sample() {
	const before=process.hrtime.bigint();
	const result=spawnSync(command[0],command.slice(1),{timeout:30000,maxBuffer:65536});
	const elapsed=Number(process.hrtime.bigint()-before);
	assert.equal(result.status,0,`${command[0]}: ${result.error??result.stderr}`);
	assert.equal(result.stdout.length,8193);
	assert.equal(createHash('sha256').update(result.stdout).digest('hex'),
		'a72b4d17b443948a0b430be95c311dfa2634811589dc8ebe01d9643daec9a285',
		'independent LuaJIT payload fixture; never regenerate from Bend');
	assert.ok(Number.isSafeInteger(elapsed)&&elapsed>0);
	return elapsed;
}
sample();
const wall=Array.from({length:7},sample);
console.log(JSON.stringify({schema:'performance-measurement/v1',correct:true,build_mode:'optimized',
	allocator_coverage:'not instrumented; no memory/leak claim',backend,
	clock:'parent monotonic spawn-to-exit including capture of 8193 bytes in RAM; digest checked outside timing',
	comparison_limit:'Bend narrow byte adapter versus production CLIs; Rust libexec bypasses self-test wrapper; stderr metadata differs',
	payload_sha256:'a72b4d17b443948a0b430be95c311dfa2634811589dc8ebe01d9643daec9a285',
	rows:[{size:4096,samples:{wall_ns:wall}}]}));
