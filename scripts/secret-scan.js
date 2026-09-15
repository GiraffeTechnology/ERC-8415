#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const ALLOWED = new Set([
  ".github/workflows/ci.yml",
  ".gitignore",
  "COMPARISON.md",
  "EIPS/eip-8415.md",
  "ERCS/erc-8415-asynchronous-register-projection.md",
  "LICENSE",
  "RATIONALE.md",
  "README.md",
  "SECURITY.md",
  "hardhat.config.cjs",
  "interfaces/IProjectionSettlement.sol",
  "interfaces/IRegisterProjection.sol",
  "package-lock.json",
  "package.json",
  "reference/RegisterProjectionReference.sol",
  "scripts/build.js",
  "scripts/check-frozen-erc-constants.js",
  "scripts/check-imports.js",
  "scripts/flatten-artifacts.js",
  "scripts/lint.js",
  "scripts/secret-scan.js",
  "test/protocol.cjs",
  "watchtower/.gitignore",
  "watchtower/README.md",
  "watchtower/contracts/WatchtowerFreshnessLayer.sol",
  "watchtower/contracts/interfaces/IERC1271.sol",
  "watchtower/contracts/interfaces/IERC165.sol",
  "watchtower/contracts/interfaces/IWatchtowerFreshnessLayer.sol",
  "watchtower/contracts/libraries/FreshnessLib.sol",
  "watchtower/contracts/libraries/SignatureVerifier.sol",
  "watchtower/contracts/libraries/WatchtowerAttestationLib.sol",
  "watchtower/contracts/mocks/ERC1271Watchtower.sol",
  "watchtower/foundry.toml",
  "watchtower/hardhat.config.ts",
  "watchtower/package-lock.json",
  "watchtower/package.json",
  "watchtower/remappings.txt",
  "watchtower/test/foundry/Base.t.sol",
  "watchtower/test/foundry/Eip712.t.sol",
  "watchtower/test/foundry/Freshness.t.sol",
  "watchtower/test/foundry/KeyRotation.t.sol",
  "watchtower/test/foundry/Sequence.t.sol",
  "watchtower/test/hardhat/eip712.test.ts",
  "watchtower/test/hardhat/fixture.ts",
  "watchtower/test/hardhat/freshness.test.ts",
  "watchtower/test/hardhat/keyRotation.test.ts",
  "watchtower/test/hardhat/sequence.test.ts",
  "watchtower/tsconfig.json",
]);
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
