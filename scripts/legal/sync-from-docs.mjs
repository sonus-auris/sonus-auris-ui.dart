import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {root, validateBundle} from './bundle.mjs';
try {
  if (process.argv.length !== 2) throw new Error('Use SONUS_LEGAL_SOURCE_DIR; no CLI arguments accepted');
  const requested = process.env.SONUS_LEGAL_SOURCE_DIR;
  if (!requested) throw new Error('SONUS_LEGAL_SOURCE_DIR must identify an authorized docs checkout');
  const source = fs.realpathSync(requested);
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'assets/legal/manifest.json'), 'utf8'));
  const actualCommit = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
  if (actualCommit !== manifest.sourceCommit) throw new Error('Docs checkout is not the pinned source commit');
  const contract = JSON.parse(execFileSync('git', ['-C', source, 'show', `${actualCommit}:contracts/mobile-legal.json`], {encoding: 'utf8'}));
  if (contract.sourceRepository !== manifest.sourceRepository || contract.profile !== 'review-only' || contract.approvedForRelease !== false ||
      JSON.stringify(contract.documents) !== JSON.stringify(manifest.documents.map(({id, path: sourcePath, asset}) => ({id, path: sourcePath, asset})))) {
    throw new Error('Canonical mobile allowlist differs from consumer manifest');
  }
  // Read committed bytes, not a potentially dirty local working copy.
  const files = new Map(manifest.documents.map(doc => [doc.asset,
    execFileSync('git', ['-C', source, 'show', `${actualCommit}:${doc.path}`], {maxBuffer: 1024 * 1024})]));
  validateBundle(manifest, files);
  for (const [name, bytes] of files) fs.writeFileSync(path.join(root, 'assets/legal', name), bytes);
  console.log('Synchronized only the pinned external legal snapshot files; review and commit explicit paths');
} catch (error) { console.error(error.message); process.exitCode = 1; }
