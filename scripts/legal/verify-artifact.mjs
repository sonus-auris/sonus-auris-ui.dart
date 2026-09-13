import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {readSourceBundle, validateBundle} from './bundle.mjs';

// Inspect, never extract, archive members. No archive path is used for writes.
function archiveFiles(artifact) {
  const names = execFileSync('unzip', ['-Z1', artifact], {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}).trim().split(/\r?\n/);
  const matches = names.filter(name => name.endsWith('/flutter_assets/assets/legal/manifest.json'));
  if (matches.length !== 1) throw new Error('Expected exactly one packaged legal manifest');
  const prefix = matches[0].slice(0, -'manifest.json'.length);
  const files = new Map();
  for (const name of names.filter(name => name.startsWith(prefix) && !name.endsWith('/'))) {
    const relative = name.slice(prefix.length);
    if (relative.includes('/') || files.has(relative)) throw new Error('Nested or duplicate packaged legal file');
    files.set(relative, execFileSync('unzip', ['-p', artifact, name], {maxBuffer: 1024 * 1024}));
  }
  return files;
}
function directoryFiles(artifact) {
  const matches = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const full = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) visit(full);
      else if (full.endsWith(`${path.sep}flutter_assets${path.sep}assets${path.sep}legal${path.sep}manifest.json`)) matches.push(full);
    }
  }
  visit(artifact);
  if (matches.length !== 1) throw new Error('Expected exactly one application legal manifest');
  const directory = path.dirname(matches[0]);
  return new Map(fs.readdirSync(directory).map(name => {
    const full = path.join(directory, name);
    if (!fs.lstatSync(full).isFile()) throw new Error('Non-regular packaged legal file');
    return [name, fs.readFileSync(full)];
  }));
}
try {
  if (process.argv.length !== 2) throw new Error('Use SONUS_LEGAL_ARTIFACT for this build check');
  const requested = process.env.SONUS_LEGAL_ARTIFACT;
  if (!requested) throw new Error('SONUS_LEGAL_ARTIFACT is required');
  const artifact = path.resolve(requested);
  const stat = fs.lstatSync(artifact);
  if (stat.isSymbolicLink()) throw new Error('Artifact symlink is not allowed');
  const packaged = stat.isDirectory() ? directoryFiles(artifact) : archiveFiles(artifact);
  const source = readSourceBundle();
  const manifestBytes = packaged.get('manifest.json');
  if (!manifestBytes?.equals(source.manifestBytes)) throw new Error('Packaged manifest differs from source');
  packaged.delete('manifest.json');
  validateBundle(JSON.parse(manifestBytes.toString('utf8')), packaged);
  for (const [name, bytes] of source.files) if (!packaged.get(name)?.equals(bytes)) throw new Error('Packaged bytes differ from reviewed snapshot');
  console.log(`PASS: ${source.files.size} exact external legal review assets in ${path.basename(artifact)}`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
