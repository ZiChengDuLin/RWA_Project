#!/usr/bin/env node
/**
 * Hardhat(CJS) + ethers v6 交互脚本
 * 与 LoanManagerAccrualProLite / ComplianceGuardLite / PrincipalToken / InterestToken 交互
 *
 * 运行示例：
 *   npx hardhat run --network sepolia scripts/interact.js info
 *   npx hardhat run --network sepolia scripts/interact.js balances 0xAlice 0xBob
 */

require("dotenv").config();
const hre = require("hardhat");
const { ethers, network } = hre;

// ---------- 环境变量（地址） ----------
let {
  ComplianceGuardLite_Contract_Address,
  LoanManagerAccrualProLite_Contract_Address,       // 建议必填；若为空则无法自动发现其它地址
  PrincipalToken_Contract_Address,
  InterestToken_Contract_Address,
} = process.env;

let GUARD_ADDR = ComplianceGuardLite_Contract_Address
let MANAGER_ADDR = LoanManagerAccrualProLite_Contract_Address
let PRINCIPAL_ADDR = PrincipalToken_Contract_Address
let INTEREST_ADDR = InterestToken_Contract_Address


// ---------- 最小 ABI 片段 ----------
const ERC20_MIN_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
  "function transferFrom(address,address,uint256) returns (bool)",
];
const MINT_BURN_ABI = [
  "function mint(address to, uint256 amount)",
  "function burnFrom(address from, uint256 amount)",
];
const GUARD_ABI = [
  "function setOracle(address o)",
  "function setPaused(bool p)",
  "function setBlocked(address u, bool b)",
  "function setFreezeOutbound(address u, bool b)",
  "function setFreezeInbound(address u, bool b)",
  "function setLockUntil(address u, uint64 ts)",
  "function canReceive(address to) view returns (bool)",
  "function blocked(address) view returns (bool)",
  "function freezeOut(address) view returns (bool)",
  "function freezeIn(address) view returns (bool)",
  "function lockUntil(address) view returns (uint64)",
  "function transfersPaused() view returns (bool)",
  "function oracle() view returns (address)",
];
const MANAGER_ABI = [
  "function initDistribute(address a,address b,address c,address d)",
  "function accrueForHour(uint32 hourNo,bool onTime)",
  "function accrueRange(uint32 startHour,uint32 endHour,bool onTime)",
  "function accrueForDay(uint32 dayNo,bool onTime)",
  "function accrueForMonth(uint32 monthNo,bool onTime)",
  "function flushPending(address[] addrs,uint256 maxAddrs)",
  "function repayPrincipal(address from,uint256 amount)",
  "function getAllHolders() view returns (address[] holders,uint256[] principals,uint256[] interests,uint256[] pendingMicro)",
  "function tokens() view returns (address principal,address interest,address guard)",
  "function distributed() view returns (bool)",
  "function lastAccruedHour() view returns (uint32)",
  "function lastAccruedDay() view returns (uint32)",
  "function lastAccruedMonth() view returns (uint32)",
  "function setOracle(address o)",
  "function setPaused(bool p)",
  "function blockAddr(address u,bool b)",
  "function freezeOutbound(address u,bool b)",
  "function freezeInbound(address u,bool b)",
  "function lockUntil(address u,uint64 ts)",
];

// Principal / Interest
const PRINCIPAL_ABI = [...ERC20_MIN_ABI, ...MINT_BURN_ABI];
const INTEREST_ABI = [...ERC20_MIN_ABI, ...MINT_BURN_ABI];

// ---------- 工具 ----------
const addr = (x) => ethers.getAddress(x);
const fromUnits = (v, d) => ethers.formatUnits(v, d);
const toPrincipalUnits = (n) => BigInt(n);                  // 0 小数
const toInterestUnits = (n) => ethers.parseUnits(`${n}`, 18);

// 等待上链并打印
async function waitTx(tx) {
  console.log("⛓️  发送交易:", tx.hash);
  const rcpt = await tx.wait();
  console.log("✅ 已上链，区块:", rcpt.blockNumber);
  return rcpt;
}

// 若没给 PRINCIPAL/INTEREST/GUARD 地址，尝试从 manager.tokens() 自动发现
async function ensureAddresses(signer) {
  if (!MANAGER_ADDR) {
    throw new Error("请在 .env 设置 MANAGER_ADDR（管理合约地址）");
  }
  MANAGER_ADDR = addr(MANAGER_ADDR);
  const manager = new ethers.Contract(MANAGER_ADDR, MANAGER_ABI, signer);

  if (!PRINCIPAL_ADDR || !INTEREST_ADDR || !GUARD_ADDR) {
    const t = await manager.tokens();
    PRINCIPAL_ADDR = PRINCIPAL_ADDR ? addr(PRINCIPAL_ADDR) : addr(t[0]);
    INTEREST_ADDR = INTEREST_ADDR ? addr(INTEREST_ADDR) : addr(t[1]);
    GUARD_ADDR = GUARD_ADDR ? addr(GUARD_ADDR) : addr(t[2]);
  } else {
    PRINCIPAL_ADDR = addr(PRINCIPAL_ADDR);
    INTEREST_ADDR = addr(INTEREST_ADDR);
    GUARD_ADDR = addr(GUARD_ADDR);
  }
  return {
    manager,
    principal: new ethers.Contract(PRINCIPAL_ADDR, PRINCIPAL_ABI, signer),
    interest: new ethers.Contract(INTEREST_ADDR, INTEREST_ABI, signer),
    guard: new ethers.Contract(GUARD_ADDR, GUARD_ABI, signer),
  };
}

// ---------- 命令实现 ----------
async function cmdInfo({ manager }) {
  const [p, i, g] = await manager.tokens();
  const [dist, lh, ld, lm] = await Promise.all([
    manager.distributed(),
    manager.lastAccruedHour(),
    manager.lastAccruedDay(),
    manager.lastAccruedMonth(),
  ]);
  console.log("Network   :", network.name);
  console.log("Manager   :", MANAGER_ADDR);
  console.log("Principal :", p);
  console.log("Interest  :", i);
  console.log("Guard     :", g);
  console.log("distributed?:", dist);
  console.log("lastAccrued -> hour/day/month:", lh, ld, lm);
}

async function cmdBalances({ principal, interest, signer }, args) {
  const who = args.length ? args.map(addr) : [await signer.getAddress()];
  const [pDec, iDec, pSym, iSym] = await Promise.all([
    principal.decimals(),
    interest.decimals(),
    principal.symbol(),
    interest.symbol(),
  ]);
  for (const a of who) {
    const [pb, ib] = await Promise.all([principal.balanceOf(a), interest.balanceOf(a)]);
    console.log(`\nAddress ${a}`);
    console.log(`  ${pSym} (dec ${pDec}) = ${fromUnits(pb, pDec)}`);
    console.log(`  ${iSym} (dec ${iDec}) = ${fromUnits(ib, iDec)}`);
  }
}

async function cmdDistribute({ manager }, args) {
  if (args.length !== 4) return console.log("用法: distribute <addrA> <addrB> <addrC> <addrD>");
  const [a, b, c, d] = args.map(addr);
  await waitTx(await manager.initDistribute(a, b, c, d));
}

async function cmdAccrueHour({ manager }, args) {
  if (args.length < 2) return console.log("用法: accrueHour <hourNo> <onTime:0|1>");
  const hourNo = Number(args[0]); const onTime = args[1] === "1";
  await waitTx(await manager.accrueForHour(hourNo, onTime));
}
async function cmdAccrueRange({ manager }, args) {
  if (args.length < 3) return console.log("用法: accrueRange <startHour> <endHour> <onTime:0|1>");
  const s = Number(args[0]), e = Number(args[1]), onTime = args[2] === "1";
  await waitTx(await manager.accrueRange(s, e, onTime));
}
async function cmdAccrueDay({ manager }, args) {
  if (args.length < 2) return console.log("用法: accrueDay <dayNo> <onTime:0|1>");
  const d = Number(args[0]), onTime = args[1] === "1";
  await waitTx(await manager.accrueForDay(d, onTime));
}
async function cmdAccrueMonth({ manager }, args) {
  if (args.length < 2) return console.log("用法: accrueMonth <monthNo> <onTime:0|1>");
  const m = Number(args[0]), onTime = args[1] === "1";
  await waitTx(await manager.accrueForMonth(m, onTime));
}

async function cmdFlush({ manager }, args) {
  if (args.length < 1) {
    console.log("用法: flush <maxAddrs> [addr1 addr2 ...]");
    return;
  }
  const maxAddrs = BigInt(args[0]);
  const addrs = args.slice(1).map(addr);
  await waitTx(await manager.flushPending(addrs, maxAddrs));
}

async function cmdRepay({ manager }, args) {
  if (args.length < 2) return console.log("用法: repay <from> <amount(本金整数)>");
  const from = addr(args[0]); const amount = toPrincipalUnits(args[1]);
  await waitTx(await manager.repayPrincipal(from, amount));
}

// guard 子命令
async function cmdGuard(ctx, [sub, ...rest]) {
  const { guard } = ctx;
  switch (sub) {
    case "status": {
      const [paused, ora] = await Promise.all([guard.transfersPaused(), guard.oracle()]);
      console.log("paused:", paused, "oracle:", ora);
      break;
    }
    case "pause": {
      const p = rest[0] === "1"; await waitTx(await guard.setPaused(p)); break;
    }
    case "block": {
      const u = addr(rest[0]); const b = rest[1] === "1";
      await waitTx(await guard.setBlocked(u, b)); break;
    }
    case "freezeOut": {
      const u = addr(rest[0]); const b = rest[1] === "1";
      await waitTx(await guard.setFreezeOutbound(u, b)); break;
    }
    case "freezeIn": {
      const u = addr(rest[0]); const b = rest[1] === "1";
      await waitTx(await guard.setFreezeInbound(u, b)); break;
    }
    case "lock": {
      const u = addr(rest[0]); const ts = BigInt(rest[1]);
      await waitTx(await guard.setLockUntil(u, ts)); break;
    }
    case "oracle": {
      const o = addr(rest[0]); await waitTx(await guard.setOracle(o)); break;
    }
    default:
      console.log("guard 子命令: status | pause | block | freezeOut | freezeIn | lock | oracle");
  }
}

// erc20 子命令
async function cmdErc20(ctx, [sub, which, ...rest]) {
  const c = which === "principal" ? ctx.principal
    : which === "interest" ? ctx.interest
      : null;
  if (!c) return console.log("用法: erc20 <info|balance|transfer> principal|interest ...");

  switch (sub) {
    case "info": {
      const [n, s, d, t] = await Promise.all([c.name(), c.symbol(), c.decimals(), c.totalSupply()]);
      console.log("name:", n, "symbol:", s, "decimals:", d);
      console.log("totalSupply:", ethers.formatUnits(t, d));
      break;
    }
    case "balance": {
      const who = addr(rest[0]); const d = await c.decimals();
      const b = await c.balanceOf(who);
      console.log(`${which} balance of ${who} =`, ethers.formatUnits(b, d));
      break;
    }
    case "transfer": {
      const to = addr(rest[0]);
      const amount = which === "principal"
        ? BigInt(rest[1])                 // 0 小数
        : ethers.parseUnits(rest[1], 18); // 18 小数
      await waitTx(await c.transfer(to, amount));
      break;
    }
    default:
      console.log("erc20 子命令: info|balance|transfer");
  }
}

// ---------- 主入口 ----------
async function main() {
  // 使用 Hardhat 的 provider 与 signer（自动读取 hardhat.config.js 的 network & accounts）
  const [signer] = await ethers.getSigners();

  // 仅当不是 hardhat 内置网络时，这里才有 URL；否则为 undefined
  console.log("Network:", network.name, "| RPC:", hre.network.config.url ?? "(in-memory hardhat)");

  const contracts = await ensureAddresses(signer);

  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "info": await cmdInfo(contracts); break;
    case "balances": await cmdBalances({ ...contracts, signer }, args); break;
    case "distribute": await cmdDistribute(contracts, args); break;
    case "accrueHour": await cmdAccrueHour(contracts, args); break;
    case "accrueRange": await cmdAccrueRange(contracts, args); break;
    case "accrueDay": await cmdAccrueDay(contracts, args); break;
    case "accrueMonth": await cmdAccrueMonth(contracts, args); break;
    case "flush": await cmdFlush(contracts, args); break;
    case "repay": await cmdRepay(contracts, args); break;
    case "guard": await cmdGuard(contracts, args); break;
    case "erc20": await cmdErc20(contracts, args); break;
    default: printHelp();
  }
}

function printHelp() {
  console.log(`
用法: npx hardhat run --network <net> scripts/interact.js <命令> [参数...]

通用:
  ... info
  ... balances [addr1 addr2 ...]

首次分发:
  ... distribute <addrA> <addrB> <addrC> <addrD>

计息:
  ... accrueHour  <hourNo> <onTime:0|1>
  ... accrueRange <startHour> <endHour> <onTime:0|1>
  ... accrueDay   <dayNo> <onTime:0|1>
  ... accrueMonth <monthNo> <onTime:0|1>

结算 & 还本:
  ... flush <maxAddrs> [addr1 addr2 ...]
  ... repay <fromAddr> <amountPrincipalInt>

合规模块:
  ... guard status
  ... guard pause 1|0
  ... guard block <user> 1|0
  ... guard freezeOut <user> 1|0
  ... guard freezeIn  <user> 1|0
  ... guard lock <user> <unixTs>
  ... guard oracle <addr>

ERC20（本金/利息）:
  ... erc20 info principal|interest
  ... erc20 balance principal|interest <addr>
  ... erc20 transfer principal|interest <to> <amount>
      - principal 金额 = 整数（0 小数）
      - interest  金额 = 18 小数
`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
