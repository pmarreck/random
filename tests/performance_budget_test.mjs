// Real engine/child deadline control, separate from any RNG or timing verdict.
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
const engine = process.argv[2] ?? process.env.RANDOM_PROFILE_ENGINE ?? 'performance-profile';
const scratch = mkdtempSync(join(tmpdir(), 'random-profile-budget-'));
const root = join(scratch, 'project'), history = join(scratch, 'history');
mkdirSync(root); mkdirSync(history);
function run(cmd, args, cwd = root) {
	const r = spawnSync(cmd, args, {cwd, encoding:'utf8', timeout:20000, maxBuffer:2<<20});
	assert.equal(r.error, undefined, String(r.error)); return r;
}
try {
	writeFileSync(join(root, 'probe.lua'), `require('luv').sleep(50)
io.write(' {"schema":"performance-measurement/v1","correct":true,"build_mode":"optimized","rows":[{"size":1,"samples":{"operations":[1,1,1]}}]}\\n')
`);
	for (const args of [['init','-q','-b','yolo'], ['-c','user.name=budget-test','-c','user.email=budget@example.invalid','add','.'],
		['-c','user.name=budget-test','-c','user.email=budget@example.invalid','commit','-qm','fixture']]) {
		const r = run('git', args); assert.equal(r.status, 0, r.stderr);
	}
	const make = (name, timeout_ms) => ({name, cores:1, definition:'declared-deadline-control-v1', mode:'bm', metric:'operations',
		comparison:'absolute', command:['luajit','probe.lua'], sizes:[1], bounds:[1,1], ...(timeout_ms === undefined ? {} : {timeout_ms})});
	const cfg = {schema:'performance-project/v1', project:'random_budget_control', history_url:'file://' + history,
		identity:{runtime:'LuaJIT', build_mode:'optimized', concurrency:1},
		cases:[make('default-budget'),make('short-budget',5),make('long-budget',5000)]};
	const path = join(root, 'profiling.json'); writeFileSync(path, JSON.stringify(cfg));
	const r = run(engine, ['run','--config',path,'--seed','42']);
	assert.equal(r.status, 1, 'short case must time out, not silently use the default deadline: ' + r.stderr);
	const records = JSON.parse(r.stdout), byName = Object.fromEntries(records.map(x => [x.case,x]));
	assert.equal(records.length, 3);
	for (const [name, limit] of [['default-budget',30000], ['long-budget',5000]]) {
		const observed = byName[name]; assert.equal(observed.verdict, 'UNBASELINED');
		assert.equal(observed.candidate.raw.correct, true); assert.equal(observed.definition.timeout_ms, limit);
	}
	const short = byName['short-budget']; assert.equal(short.verdict, 'INVALID');
	assert.equal(short.candidate.raw.process.timed_out, true); assert.equal(short.attempts, 1);
	assert.equal(short.definition.timeout_ms, 5);
	for (const invalid of [0,-1,1.5,'1000',3600001]) {
		cfg.cases = [make('invalid-budget', invalid)]; writeFileSync(path, JSON.stringify(cfg));
		const failed = run(engine, ['run','--config',path,'--seed','42']);
		assert.equal(failed.status, 1, 'invalid deadline accepted: ' + invalid);
		assert.match(failed.stderr, /deadline|timeout/);
	}
	console.log('Profiling deadline: default/short/long child behavior, durable budgets and five invalid-domain refusals passed');
} finally {
	const cleanup = run('bash', ['-c', 'source "$1"; test_trash "$2"', '--', resolve('tests/fixture-cleanup.sh'), scratch], process.cwd());
	assert.equal(cleanup.status, 0, cleanup.stderr);
}
