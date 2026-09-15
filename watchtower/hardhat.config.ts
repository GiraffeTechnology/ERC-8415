import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";

/// Compiler settings (version, EVM target, optimizer) are kept identical to `foundry.toml`, so both
/// toolchains emit the same runtime bytecode — byte for byte, apart from the trailing metadata hash —
/// and the Solidity and TypeScript suites exercise the same contract.
const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "paris",
      optimizer: { enabled: true, runs: 200 },
    },
  },
  paths: {
    sources: "contracts",
    tests: "test/hardhat",
    cache: "cache-hardhat",
    artifacts: "artifacts",
  },
};

export default config;
