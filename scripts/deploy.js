const hre = require('hardhat');
const fs = require('fs');
const path = require('path');

const CONFIG = require('./config.js');

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);
const toWad = ethers.utils.parseEther;
const fromWad = ethers.utils.formatEther;
const toBytes32 = ethers.utils.formatBytes32String;

function convertBigNumberToString(value) {
  if (ethers.BigNumber.isBigNumber(value)) return value.toString();
  if (value instanceof Array) return value.map((v) => convertBigNumberToString(v));
  if (value instanceof Object) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, convertBigNumberToString(v)]));
  return value;
}

async function getSignerAddress() {
  return (await (await ethers.getSigners())[0].getAddress());
}

async function verifyOnTenderly(name, address) {
  if (hre.network.name != 'tenderly') return;
  console.log('Verifying on Tenderly...');
  try {
    await hre.tenderly.verify({ name, address });
    console.log('Verified on Tenderly');
  } catch (error) {
    console.log('Failed to verify on Tenderly');
  }
}

async function getDeploymentFilePath() {
  return path.join(__dirname, '.', `deployment-${hre.network.name}.json`);
}

async function storeContractDeployment(isVault, name, address, artifactName, constructorArguments) {
  const deploymentFilePath = await getDeploymentFilePath();
  const deploymentFile = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  if (constructorArguments) constructorArguments = convertBigNumberToString(constructorArguments);
  if (isVault) {
    if (deploymentFile.vaults == undefined) deploymentFile.vaults = {};
    deploymentFile.vaults[name] = { address, artifactName, constructorArguments: constructorArguments || []};
  } else {
    if (deploymentFile.core == undefined) deploymentFile.core = {};
    deploymentFile.core[name] = { address, artifactName, constructorArguments: constructorArguments || []};
  }
  fs.writeFileSync(deploymentFilePath, JSON.stringify(deploymentFile, null, 2));
}

async function storeEnvMetadata(metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.environment == undefined) metadataFile.environment = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.environment = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function storeVaultMetadata(address, metadata) {
  const metadataFilePath = path.join(__dirname, '.', `metadata-${hre.network.name}.json`);
  const metadataFile = fs.existsSync(metadataFilePath) ? JSON.parse(fs.readFileSync(metadataFilePath)) : {};
  if (metadataFile.vaults == undefined) metadataFile.vaults = {};
  metadata = convertBigNumberToString(metadata);
  metadataFile.vaults[address] = { ...metadata };
  fs.writeFileSync(metadataFilePath, JSON.stringify(metadataFile, null, 2));
}

async function loadDeployedContracts() {
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};
  for (let [name, { address, artifactName }] of Object.entries({ ...deployment.core, ...deployment.vaults })) {
    contracts[name] = (await ethers.getContractFactory(artifactName)).attach(address);
  }
  return contracts;
}

async function loadDeployedVaults() {
  const deploymentFilePath = await getDeploymentFilePath();
  const deployment = fs.existsSync(deploymentFilePath) ? JSON.parse(fs.readFileSync(deploymentFilePath)) : {};
  const contracts = {};
  for (let [name, { address, artifactName }] of Object.entries({ ...deployment.vaults })) {
    contracts[name] = (await ethers.getContractFactory(artifactName)).attach(address);
  }
  return contracts;
}

async function attachContract(name, address) {
  return await ethers.getContractAt(name, address);
}

async function deployContract(name, artifactName, ...args) {
  const Contract = await ethers.getContractFactory(name);
  const contract = await Contract.deploy(...args);
  await contract.deployed();
  console.log(`${artifactName || name} deployed to: ${contract.address}`);
  await verifyOnTenderly(name, contract.address);
  await storeContractDeployment(false, artifactName || name, contract.address, name, args);
  return contract; 
}

async function deployVault(vaultName, artifactName, vaultFactory, ...args) {
  const tx = await vaultFactory.create(...args);
  const receipt = await tx.wait();
  let vaultAddress = receipt.events?.find(e => e.event === 'CreateVault')?.args[0];
  if (!vaultAddress) throw new Error('Failed to create vault');
  console.log(`${vaultName} deployed to: ${vaultAddress}`);
  await verifyOnTenderly(artifactName, vaultAddress);
  await storeContractDeployment(true, vaultName, vaultAddress, artifactName, args);
  return await attachContract('CDPVault_TypeA', vaultAddress);
}

async function deployProxy(name, implementationArgs, proxyArgs) {
  const ProxyAdmin = await ethers.getContractFactory('ProxyAdmin');
  const proxyAdmin = await ProxyAdmin.deploy();
  await proxyAdmin.deployed();
  console.log(`${name}'s ProxyAdmin deployed to: ${proxyAdmin.address}`);
  await verifyOnTenderly('ProxyAdmin', proxyAdmin.address);
  await storeContractDeployment(false, `${name}ProxyAdmin`, proxyAdmin.address, 'ProxyAdmin');
  const Implementation = await ethers.getContractFactory(name);
  const implementation = await Implementation.deploy(...implementationArgs);
  await implementation.deployed();
  console.log(`${name}'s implementation deployed to: ${implementation.address}`);
  await verifyOnTenderly(name, implementation.address);
  await storeContractDeployment(false, `${name}Implementation`, implementation.address, name);
  const Proxy = await ethers.getContractFactory('TransparentUpgradeableProxy');
  // const initializeEncoded = Implementation.interface.getSighash(Implementation.interface.getFunction('initialize'));
  const initializeEncoded = Implementation.interface.encodeFunctionData('initialize', proxyArgs);
  const proxy = await Proxy.deploy(implementation.address, proxyAdmin.address, initializeEncoded);
  await proxy.deployed();
  console.log(`${name}'s proxy deployed to: ${proxy.address}`);
  await verifyOnTenderly('TransparentUpgradeableProxy', proxy.address);
  await storeContractDeployment(
    false, name, proxy.address, name, [implementation.address, proxyAdmin.address, initializeEncoded]
  );
  return (await ethers.getContractFactory(name)).attach(proxy.address);
}

async function deployPRBProxy(prbProxyRegistry) {
  const signer = await getSignerAddress();
  let proxy = (await ethers.getContractFactory('PRBProxy')).attach(await prbProxyRegistry.getProxy(signer));
  if (proxy.address == ethers.constants.AddressZero) {
    await prbProxyRegistry.deploy();
    proxy = (await ethers.getContractFactory('PRBProxy')).attach(await prbProxyRegistry.getProxy(signer));
    console.log(`PRBProxy deployed to: ${proxy.address}`);
    await verifyOnTenderly('PRBProxy', proxy.address);
    await storeContractDeployment(false, 'PRBProxy', proxy.address, 'PRBProxy');
  }
  return proxy;
}

async function deployCore() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                         DEPLOYING CORE
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();

  if (hre.network.name == 'tenderly') {
    await ethers.provider.send('tenderly_setBalance', [[signer], ethers.utils.hexValue(toWad('100').toHexString())]);
  }

  const cdm = await deployContract('CDM', 'CDM',  signer, signer, signer);
  await cdm["setParameter(bytes32,uint256)"](toBytes32("globalDebtCeiling"), CONFIG.Core.CDM.initialGlobalDebtCeiling);

  const stablecoin = await deployContract('Stablecoin');
  const minter = await deployContract('Minter', 'Minter', cdm.address, stablecoin.address, signer, signer);
  const flashlender = await deployContract('Flashlender', 'Flashlender', minter.address, CONFIG.Core.Flashlender.constructorArguments.protocolFee_);
  await deployProxy('Buffer', [cdm.address], [signer, signer]);
  await deployContract('MockOracle');

  // await deployContract('PRBProxyRegistry');
  storeEnvMetadata({PRBProxyRegistry: CONFIG.Core.PRBProxyRegistry});

  const swapAction = await deployContract(
   'SwapAction', 'SwapAction', ...Object.values(CONFIG.Core.Actions.SwapAction.constructorArguments)
  );
  const joinAction = await deployContract(
   'JoinAction', 'JoinAction', ...Object.values(CONFIG.Core.Actions.JoinAction.constructorArguments)
  );

  await deployContract('ERC165Plugin');
  await deployContract('PositionAction20', 'PositionAction20', flashlender.address, swapAction.address, joinAction.address);
  await deployContract('PositionActionYV', 'PositionActionYV', flashlender.address, swapAction.address, joinAction.address);
  await deployContract('PositionAction4626', 'PositionAction4626', flashlender.address, swapAction.address, joinAction.address);

  const cdpVaultTypeADeployer = await deployContract('CDPVault_TypeA_Deployer');
  const cdpVaultTypeAFactory = await deployContract(
    'CDPVault_TypeA_Factory',
    'CDPVault_TypeA_Factory',
    cdpVaultTypeADeployer.address,
    signer, // roleAdmin
    signer, // deployerAdmin
    signer // deployer
  );

  console.log('------------------------------------');

  await stablecoin.grantRole(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_AND_BURNER_ROLE")), minter.address);
  console.log('Granted MINTER_AND_BURNER_ROLE to Minter');

  await cdm.grantRole(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ACCOUNT_CONFIG_ROLE")), cdpVaultTypeAFactory.address);
  console.log('Granted ACCOUNT_CONFIG_ROLE to CDPVault_TypeA_Factory');

  await cdm["setParameter(address,bytes32,uint256)"](flashlender.address, toBytes32("debtCeiling"), CONFIG.Core.Flashlender.initialDebtCeiling);
  console.log('Set debtCeiling to', fromWad(CONFIG.Core.Flashlender.initialDebtCeiling), 'Credit for Flashlender');

  console.log('------------------------------------');
}

async function deployAuraVaults() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING AURA VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const {
    MockOracle: oracle,
  } = await loadDeployedContracts();

  for (const [key, config] of Object.entries(CONFIG.Vendors.AuraVaults)) {
    const vaultName = key;
    const constructorArguments = [
      config.rewardPool,
      config.asset,
      oracle.address,
      config.maxClaimerIncentive,
      config.maxLockerIncentive,
      config.tokenName,
      config.tokenSymbol
    ];
    await oracle.updateSpot(config.asset, config.feed.defaultPrice);
    console.log('Updated default price for', config.asset, 'to', fromWad(config.feed.defaultPrice), 'USD');

    const auraVault = await deployContract("AuraVault", vaultName, ...Object.values(constructorArguments));

    console.log('------------------------------------');
    console.log('Deployed ', vaultName, 'at', auraVault.address);
    console.log('------------------------------------');
    console.log('');
  }
}

async function deployVaults() {
  console.log(`
/*//////////////////////////////////////////////////////////////
                        DEPLOYING VAULTS
//////////////////////////////////////////////////////////////*/
  `);

  const signer = await getSignerAddress();
  const {
    CDM: cdm,
    MockOracle: oracle,
    Buffer: buffer,
    CDPVault_TypeA_Factory: vaultFactory,
    ...contracts
  } = await loadDeployedContracts();
  
  for (const [key, config] of Object.entries(CONFIG.Vaults)) {
    const vaultName = `CDPVault_TypeA_${key}`;
    console.log('deploying vault ', vaultName);

    var token;
    var tokenAddress = config.token;

    // initialize the token
    if (tokenAddress != "") {
      token = await attachContract('ERC20PresetMinterPauser', tokenAddress);
    } else {
      // search for the token in the deployed contracts
      token = contracts[config.tokenName];
      tokenAddress = token.address;
    }

    const tokenScale = new ethers.BigNumber.from(10).pow(await token.decimals());
    const cdpVault_TypeA = await deployVault(
      vaultName,
      'CDPVault_TypeA',
      vaultFactory,
      [
        cdm.address,
        oracle.address,
        buffer.address,
        tokenAddress,
        tokenScale,
        ...Object.values(config.deploymentArguments.params)
      ],
      [...Object.values(config.deploymentArguments.paramsTypeA)],
      [...Object.values(config.deploymentArguments.configs).map((v) => v === "deployer" ? signer : v)],
      config.deploymentArguments.debtCeiling
    );
    
    console.log('------------------------------------');

    console.log('Initialized', vaultName, 'with a debt ceiling of', fromWad(config.deploymentArguments.debtCeiling), 'Credit');

    await oracle.updateSpot(tokenAddress, config.oracle.defaultPrice);
    console.log('Updated default price for', key, 'to', fromWad(config.oracle.defaultPrice), 'USD');

    const limitPriceTicks = config.exchange.limitPriceTicks.sort((a, b) => a.gt(b) ? 1 : -1);
    for (const tick of limitPriceTicks) {
      await cdpVault_TypeA.addLimitPriceTick(tick, 0);
      console.log('Added limit price tick of', fromWad(tick));
    }

    const underlier = (config.collateralType === "ERC4626")
      ? await attachContract('ERC20PresetMinterPauser', config.underlier) : null;

    await storeVaultMetadata(
        cdpVault_TypeA.address,
      {
        contractName: vaultName,
        name: config.name,
        description: config.description,
        artifactName: 'CDPVault_TypeA',
        collateralType: config.collateralType,
        cdm: cdm.address,
        oracle: oracle.address,
        buffer: buffer.address,
        token: tokenAddress,
        tokenScale: tokenScale,
        tokenSymbol: await token.symbol(),
        tokenName: config.tokenName,
        tokenIcon: config.tokenIcon,
        underlier: (config.collateralType === "ERC4626")
          ? config.underlier : null,
        underlierScale: (config.collateralType === "ERC4626")
          ? new ethers.BigNumber.from(10).pow(await underlier.decimals()) : null,
        underlierSymbol: (config.collateralType === "ERC4626")
          ? await underlier.symbol() : null,
        underlierName: (config.collateralType === "ERC4626") ? config.underlierName : null,
        underlierIcon: (config.collateralType === "ERC4626") ? config.underlierIcon : null,
        protocolName: (config.collateralType === "ERC4626") ? config.protocolName : null,
        protocolIcon: (config.collateralType === "ERC4626") ? config.protocolIcon : null,
        protocolFee: config.deploymentArguments.params.protocolFee,
        targetUtilizationRatio: config.deploymentArguments.params.targetUtilizationRatio,
        maxUtilizationRatio: config.deploymentArguments.params.maxUtilizationRatio,
        minInterestRate: config.deploymentArguments.params.minInterestRate,
        maxInterestRate: config.deploymentArguments.params.maxInterestRate,
        targetInterestRate: config.deploymentArguments.params.targetInterestRate,
        rebateRate: config.deploymentArguments.params.rebateRate,
        maxRebate: config.deploymentArguments.params.maxRebate
      }
    );

    console.log('------------------------------------');
    console.log('');
  }
}

async function logVaults() {
  const { CDM: cdm } = await loadDeployedContracts()
  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    console.log(`${name}: ${vault.address}`);
    console.log('  debtCeiling:', fromWad(await cdm.creditLine(vault.address)));
    const vaultConfig = await vault.vaultConfig();
    console.log('  debtFloor:', fromWad(vaultConfig.debtFloor));
    console.log('  liquidationRatio:', fromWad(vaultConfig.liquidationRatio));
    console.log('  globalLiquidationRatio:', fromWad(vaultConfig.globalLiquidationRatio));
    const liquidationConfig = await vault.liquidationConfig();
    console.log('  liquidationPenalty:', fromWad(liquidationConfig.liquidationPenalty));
    console.log('  liquidationDiscount:', fromWad(liquidationConfig.liquidationDiscount));
    console.log('  targetHealthFactor:', fromWad(liquidationConfig.targetHealthFactor));
    console.log('  limitOrderFloor:', fromWad(await vault.limitOrderFloor()));
  }
}

async function createPositions() {
  const { CDM: cdm, PositionAction20: positionAction } = await loadDeployedContracts();
  const prbProxyRegistry = await attachContract('PRBProxyRegistry', CONFIG.Core.PRBProxyRegistry);

  const signer = await getSignerAddress();
  const proxy = await deployPRBProxy(prbProxyRegistry);

  // anvil or tenderly
  try {
    const ethPot = await ethers.getImpersonatedSigner('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2');
    await ethPot.sendTransaction({ to: signer, value: toWad('10') });
  } catch {
    const ethPot = (new ethers.providers.JsonRpcProvider(process.env.TENDERLY_FORK_URL)).getSigner('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2');
    await ethPot.sendTransaction({ to: signer, value: toWad('10') });
  }
  console.log('Sent 10 ETH to', signer);

  for (const [name, vault] of Object.entries(await loadDeployedVaults())) {
    let token = await attachContract('ERC20PresetMinterPauser', await vault.token());
    const config = Object.values(CONFIG.Vaults).find((v) => v.token.toLowerCase() == token.address.toLowerCase());
    console.log(`${name}: ${vault.address}`);

    const amountInWad = config.deploymentArguments.configs.debtFloor.mul('5').add(toWad('1'));
    const amount = amountInWad.mul(await vault.tokenScale()).div(toWad('1'));
    await token.approve(proxy.address, amount);

    // anvil or tenderly
    try {
      token = token.connect(await ethers.getImpersonatedSigner(config.tokenPot));
      await token.transfer(signer, amount);
    } catch {
      token = token.connect((new ethers.providers.JsonRpcProvider(process.env.TENDERLY_FORK_URL)).getSigner(config.tokenPot));
      await token.transfer(signer, amount);
    }
    console.log('Sent', fromWad(amountInWad), await token.symbol(), 'signer');

    await proxy.execute(
      positionAction.address,
      positionAction.interface.encodeFunctionData(
        'depositAndBorrow',
        [
          proxy.address,
          vault.address,
          [token.address, amount, signer, [0, 0, ethers.constants.AddressZero, 0, 0, ethers.constants.AddressZero, 0, ethers.constants.HashZero]],
          [config.deploymentArguments.configs.debtFloor, signer, [0, 0, ethers.constants.AddressZero, 0, 0, ethers.constants.AddressZero, 0, ethers.constants.HashZero]],
          [0, 0, 0, 0, 0, ethers.constants.HashZero, ethers.constants.HashZero]
      ]
      ),
      { gasLimit: 2000000 }
    );
    
    const position = await vault.positions(proxy.address);
    console.log('Borrowed', fromWad(position.normalDebt), 'Credit against', fromWad(position.collateral), await token.symbol());
  }
}

((async () => {
  await deployCore();
  await deployAuraVaults();
  await deployVaults();
  // await logVaults();
  // await createPositions();
})()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
