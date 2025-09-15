const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  // Step 1. 部署基础模块
  const Guard = await ethers.getContractFactory("ComplianceGuardV2");
  const guard = await Guard.deploy(deployer.address, process.env.Verifier);
  console.log("=======参数传入成功=======");
  await guard.waitForDeployment();
  console.log("✔ComplianceGuardV2:", guard.target);

  const Registry = await ethers.getContractFactory("HolderRegistry1");
  const registry = await Registry.deploy(deployer.address);
  console.log("=======参数传入成功=======");
  await registry.waitForDeployment();
  console.log("✔HolderRegistry1:", registry.target);

  const Exchange = await ethers.getContractFactory("ExchangeModule");
  const exchange = await Exchange.deploy(process.env.SEPOLIA_USDT_ADDR, deployer.address);
  console.log("=======参数传入成功=======");
  await exchange.waitForDeployment();
  console.log("✔ExchangeModule:", exchange.target);

  const Principal = await ethers.getContractFactory("LPrincipal");
  const principal = await Principal.deploy("Principal-Token", "PWL-P", 1_000_000 * 1e6, exchange.target, deployer.address);
  console.log("=======参数传入成功=======");
  await principal.waitForDeployment();
  console.log("✔LPrincipal:", principal.target);

  const Interest = await ethers.getContractFactory("LInterest");
  const interest = await Interest.deploy("LInterest-Token", "PWL-I", deployer.address);
  console.log("=======参数传入成功=======");
  await interest.waitForDeployment();
  console.log("✔LInterest:", interest.target);

  const Accrual = await ethers.getContractFactory("AccrualModule");
  const accrual = await Accrual.deploy(deployer.address);
  console.log("=======参数传入成功=======");
  await accrual.waitForDeployment();
  console.log("✔AccrualModule:", accrual.target);

  const Manager = await ethers.getContractFactory("RWAManager");
  const manager = await Manager.deploy(deployer.address);
  console.log("=======参数传入成功=======");
  await manager.waitForDeployment();
  console.log("✔RWAManager:", manager.target);

  // Step 2. 配置布线
  // Guard <-> Tokens/Modules
  await (await principal.setGuard(guard.target)).wait();
  await (await interest.setGuard(guard.target)).wait();
  await (await principal.setRegistry(registry.target)).wait();
  await (await interest.setRegistry(registry.target)).wait();

  // Accrual 布线
  await (await accrual.wire(principal.target, interest.target, guard.target, registry.target)).wait();

  // Exchange 布线
  await (await exchange.wire(principal.target, guard.target, accrual.target, process.env.FEE_RECIPIENT)).wait();

  // Manager 配置
  await (await manager.setAddresses(
    guard.target,
    registry.target,
    principal.target,
    interest.target,
    accrual.target,
    exchange.target
  )).wait();

  await (await manager.wireRegistryAndManagers(
    [principal.target, interest.target, exchange.target, accrual.target],
    exchange.target,   // principal 的 manager
    accrual.target     // interest 的 manager
  )).wait();

  console.log("部署与初始化完成 ✅");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
