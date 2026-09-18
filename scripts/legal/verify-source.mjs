import fs from 'node:fs';
import path from 'node:path';
import {root, readSourceBundle} from './bundle.mjs';
try {
  if (process.argv.length !== 2) throw new Error('This build check accepts no arguments');
  const {manifest, files} = readSourceBundle();
  const pubspec = fs.readFileSync(path.join(root, 'pubspec.yaml'), 'utf8');
  for (const name of ['manifest.json', ...files.keys()]) {
    if (!pubspec.split('\n').some(line => line.trim() === `- assets/legal/${name}`)) {
      throw new Error(`Asset is not explicitly declared in pubspec: ${name}`);
    }
  }
  console.log(`PASS: ${files.size} external review assets match ${manifest.sourceCommit}; no legal approval implied`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
