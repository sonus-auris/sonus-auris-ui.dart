import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {root, readSourceBundle, validateBundle, assertProductionApproved, gitBlob} from './bundle.mjs';
const source = readSourceBundle();
const clone = () => structuredClone(source.manifest);
test('source bundle is valid and external only', () => assert.equal(validateBundle(clone(), source.files).documents.length, 3));
test('missing bytes fail', () => assert.throws(() => validateBundle(clone(), new Map()), /integrity/));
test('corrupt bytes fail', () => { const files=new Map(source.files);files.set('mobile-eula.md',Buffer.from('corrupted'));assert.throws(()=>validateBundle(clone(),files),/integrity/); });
test('unlisted private file fails', () => { const files=new Map(source.files);files.set('internal.md',Buffer.from('fixture'));assert.throws(()=>validateBundle(clone(),files),/Unlisted/); });
test('internal source path fails', () => { const m=clone();m.documents[0].path='docs/legal/internal/member.md';assert.throws(()=>validateBundle(m,source.files),/non-external/); });
test('duplicate document fails', () => { const m=clone();m.documents[1]=m.documents[0];assert.throws(()=>validateBundle(m,source.files),/duplicate/); });
test('floating source ref fails', () => { const m=clone();m.sourceCommit='main';assert.throws(()=>validateBundle(m,source.files),/identity/); });
test('approval boolean cannot approve draft', () => { const m=clone();m.approvedForRelease=true;assert.throws(()=>validateBundle(m,source.files),/approval/); });
test('profile change cannot approve draft', () => { const m=clone();m.profile='approved';assert.throws(()=>validateBundle(m,source.files),/approval/); });
test('removed draft warning fails even with refreshed hash', () => { const m=clone();const files=new Map(source.files);const d=m.documents[0];const bytes=Buffer.from(files.get(d.asset).toString('utf8').replace('DRAFT TEMPLATE','REMOVED'));files.set(d.asset,bytes);d.gitBlobSha=gitBlob(bytes);d.bytes=bytes.length;assert.throws(()=>validateBundle(m,files),/warning/); });
test('production gate fails closed', () => assert.throws(()=>assertProductionApproved(clone()),/LEGAL_RELEASE_BLOCKED/));
test('real source declaration check succeeds', () => execFileSync(process.execPath,['scripts/legal/verify-source.mjs'],{cwd:root}));
test('production executable returns failure', () => { const r=spawnSync(process.execPath,['scripts/legal/require-production.mjs'],{cwd:root,encoding:'utf8'});assert.equal(r.status,1);assert.match(r.stderr,/LEGAL_RELEASE_BLOCKED/); });
test('signed release helpers invoke legal gate before Flutter', () => {
 for(const name of ['android-build-aab.sh','android-build-apk.sh','ios-build-ipa.sh']){
  const text=fs.readFileSync(path.join(root,'scripts/release',name),'utf8');
  const gate=text.indexOf('node scripts/legal/require-production.mjs');
  assert.ok(gate>=0,name);assert.ok(gate<text.indexOf('flutter pub get'),name);
 }
});
