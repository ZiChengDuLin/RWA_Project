require("dotenv").config();
const { ethers } = require("hardhat");

const ADDR = {
  GUARD: process.env.ComplianceGuardLite_Contract_Address,
  MANAGER: process.env.LoanManagerAccrualProLite_Contract_Address,
  PTOKEN: process.env.PrincipalToken_Contract_Address,
  ITOKEN: process.env.InterestToken_Contract_Address,
};

function need(k) {
  if (!ADDR[k] || !ADDR[k].startsWith("0x")) {
    throw new Error(`请在 .env 里填好 ${k}_ADDR （当前值 ${ADDR[k]}）`);
  }
  return ADDR[k];
}

function fmt(n, d) { return ethers.formatUnits(n, d); }
async function decimalsOf(token) { return (await token.decimals?.()) ?? 18; }

// 便捷函数：判断合约是否有某函数签名
function hasFn(c, sig) { try { c.interface.getFunction(sig); return true; } catch { return false; } }
// 便捷调用：存在则调用并等待
async function tryWrite(c, sig, args = []) {
  try {
    const fn = c.getFunction(sig);
    const tx = await fn(...args);
    await tx.wait();
    console.log(`✔ ${c.target} :: ${sig}(${args.join(",")})`);
    return true;
  } catch (e) { return false; }
}

async function getToken(which) {
  const name = which.toLowerCase();
  if (name === "pt" || name === "principal") {
    return ethers.getContractAt("PrincipalToken", need("PTOKEN"));
  }
  if (name === "it" || name === "interest") {
    return ethers.getContractAt("InterestToken", need("ITOKEN"));
  }
  throw new Error("token 必须是 pt|principal 或 it|interest");
}

async function getManager() { return ethers.getContractAt("LoanManagerAccrualProLite", need("MANAGER")); }
async function getGuard() { return ethers.getContractAt("ComplianceGuardLite", need("GUARD")); }

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Signer:", signer.address);

  const [cmd, ...argv] = process.argv.slice(2);
  if (!cmd) {
    console.log(`
用法示例（--network sepolia）：
  余额查询
    npx hardhat run scripts/rwa_interact.js --network sepolia balance pt 0xYourAddr
    npx hardhat run scripts/rwa_interact.js --network sepolia balance it 0xYourAddr

  转账 & 授权
    npx hardhat run scripts/rwa_interact.js --network sepolia transfer pt 0xTO 100
    npx hardhat run scripts/rwa_interact.js --network sepolia approve  it 0xSPENDER 50
    npx hardhat run scripts/rwa_interact.js --network sepolia allowance it 0xOWNER 0xSPENDER

  （若可用）铸造/销毁
    npx hardhat run scripts/rwa_interact.js --network sepolia mint  pt 0xTO 100
    npx hardhat run scripts/rwa_interact.js --network sepolia burn  it 25

  合规模块 / 管理操作
    npx hardhat run scripts/rwa_interact.js --network sepolia blockaddr 0xUSER true
    npx hardhat run scripts/rwa_interact.js --network sepolia freezein  0xUSER true
    npx hardhat run scripts/rwa_interact.js --network sepolia freezeout 0xUSER true
    npx hardhat run scripts/rwa_interact.js --network sepolia lockuntil 0xUSER 1728000000   # unix时间
    npx hardhat run scripts/rwa_interact.js --network sepolia pause true

  计提 / 归还
    npx hardhat run scripts/rwa_interact.js --network sepolia accrueHour  123 true
    npx hardhat run scripts/rwa_interact.js --network sepolia accrueDay   45  true
    npx hardhat run scripts/rwa_interact.js --network sepolia accrueMonth 7   false
    npx hardhat run scripts/rwa_interact.js --network sepolia repayPrincipal 0xFROM 100

  在 Manager 中登记两种 Token 地址（若需要）
    npx hardhat run scripts/rwa_interact.js --network sepolia registerTokens
`); return;
  }

  switch (cmd.toLowerCase()) {
    /** ---------------- ERC20 常用 ---------------- **/
    case "balance": {
      const [which, holder] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const bal = await t.balanceOf(holder);
      console.log(`${which} balance of ${holder}:`, fmt(bal, d));
      break;
    }
    case "transfer": {
      const [which, to, amount] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const v = ethers.parseUnits(amount, d);
      await (await t.transfer(to, v)).wait();
      console.log("✔ transfer done");
      break;
    }
    case "approve": {
      const [which, spender, amount] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const v = ethers.parseUnits(amount, d);
      await (await t.approve(spender, v)).wait();
      console.log("✔ approve done");
      break;
    }
    case "allowance": {
      const [which, owner, spender] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const v = await t.allowance(owner, spender);
      console.log("allowance:", fmt(v, d));
      break;
    }
    case "mint": {
      const [which, to, amount] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const v = ethers.parseUnits(amount, d);

      // 先尝试直接 token.mint(to, amount)
      if (await tryWrite(t, "mint(address,uint256)", [to, v])) break;

      // 如果 Token 的 owner 是 Manager，则从 Manager 尝试常见命名
      const m = await getManager();
      const tryList = (which.toLowerCase().startsWith("p"))
        ? [
          ["mintPrincipal(address,uint256)", [to, v]],
          ["mintP(address,uint256)", [to, v]],
        ]
        : [
          ["mintInterest(address,uint256)", [to, v]],
          ["mintI(address,uint256)", [to, v]],
        ];
      for (const [sig, args] of tryList) {
        if (await tryWrite(m, sig, args)) return;
      }
      console.log("⚠ 未找到可用的铸币入口（既没有 token.mint，也没有 manager 的铸币函数）");
      break;
    }
    case "burn": {
      const [which, amount] = argv;
      const t = await getToken(which);
      const d = await decimalsOf(t);
      const v = ethers.parseUnits(amount, d);

      if (await tryWrite(t, "burn(uint256)", [v])) break;
      if (await tryWrite(t, "burnFrom(address,uint256)", [await (await ethers.getSigners())[0].getAddress(), v])) break;
      console.log("⚠ 未找到可用的销毁入口（burn/burnFrom）");
      break;
    }

    /** ---------------- 合规模块 & 管理 ---------------- **/
    case "blockaddr": {
      const [user, flag] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "blockAddr(address,bool)", [user, flag === "true"]))) {
        const g = await getGuard();
        if (!(await tryWrite(g, "blockAddr(address,bool)", [user, flag === "true"]))) {
          console.log("⚠ 未找到 blockAddr 接口（Manager/Guard 都没有）");
        }
      }
      break;
    }
    case "freezein": {
      const [user, flag] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "freezeInbound(address,bool)", [user, flag === "true"]))) {
        const g = await getGuard();
        await tryWrite(g, "freezeInbound(address,bool)", [user, flag === "true"]);
      }
      break;
    }
    case "freezeout": {
      const [user, flag] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "freezeOutbound(address,bool)", [user, flag === "true"]))) {
        const g = await getGuard();
        await tryWrite(g, "freezeOutbound(address,bool)", [user, flag === "true"]);
      }
      break;
    }
    case "lockuntil": {
      const [user, ts] = argv; // Unix 秒
      const m = await getManager();
      if (!(await tryWrite(m, "lockUntil(address,uint64)", [user, BigInt(ts)]))) {
        const g = await getGuard();
        await tryWrite(g, "lockUntil(address,uint64)", [user, BigInt(ts)]);
      }
      break;
    }
    case "pause": {
      const [flag] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "setPaused(bool)", [flag === "true"]))) {
        console.log("⚠ 未找到 setPaused(bool) 接口");
      }
      break;
    }

    /** ---------------- 计提 & 还本 ---------------- **/
    case "accruehour": {
      const [hourNo, onTime] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "accrueForHour(uint32,bool)", [Number(hourNo), onTime === "true"]))) {
        console.log("⚠ 未找到 accrueForHour(uint32,bool)");
      }
      break;
    }
    case "accrueday": {
      const [dayNo, onTime] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "accrueForDay(uint32,bool)", [Number(dayNo), onTime === "true"]))) {
        console.log("⚠ 未找到 accrueForDay(uint32,bool)");
      }
      break;
    }
    case "accruemonth": {
      const [monthNo, onTime] = argv;
      const m = await getManager();
      if (!(await tryWrite(m, "accrueForMonth(uint32,bool)", [Number(monthNo), onTime === "true"]))) {
        console.log("⚠ 未找到 accrueForMonth(uint32,bool)");
      }
      break;
    }
    case "repayprincipal": {
      const [from, amount] = argv;
      const m = await getManager();
      const pt = await getToken("pt");
      const d = await decimalsOf(pt);
      const v = ethers.parseUnits(amount, d);
      if (!(await tryWrite(m, "repayPrincipal(address,uint256)", [from, v]))) {
        console.log("⚠ 未找到 repayPrincipal(address,uint256)");
      }
      break;
    }

    /** ---------------- 注册两种 token 地址（若合约设计需要） ---------------- **/
    case "registertokens": {
      const m = await getManager();
      const pt = need("PTOKEN"), it = need("ITOKEN");
      const tries = [
        ["setTokens(address,address)", [pt, it]],
        ["setTokenAddresses(address,address)", [pt, it]],
        ["initializeTokens(address,address)", [pt, it]],
      ];
      for (const [sig, args] of tries) {
        if (await tryWrite(m, sig, args)) return;
      }
      console.log("⚠ 未找到登记 Token 的接口（setTokens / setTokenAddresses / initializeTokens）");
      break;
    }

    default:
      throw new Error(`未知命令：${cmd}。不带参数运行脚本可查看用法示例。`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
