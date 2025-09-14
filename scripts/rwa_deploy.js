// scripts/deploy.js
require("dotenv").config();
const { ethers } = require("hardhat");

const Owner_address = process.env.Owner_address;
const Guard_address = process.env.Guard_address;

//打印部署地址
const hre = require("hardhat");
console.log("============RPC URL =", hre.network.config.url);

// 创建函数部署合约
async function deploy(name, args = []) {
  // 将传入参数统一成数组
  if (!Array.isArray(args)) args = [args];
  // 去掉末尾多余的参数，避免被当作null传入
  while (args.length && (args[args.length - 1] === null || args[args.length - 1] === undefined)) { args.pop(); }
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(args);
  await contract.waitForDeployment();
  console.log(`✔ ${name} =>`, await contract.getAddress());
  return contract;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("============Deployer:", deployer.address);

  //1.部署ComplianceGuardLite
  const guard = await deploy("ComplianceGuardLite");

  //2.部署LoanManagerAccrualProLite
  let manager;
  try { manager = await deploy("LoanManagerAccrualProLite", [await guard.getAddress()]); }
  catch { manager = await deploy("LoanManagerAccrualProLite"); }
  const managerAddr = await manager.getAddress();

  //3.部署PrincipalToken和InterestToken（如果你的构造没有 owner 参数，就先不传，随后 transferOwnership 给 manager）
  const PrincipalToken_factory = await ethers.getContractFactory("PrincipalToken")
  const PrincipalToken_contract = await PrincipalToken_factory.deploy(Owner_address, managerAddr, Guard_address)
  await PrincipalToken_contract.waitForDeployment()
  console.log(`✔ PrincipalToken_contract =>`, await PrincipalToken_contract.getAddress())

  const InterestToken_factory = await ethers.getContractFactory("InterestToken")
  const InterestToken_contract = await InterestToken_factory.deploy(Owner_address, Guard_address)
  await InterestToken_contract.waitForDeployment()
  console.log(`✔ InterestToken_contracts =>`, await InterestToken_contract.getAddress())

  console.log(" ============ All contracts deployed successfully ============ ")

  // 4) 如需在 Manager 里登记两种 token 地址（按你的合约函数名选择调用）
  // if (manager.getFunction) {
  //   for (const sig of ["setTokens(address,address)", "setTokenAddresses(address,address)", "initializeTokens(address,address)"]) {
  //     try {
  //       const fn = manager.getFunction(sig);
  //       await (await fn(await pt.getAddress(), await it.getAddress())).wait();
  //       console.log("✔ Tokens registered via", sig);
  //       break;
  //     } catch { }
  //   }
  // }
}

main().catch((e) => { console.error(e); process.exit(1); });
