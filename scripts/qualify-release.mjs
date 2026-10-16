#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { REQUIRED_RELEASE_CHECKS, qualificationIdentity, qualificationCandidateMatches, validateQualification } from './lib/release-qualification.mjs';
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key,canonical(value[key])])) : value;
const same = (a,b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
const [mode, manifestFile, receiptFile, evidenceDirectory, outputFile] = process.argv.slice(2);
try {
  if (!['--prepare','--verify','--qualify'].includes(mode) || !manifestFile || !receiptFile) throw Error('Usage: qualify-release.mjs --prepare MANIFEST RECEIPT | --verify MANIFEST RECEIPT EVIDENCE_DIR | --qualify MANIFEST RECEIPT EVIDENCE_DIR OUTPUT_MANIFEST');
  const release = JSON.parse(fs.readFileSync(manifestFile));
  if (mode === '--prepare') {
    const receipt = { schema: 1, candidate: qualificationIdentity(release), completed_at: null,
      blockers: ['Installed, physical, hosted and compatibility acceptance pending.'],
      checks: Object.fromEntries(Object.entries(REQUIRED_RELEASE_CHECKS).map(([id,kind]) => [id,{ kind, status:'pending', observed_at:null,
        candidate: qualificationIdentity(release), evidence:[] }])) };
    fs.writeFileSync(receiptFile, JSON.stringify(receipt,null,2)+'\n', {flag:'wx', mode:0o600});
    console.log('Prepared pending qualification. No download was enabled.');
  } else {
    if (!evidenceDirectory) throw Error('Evidence directory is required');
    const qualification = JSON.parse(fs.readFileSync(receiptFile));
    const result = validateQualification(release, qualification);
    if (!result.ok) throw Error(result.reason);
    const root = fs.realpathSync(evidenceDirectory);
    for (const [id,check] of Object.entries(qualification.checks)) {
      let verifiedRecord = false;
      for (const evidence of check.evidence) {
        const file = fs.realpathSync(path.join(root,evidence.path));
        if (!file.startsWith(root+path.sep) || !fs.statSync(file).isFile()) throw Error('Evidence escapes its directory');
        const hash = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
        if (hash !== evidence.sha256) throw Error(`Evidence changed: ${evidence.path}`);
        if (path.extname(file).toLowerCase() === '.json') {
          const record = JSON.parse(fs.readFileSync(file,'utf8'));
          if (record.check_id !== id) continue;
          if (record.kind !== check.kind || record.status !== 'passed' || record.observed_at !== check.observed_at
              || !qualificationCandidateMatches(record.candidate, qualificationIdentity(release))
              || !same(record.environment,check.environment) || !same(record.metrics,check.metrics)) {
            throw Error(`Evidence record does not match check or candidate: ${id}`);
          }
          verifiedRecord = true;
        }
      }
      if (!verifiedRecord) throw Error(`Missing matching JSON evidence record: ${id}`);
    }
    for (const artifact of Object.values(release.installers)) {
      if (typeof artifact.asset !== 'string' || !/^[a-zA-Z0-9_.-]+\.pkg$/.test(artifact.asset)
          || path.basename(artifact.asset) !== artifact.asset) throw Error('Invalid package asset path');
      const file = path.join(path.dirname(manifestFile),artifact.asset);
      if (fs.statSync(file).size !== artifact.size_bytes || createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== artifact.sha256) throw Error(`Package changed: ${artifact.asset}`);
    }
    if (mode === '--qualify') {
      if (!outputFile || release.notarized !== true || release.firefox_extension_signed !== true || release.chrome_web_store_approved !== true
          || release.chrome_web_store_version !== release.chrome_extension_version || release.channel !== 'launch'
          || release.website_adder_enabled !== false || release.automatic_update_checks_enabled !== false) throw Error('Distribution or output gate incomplete');
      fs.writeFileSync(outputFile,JSON.stringify({...release,qualification,distribution_ready:true},null,2)+'\n',{flag:'wx',mode:0o600});
    }
    console.log('Qualification evidence and exact package hashes verified.');
  }
} catch(error) { console.error(`Release remains blocked: ${error.message}`); process.exitCode=1; }
