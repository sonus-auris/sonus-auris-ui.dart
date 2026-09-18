import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const expectedAssets = new Map([
  ['mobile-eula.md', 'SONUS-EXT-MOBILE-EULA'],
  ['apple-platform-addendum.md', 'SONUS-EXT-APPLE'],
  ['mobile-subscription-agreement.md', 'SONUS-EXT-SUBSCRIPTION'],
]);
export function gitBlob(bytes) {
  return createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
}
export function validateBundle(manifest, files) {
  if (manifest.schemaVersion !== 1 || manifest.sourceRepository !== 'sonus-auris/sonus-auris-docs' ||
      !/^[a-f0-9]{40}$/.test(manifest.sourceCommit ?? '') || manifest.sourceContract !== 'contracts/mobile-legal.json') {
    throw new Error('Invalid legal source identity');
  }
  // Version 1 is intentionally review-only. A boolean edit cannot approve it.
  if (manifest.profile !== 'review-only' || manifest.approvedForRelease !== false) {
    throw new Error('Legal approval requires a separately reviewed release contract');
  }
  if (!Array.isArray(manifest.documents) || manifest.documents.length !== expectedAssets.size) {
    throw new Error('Unexpected legal document count');
  }
  const seen = new Set();
  for (const doc of manifest.documents) {
    if (expectedAssets.get(doc.asset) !== doc.id || seen.has(doc.asset) ||
        doc.path !== `docs/legal/external/additional/${doc.asset}`) {
      throw new Error('Unexpected, duplicate or non-external legal asset');
    }
    seen.add(doc.asset);
    const bytes = files.get(doc.asset);
    if (!Buffer.isBuffer(bytes) || !Number.isSafeInteger(doc.bytes) || doc.bytes <= 0 ||
        bytes.length !== doc.bytes || !/^[a-f0-9]{40}$/.test(doc.gitBlobSha ?? '') || gitBlob(bytes) !== doc.gitBlobSha) {
      throw new Error(`Legal asset integrity failure: ${doc.asset}`);
    }
    const text = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
    if (!text.includes(`\nid: ${doc.id}\n`) || !/^status: draft$/m.test(text) ||
        !/^approval_date: null$/m.test(text) || !/^effective_date: null$/m.test(text) ||
        !text.includes('DRAFT TEMPLATE — NOT AN EXECUTED AGREEMENT — NOT LEGAL ADVICE')) {
      throw new Error('Unreviewed legal metadata or missing warning');
    }
  }
  if (files.size !== expectedAssets.size || [...files.keys()].some(name => !seen.has(name))) {
    throw new Error('Unlisted legal files are prohibited');
  }
  return manifest;
}
export function readSourceBundle(directory = path.join(root, 'assets/legal')) {
  const files = new Map();
  const names = fs.readdirSync(directory);
  for (const name of names) {
    const full = path.join(directory, name);
    if (!fs.lstatSync(full).isFile()) throw new Error('Legal bundle must contain only regular files');
    if (name !== 'manifest.json') files.set(name, fs.readFileSync(full));
  }
  const manifestBytes = fs.readFileSync(path.join(directory, 'manifest.json'));
  const manifest = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(manifestBytes));
  validateBundle(manifest, files);
  return {manifest, manifestBytes, files};
}
export function assertProductionApproved(manifest) {
  // This release set has no legal approval. No env flag bypass is accepted.
  throw new Error(`LEGAL_RELEASE_BLOCKED: source ${manifest.sourceCommit} is a review-only legal bundle; complete legal approval and a reviewed release-contract change first`);
}
