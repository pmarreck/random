import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {dirname,resolve} from 'node:path';
import {readFileSync} from 'node:fs';

function run(command,args=[]) {
	const result=spawnSync(command,[...args].map(String),{encoding:'utf8',timeout:30000,maxBuffer:1<<20});
	assert.equal(result.error,undefined,`${command}: ${result.error}`);
	return result;
}
for(const [command,manifest] of [
	[process.env.RANDOM_BEND_NATIVE_BENCH,'random-bend2-bench'],
	[process.env.RANDOM_BEND_ZIG_BENCH,'random-zig-bend2-bench'],
	[process.env.RANDOM_BEND_RUST_BENCH,'random-rust-bend2-bench'],
]) {
	assert.ok(command,'missing pinned benchmark artifact');
	const check=run('sha256sum',['--check','--status',resolve(dirname(command),'../share',manifest,'source.sha256')]);
	assert.equal(check.status,0,`stale ${manifest}: ${check.stderr}`);
}
const modelTest=run('node',['tests/bend2_benchmark_model_test.mjs',process.env.RANDOM_BEND_MODEL_MODULE]);
assert.equal(modelTest.status,0,modelTest.stderr);
const clock=run(resolve(dirname(process.env.RANDOM_BEND_NATIVE_BENCH),'bend2-clock-test'));
assert.equal(clock.status,0,clock.stderr);
const notices=run('node',['tests/bend2_license_test.mjs',resolve(dirname(process.env.RANDOM_BEND_NATIVE_BENCH),'..'),'random-bend2-bench']);
assert.equal(notices.status,0,notices.stderr);
const config=JSON.parse(readFileSync('profiling-bend2.json','utf8'));
const names=config.cases.map(c=>c.name);
const wanted=[];
for(const cores of [1,12]) for(const backend of ['bend-native','bend-js','zig','rust','luajit']) {
	for(const kind of ['bytes','d6','wide']) for(const metric of ['cpu','wall']) wanted.push(`${backend}-${kind}-${metric}-${cores}`);
	wanted.push(`${backend}-startup-${cores}`);
	const startup=run('experiments/bend2-startup',[`${backend}-startup-${cores}`,1024,42]);
	assert.equal(startup.status,0,startup.stderr);assert.ok(startup.stdout.startsWith('READY\n'));
}
assert.deepEqual([...names].sort(),wanted.sort(),'complete profiling case classifier');
assert.equal(new Set(names).size,names.length);
for(const args of [['invalid',1024,42],['zig-startup-1',1023,42],['zig-startup-1',1024,41]]) {
	assert.notEqual(run('experiments/bend2-startup',args).status,0,'invalid startup fixture accepted');
}
const interpreted=run('bend',['bend/Benchmark.bend',0,1,1,0,0,0,42]);
assert.notEqual(interpreted.status,0,'interpreted execution cannot masquerade as native timing');
assert.match(interpreted.stderr,/optimized native artifact/);
for(const backend of ['bend-native','zig','rust','luajit']) {
	const cli=run('node',['experiments/bend2-cli-profile.mjs',`${backend}-cli-1`,4096,42]);
	assert.equal(cli.status,0,cli.stderr);assert.equal(JSON.parse(cli.stdout).correct,true);
}
let cases=0;
for(const kind of [0,1,2]) for(const n of [1,64]) {
	const oracle=repeats=>{
		const result=run('luajit',['experiments/bend2_expected.lua',kind,n,repeats,42]);
		assert.equal(result.status,0,result.stderr);return JSON.parse(result.stdout);
	};
	const expected=oracle(2),first=oracle(1),warm=oracle(3);
	const args=[kind,n,2,expected.hash,first.hash,warm.hash,42];
	for(const command of [process.env.RANDOM_BEND_ZIG_BENCH,process.env.RANDOM_BEND_RUST_BENCH]) {
		const result=run(command,[kind,n,2,'-',0,0,42]);
		assert.equal(result.status,0,result.stderr);
		assert.deepEqual(JSON.parse(result.stdout),expected,'continuous-stream oracle cursor/checksum');
	}
	for(const [command,prefix] of [
		[process.env.RANDOM_BEND_NATIVE_BENCH,[]],
		[process.env.RANDOM_BEND_ZIG_BENCH,[]],
		[process.env.RANDOM_BEND_RUST_BENCH,[]],
		['node',['--expose-gc','experiments/bend2_js_bench.mjs']],
		['luajit',['experiments/bend2_lua_bench.lua']],
	]) {
		const result=run(command,[...prefix,...args]);
		assert.equal(result.status,0,`${command}: ${result.stderr}`);
		const [ready,text,...extra]=result.stdout.trimEnd().split('\n');
		assert.equal(ready,'READY');assert.equal(extra.length,0);
		const data=JSON.parse(text);assert.equal(data.correct,true);
		assert.equal(data.build_mode,config.identity.build_mode,'profiling engine build identity contract');
		assert.equal(data.iterations,2);assert.equal(data.rows[0].size,n);
		for(const metric of ['cpu_ns','wall_ns']) {
			assert.equal(data.rows[0].samples[metric].length,7);
			assert.ok(data.rows[0].samples[metric].every(x=>Number.isSafeInteger(x)&&x>0));
		}
		// Independent wrong-work controls: startup, warmup, and timed batch.
		if(n===1) for(const index of [3,4,5]) {
			const bad=[...args];bad[index]=(bad[index]+1)>>>0;
			const failure=run(command,[...prefix,...bad]);
			assert.notEqual(failure.status,0,`${command} accepted corrupted checksum ${index}`);
		}
		cases++;
	}
}
console.log(`bend2 benchmark controls: ${cases} five-backend work checks plus mutation/clock/source checks passed`);
