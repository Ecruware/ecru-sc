const path = require('path');
const fs = require('fs');

const TARGET_DIRECTORY = path.join(__dirname, '..', 'bindings');
const FILE_NAME = 'human-readable-abis.ts';
const FILE_PATH = path.join(TARGET_DIRECTORY, FILE_NAME);

async function main() {
  const contracts = [
    { name: 'Stablecoin', path: '../out/Stablecoin.sol/Stablecoin.json'},
    { name: 'CDM', path: '../out/CDM.sol/CDM.json'},
    { name: 'Buffer', path: '../out/Buffer.sol/Buffer.json'},
    { name: 'CDPVault_TypeA', path: '../out/CDPVault_TypeA.sol/CDPVault_TypeA.json'},
    { name: 'Minter', path: '../out/Minter.sol/Minter.json'},
    { name: 'Flashlender', path: '../out/Flashlender.sol/Flashlender.json'},
    { name: 'SwapAction', path: '../out/SwapAction.sol/SwapAction.json'},
    { name: 'PositionAction20', path: "../out/PositionAction20.sol/PositionAction20.json"},
    { name: 'PositionActionYV', path: '../out/PositionActionYV.sol/PositionActionYV.json'},
    { name: 'PRBProxyRegistry', path: '../out/IPRBProxyRegistry.sol/IPRBProxyRegistry.json' },
    { name: 'PRBProxy', path: '../out/PRBProxy.sol/PRBProxy.json' },
    { name: 'ERC20Permit', path: '../out/ERC20Permit.sol/ERC20Permit.json' },
    { name: 'ERC20', path: '../out/ERC20.sol/ERC20.json' },
    { name: 'ISignatureTransfer', path: '../out/ISignatureTransfer.sol/ISignatureTransfer.json' }
  ];

  const abis = {};
  contracts.map(({ name, path }) => {
    const jsonABI = require(path);
    abis[name] = [...jsonABI.abi];
  });

  const objectEntries = Object.entries(abis).map(([key, value]) => {
    return `${key}: ${JSON.stringify(value)} as const`;
  });

  const objectAsString = `export const abis = {\n  ${objectEntries.join(',\n  ')}\n};\n`;

  fs.mkdir(TARGET_DIRECTORY, { recursive: true }, (err) => {
    fs.writeFile(FILE_PATH, objectAsString, (err) => {
      if (err) {
        console.error('Error writing file:', err);
      } else {
        console.log(`TypeScript bindings created at ${FILE_PATH}`);
      }
    });
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});