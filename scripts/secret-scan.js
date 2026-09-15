#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const ALLOWED = new Set([".github/workflows/ci.yml",".gitignore","EIPS/eip-8415.md","LICENSE","README.md","hardhat.config.cjs","interfaces/IProjectionSettlement.sol","interfaces/IRegisterProjection.sol","package-lock.json","package.json","reference/RegisterProjectionReference.sol","scripts/build.js","scripts/check-frozen-erc-constants.js","scripts/check-imports.js","scripts/flatten-artifacts.js","scripts/lint.js","scripts/secret-scan.js","test/protocol.cjs"]);
const SKIP = new Set(['.git', 'node_modules', 'artifacts', 'cache', 'dist']);
const failures = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue;
    const file = path.join(dir, entry.name);
    const rel = path.relative(ROOT, file).split(path.sep).join('/');
    if (entry.isDirectory()) { walk(file); continue; }
    if (!ALLOWED.has(rel)) failures.push(rel + ': outside publication allowlist');
    if (rel === 'scripts/secret-scan.js') continue;
    const content = fs.readFileSync(file, 'utf8');
    if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(content) ||
        /\bgh[pousr]_[A-Za-z0-9]{30,}\b/.test(content)) {
      failures.push(rel + ': possible credential');
    }
  }
}
walk(ROOT);
if (failures.length) {
  console.error('[secret-scan]', failures);
  process.exit(1);
}
console.log('[secret-scan] publication allowlist and credential checks passed');
