import {readSourceBundle, assertProductionApproved} from './bundle.mjs';
try {
  if (process.argv.length !== 2) throw new Error('This release gate accepts no arguments');
  const {manifest} = readSourceBundle();
  assertProductionApproved(manifest);
} catch (error) { console.error(error.message); process.exitCode = 1; }
