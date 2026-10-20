// Measurement adapter, not another generator or performance-history engine.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';

const [name,sizesText,seedText]=process.argv.slice(2);
const match=/^(bend-native|bend-js|zig|rust|luajit)-(bytes|d6|wide)-(cpu|wall)-(1|12)$/.exec(name??'');
assert.ok(match,'invalid profiling case');
const backend=match[1],kind=['bytes','d6','wide'].indexOf(match[2]),seed=Number(seedText);
assert.ok(Number.isInteger(seed)&&seed>=0&&seed<=0xffffffff);
const sizes=sizesText.split(',').map(Number);
assert.deepEqual(sizes,[1024,2048,4096,8192]);
const commands={
	'bend-native':[process.env.RANDOM_BEND_NATIVE_BENCH],
	'bend-js':['node','--expose-gc','experiments/bend2_js_bench.mjs'],
	zig:[process.env.RANDOM_BEND_ZIG_BENCH],rust:[process.env.RANDOM_BEND_RUST_BENCH],
	luajit:['luajit','experiments/bend2_lua_bench.lua'],
};
function run(command,args) {
	assert.ok(command[0],'missing optimized artifact');
	const result=spawnSync(command[0],[...command.slice(1),...args.map(String)],
		{encoding:'utf8',timeout:60000,maxBuffer:1<<20});
	assert.equal(result.status,0,`${command[0]}: ${result.error??result.stderr}`);
	return result.stdout;
}
function expected(n,repeats) {
	const args=[kind,n,repeats,'-',0,0,seed];
	const zig=JSON.parse(run(commands.zig,args)),rust=JSON.parse(run(commands.rust,args));
	assert.deepEqual(zig,rust,'independent native oracle checksum/cursor mismatch');
	if(repeats<=3) {
		const lua=JSON.parse(run(['luajit','experiments/bend2_expected.lua'],[kind,n,repeats,seed]));
		assert.deepEqual(zig,lua,'native vs LuaJIT contiguous-stream oracle mismatch');
	}
	return zig;
}
function probe(n,repeats,checksum,first,warm) {
	const [ready,text,...extra]=run(commands[backend],[kind,n,repeats,checksum,first,warm,seed]).trimEnd().split('\n');
	assert.equal(ready,'READY');assert.equal(extra.length,0);
	const data=JSON.parse(text);assert.equal(data.correct,true);
	assert.equal(data.iterations,repeats);assert.equal(data.rows.length,1);assert.equal(data.rows[0].size,n);
	for(const metric of ['cpu_ns','wall_ns']) {
		assert.equal(data.rows[0].samples[metric].length,7);
		assert.ok(data.rows[0].samples[metric].every(v=>Number.isSafeInteger(v)&&v>0));
	}
	return data;
}
const rows=[],observations=[];
for(const n of sizes) {
	const first=expected(n,1),warm=expected(n,3);
	const calibration=probe(n,1,first.hash,first.hash,warm.hash);
	const sorted=[...calibration.rows[0].samples.wall_ns].sort((a,b)=>a-b);
	// One declared calibration, not a retry/cherry-pick of accepted observations.
	const repeats=Math.max(1,Math.min(100000,Math.ceil(20000000/sorted[3])));
	const oracle=expected(n,repeats);
	const measurement=probe(n,repeats,oracle.hash,first.hash,warm.hash);
	rows.push(measurement.rows[0]);
	observations.push({size:n,calibration,measurement,oracle});
}
console.log(JSON.stringify({schema:'performance-measurement/v1',correct:true,
	build_mode:'optimized',
	allocator_coverage:'allocation counters unavailable; approximate post-exec RSS is supplemental, not leak evidence',
	clock:'child process CPU and monotonic wall; continuous stream; per-work-unit normalized; one 20ms wall-target calibration',
	backend,kind,seed,rows,observations}));
