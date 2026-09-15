#!/usr/bin/env node
/**
 * Distribution artifacts: the two interface ABIs, their computed IDs, the
 * spec text, and a manifest carrying a sha256 for each file so a consumer can
 * tell whether what they hold is what this build produced.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Interface, toBeHex } = require('ethers');

const ROOT = path.join(__dirname, '..');
const DIST = path.join(ROOT, 'dist');
const NAMES = ['IRegisterProjection', 'IProjectionSettlement'];

fs.rmSync(DIST, { recursive: true, force: true });
fs.mkdirSync(path.join(DIST, 'abi'), { recursive: true });

const ids = {};
for (const name of NAMES) {
  const artifact = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'artifacts', `${name}.json`), 'utf8')
  );
  const abi = artifact.abi || artifact;
  fs.writeFileSync(path.join(DIST, 'abi', `${name}.json`), JSON.stringify(abi, null, 2) + '\n');
  const iface = new Interface(abi);
  let value = 0n;
  for (const f of iface.fragments) {
    if (f.type === 'function' && f.name !== 'supportsInterface') value ^= BigInt(f.selector);
  }
  ids[name] = toBeHex(value, 4);
}

fs.copyFileSync(path.join(ROOT, 'EIPS', 'eip-8415.md'), path.join(DIST, 'eip-8415.md'));

const sha256 = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else files.push(full);
  }
})(DIST);

const manifest = {
  name: 'erc-8415',
  interfaceIds: ids,
  files: Object.fromEntries(
    files.map((f) => [path.relative(DIST, f).split(path.sep).join('/'), sha256(f)])
  ),
};
fs.writeFileSync(path.join(DIST, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

console.log('[build] dist/ written');
for (const [k, v] of Object.entries(ids)) console.log(`  ${k} = ${v}`);
console.log(`  ${files.length + 1} files, manifest.json carries sha256 for each`);
