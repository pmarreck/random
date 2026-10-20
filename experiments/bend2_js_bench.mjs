// The same generated Bend work model, timed inside one warmed Node process.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {readFileSync} from 'node:fs';
assert.equal(typeof globalThis.gc,'function','use node --expose-gc');
assert.ok(!process.execArgv.some(x=>/jitless|no-opt/.test(x)),'optimized JS required');
const model=(await import(pathToFileURL(process.env.RANDOM_BEND_MODEL_MODULE))).default;
const [kind,n,repeats,expected,first,warm,seed]=process.argv.slice(2).map(Number);
assert.equal(process.argv.length,9);
for (const [v,lo,hi] of [[kind,0,2],[n,1,8192],[repeats,1,1000000],
	[expected,0,4294967295],[first,0,4294967295],[warm,0,4294967295],[seed,0,4294967295]]) {
	assert.ok(Number.isInteger(v) && v>=lo && v<=hi);
}
const key=model.key(seed);
function work(count) {
	const result=model.repeat(count,kind,n,key,0);
	assert.equal(result.$,'Done','generator failure');
	return result.value;
}
function settle() {
	let previous=Infinity;
	for(let i=0;i<32;i++) {
		globalThis.gc();
		const current=process.memoryUsage().heapUsed;
		if(current>=previous) return;
		previous=current;
	}
	throw new Error('heap did not settle outside timing');
}
assert.equal(work(1),first,'incorrect first work');
process.stdout.write('READY\n');
assert.equal(work(3),warm,'incorrect warmup');
const cpu=[],wall=[];
for(let sample=0;sample<7;sample++) {
	settle();
	const w0=process.hrtime.bigint(),c0=process.cpuUsage();
	const result=work(repeats);
	const c1=process.cpuUsage(c0),w1=process.hrtime.bigint();
	assert.equal(result,expected,'incorrect timed work');
	const cpuTotal=(c1.user+c1.system)*1000,wallTotal=Number(w1-w0);
	assert.ok(Number.isSafeInteger(cpuTotal) && Number.isSafeInteger(wallTotal));
	assert.ok(cpuTotal>0 && wallTotal>0);
	cpu.push(Math.floor(cpuTotal/repeats));wall.push(Math.floor(wallTotal/repeats));
	assert.ok(cpu.at(-1)>0 && wall.at(-1)>0);
}
const hwm=/^VmHWM:\s+(\d+) kB$/m.exec(readFileSync('/proc/self/status','utf8'));
assert.ok(hwm,'post-exec RSS unavailable');
const peakRss=Number(hwm[1])*1024;
assert.ok(Number.isSafeInteger(peakRss) && peakRss>0);
console.log(JSON.stringify({schema:'performance-measurement/v1',correct:true,
	build_mode:'optimized',backend_build_mode:'Node-V8-JIT',runtime:process.version,iterations:repeats,heap_settled:true,
	allocator_coverage:'JS/native allocation counters unavailable; supplemental high-water RSS only',
	rss_method:'Linux /proc/self/status VmHWM; supplemental approximate post-exec high water',
	peak_rss_bytes:peakRss,
	rows:[{size:n,samples:{cpu_ns:cpu,wall_ns:wall}}]}));
