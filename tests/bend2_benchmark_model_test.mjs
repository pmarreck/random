import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const model=(await import(pathToFileURL(process.argv[2]))).default;
const jobs=[];
for (const seed of [1,42,12345]) for (const kind of [0,1,2]) {
	for (const n of [0,1,16,128,1024]) for (const repeats of [1,2,3]) jobs.push([seed,kind,n,repeats]);
}
const oracle=spawnSync('luajit',['-e',`package.path='./lib/?.lua;'..package.path
local b=require('blake3');local d=require('drbg');local bit=require('bit')
local function step(h,b) return bit.bxor(bit.rol(h,5),b) end
for line in io.lines() do
 local seed,kind,n,repeats=line:match('(%d+) (%d+) (%d+) (%d+)')
 seed=tonumber(seed);kind=tonumber(kind);n=tonumber(n)*tonumber(repeats)
 local r=d.new(b.hex_to_bin(string.format('%064x',seed)));local h=0
 if kind==0 then
  local bytes=r:bytes(n);for i=1,#bytes do h=step(h,bytes:byte(i)) end
 else
  local last=kind==1 and 6 or 4503599627370496
  for i=1,n do
   local v=r:range(1,last)
   h=step(step(h,v%4294967296),math.floor(v/4294967296))
  end
 end
 io.write(string.format('%.0f\\n',h<0 and h+4294967296 or h))
end`],{input:jobs.map(j=>j.join(' ')).join('\n')+'\n',encoding:'utf8'});
assert.equal(oracle.status,0,oracle.stderr);
const lines=oracle.stdout.trimEnd().split('\n');
assert.equal(lines.length,jobs.length);
for (let i=0;i<jobs.length;i++) {
	const [seed,kind,n,repeats]=jobs[i];
	const value=model.repeat(repeats,kind,n,model.key(seed),0);
	assert.equal(value.$,'Done');
	assert.equal(value.value,Number(lines[i]),`checksum ${seed}/${kind}/${n}`);
}
console.log(`bend2 benchmark model: ${jobs.length} independent work checks passed`);
