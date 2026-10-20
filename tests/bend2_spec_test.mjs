// Pin the predicates and domains imported by the laws, not just their wording.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

export function validate(spec, core, base) {
	assert.equal(spec.schema,'random-bend2-spec/v1');
	assert.equal(createHash('sha256').update(base).digest('hex'),spec.base_sha256,
		'the actual compiler Base/predicate source differs from the pinned specification');
	for (const [name, expected] of Object.entries(spec.declarations)) {
		assert.match(name,/^[A-Za-z_][A-Za-z_0-9]*$/);
		const pattern=new RegExp(`^type ${name} is (?:Data|Type):\\n(?:\\t[^\\n]+\\n)+`,'gm');
		const matches=[...core.matchAll(pattern)];
		assert.equal(matches.length,1,`specification type ${name} is missing or duplicated`);
		assert.equal(matches[0][0].replace(/\s/g,''),expected.replace(/\s/g,''),
			`specification type ${name} changed`);
	}
}

if (process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
	const spec=JSON.parse(readFileSync('tests/fixtures/bend2-spec.json','utf8'));
	const base=spawnSync('bend',['base'],{encoding:'utf8',timeout:10000});
	assert.equal(base.status,0,base.stderr);
	validate(spec,readFileSync(process.argv[2] ?? 'bend/Core.bend','utf8'),base.stdout);
}
