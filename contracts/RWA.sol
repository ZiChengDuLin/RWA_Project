// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/* 可选：制裁库接口（不想用可不设置 oracle） */
interface IChainalysisSanctionsOracle {
    function isSanctioned(address) external view returns (bool);
}

/* --------------------- 合规模块（Lite）：无“白名单” --------------------- */
contract ComplianceGuardLite is Ownable {
    mapping(address => bool) public blocked; // 黑名单（入/出都禁）
    mapping(address => bool) public freezeOut; // 冻结“转出”
    mapping(address => bool) public freezeIn; // 冻结“转入/接收”
    mapping(address => uint64) public lockUntil; // 时间锁（未到期不可转出）
    bool public transfersPaused = false;
    IChainalysisSanctionsOracle public oracle; // 可选

    event BlockedSet(address indexed user, bool blocked);
    event FreezeOutSet(address indexed user, bool frozen);
    event FreezeInSet(address indexed user, bool frozen);
    event LockUntilSet(address indexed user, uint64 untilTs);
    event OracleSet(address indexed oracle);
    event Paused(bool paused);

    constructor() Ownable(msg.sender) {}

    /* 管理员设置 */
    function setOracle(address o) external onlyOwner {
        oracle = IChainalysisSanctionsOracle(o);
        emit OracleSet(o);
    }

    function setPaused(bool p) external onlyOwner {
        transfersPaused = p;
        emit Paused(p);
    }

    function setBlocked(address u, bool b) external onlyOwner {
        blocked[u] = b;
        emit BlockedSet(u, b);
    }

    function setFreezeOutbound(address u, bool b) external onlyOwner {
        freezeOut[u] = b;
        emit FreezeOutSet(u, b);
    }

    function setFreezeInbound(address u, bool b) external onlyOwner {
        freezeIn[u] = b;
        emit FreezeInSet(u, b);
    }

    function setLockUntil(address u, uint64 ts) external onlyOwner {
        lockUntil[u] = ts;
        emit LockUntilSet(u, ts);
    }

    /* 供代币在 _update 前调用：不合规则 revert */
    function check(address from, address to) external view {
        require(!transfersPaused, "paused");
        if (from != address(0)) {
            require(!blocked[from], "from blocked");
            require(!freezeOut[from], "from frozen");
            uint64 lu = lockUntil[from];
            if (lu != 0) require(block.timestamp >= lu, "from locked");
            if (address(oracle) != address(0))
                require(!oracle.isSanctioned(from), "from sanctioned");
        }
        if (to != address(0)) {
            require(!blocked[to], "to blocked");
            require(!freezeIn[to], "to inbound frozen");
            if (address(oracle) != address(0))
                require(!oracle.isSanctioned(to), "to sanctioned");
        }
    }

    /* 只读：当前是否允许“接收” */
    function canReceive(address to) external view returns (bool) {
        if (transfersPaused || to == address(0) || blocked[to] || freezeIn[to])
            return false;
        if (address(oracle) != address(0) && oracle.isSanctioned(to))
            return false;
        return true;
    }
}

/* --------------------- 基础 ERC20（可铸/可销，定制小数） --------------------- */
contract MintableBurnableERC20 is ERC20, Ownable {
    uint8 private _customDecimals;

    constructor(
        string memory n,
        string memory s,
        uint8 d,
        address owner_
    ) ERC20(n, s) Ownable(owner_) {
        _customDecimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

interface IHolderRegistry {
    function registerOnReceive(address to) external;
}

/* --------------------- 本金币：贷款本金（0 小数） --------------------- */
contract PrincipalToken is MintableBurnableERC20 {
    address public immutable manager;
    ComplianceGuardLite public immutable guard;

    constructor(
        address owner_,
        address manager_,
        address guard_
    )
        // 名称改为中文：贷款本金；符号保留 PWL-P（如要改符号，把 "PWL-P" 改成你想要的）
        MintableBurnableERC20(unicode"贷款本金", "PWL-P", 0, owner_)
    {
        require(manager_ != address(0) && guard_ != address(0), "bad ctor");
        manager = manager_;
        guard = ComplianceGuardLite(guard_);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        guard.check(from, to); // 冻结/黑名单/暂停检查
        super._update(from, to, value);
        if (to != address(0) && value > 0 && balanceOf(to) > 0) {
            IHolderRegistry(manager).registerOnReceive(to); // 首次入册
        }
    }
}

/* --------------------- 利息币：贷款利息（18 小数） --------------------- */
contract InterestToken is MintableBurnableERC20 {
    ComplianceGuardLite public immutable guard;

    constructor(
        address owner_,
        address guard_
    )
        // 名称改为中文：贷款利息；符号保留 PWL-I（如要改符号，改这里第二个参数）
        MintableBurnableERC20(unicode"贷款利息", "PWL-I", 18, owner_)
    {
        require(guard_ != address(0), "guard=0");
        guard = ComplianceGuardLite(guard_);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        guard.check(from, to); // 冻结/黑名单/暂停检查
        super._update(from, to, value);
    }
}

/* --------------------- 管理合约（无白名单） --------------------- */
contract LoanManagerAccrualProLite is Ownable, IHolderRegistry {
    using Math for uint256;

    // 参数（年化 9.9%，逾期 18%）
    uint256 public constant TOTAL_LOAN_AMOUNT = 1_000_000;
    uint256 public constant ANNUAL_RATE_BPS = 990;
    uint256 public constant LATE_ANNUAL_BPS = 1800;
    uint32 public constant HOURS_PER_YEAR = 365 * 24;
    uint32 public constant DURATION_HOURS = HOURS_PER_YEAR;
    uint32 public constant DURATION_DAYS = 365;
    uint32 public constant DURATION_MONTHS = 12;
    uint64 public constant START_TIMESTAMP = 1722960000;

    // 精度：1分 = 1e18/100；1分 = 1,000,000 微分
    uint256 private constant ONE_CENT_IN_18 = 1e16;
    uint256 private constant MICRO_PER_CENT = 1_000_000;
    uint32 public constant MAX_HOUR_BATCH = 720;

    // 模块
    PrincipalToken public immutable principal; // 贷款本金
    InterestToken public immutable interest; // 贷款利息
    ComplianceGuardLite public immutable guard;

    // 名册
    address[] private _holders;
    mapping(address => bool) private _seen;

    // 利息累计（微分）
    mapping(address => uint256) public pendingMicroCents;

    // 进度
    bool public distributed;
    uint32 public lastAccruedHour;
    uint32 public lastAccruedDay;
    uint32 public lastAccruedMonth;

    // 事件
    event HolderAdded(address indexed holder);
    event InitialDistributed(
        address a,
        address b,
        address c,
        address d,
        uint256 each
    );
    event AccruedHour(
        uint32 hourIndex,
        bool onTime,
        uint256 annualBpsUsed,
        uint256 minted18
    );
    event AccruedHourBatch(
        uint32 startHour,
        uint32 endHour,
        bool onTime,
        uint256 minted18Total
    );
    event AccruedDay(
        uint32 dayIndex,
        bool onTime,
        uint256 annualBpsUsed,
        uint256 minted18
    );
    event AccruedMonth(
        uint32 monthIndex,
        bool onTime,
        uint256 annualBpsUsed,
        uint256 minted18
    );
    event PrincipalRepaid(address indexed from, uint256 amount);
    event DefaultNotified(string scope, uint32 index, string memo);

    constructor() Ownable(msg.sender) {
        ComplianceGuardLite g = new ComplianceGuardLite(); // owner = 本合约
        guard = g;
        principal = new PrincipalToken(
            address(this),
            address(this),
            address(g)
        );
        interest = new InterestToken(address(this), address(g));
        distributed = false;
        lastAccruedHour = 0;
        lastAccruedDay = 0;
        lastAccruedMonth = 0;
    }

    /* ---- 合规模块转发（仍可冻结/封禁/时间锁/暂停/制裁） ---- */
    function setOracle(address o) external onlyOwner {
        guard.setOracle(o);
    }

    function setPaused(bool p) external onlyOwner {
        guard.setPaused(p);
    }

    function blockAddr(address u, bool b) external onlyOwner {
        guard.setBlocked(u, b);
    }

    function freezeOutbound(address u, bool b) external onlyOwner {
        guard.setFreezeOutbound(u, b);
    }

    function freezeInbound(address u, bool b) external onlyOwner {
        guard.setFreezeInbound(u, b);
    }

    function lockUntil(address u, uint64 ts) external onlyOwner {
        guard.setLockUntil(u, ts);
    }

    /* ---- 首次分配（平均给四个地址；如需自定义比例，可改为传入 amounts[]） ---- */
    function initDistribute(
        address a,
        address b,
        address c,
        address d
    ) external onlyOwner {
        require(!distributed, "already distributed");
        require(
            a != address(0) &&
                b != address(0) &&
                c != address(0) &&
                d != address(0),
            "zero addr"
        );

        uint256 each = TOTAL_LOAN_AMOUNT / 4; // 250,000
        principal.mint(a, each);
        principal.mint(b, each);
        principal.mint(c, each);
        principal.mint(d, each);

        _register(a);
        _register(b);
        _register(c);
        _register(d);
        distributed = true;
        emit InitialDistributed(a, b, c, d, each);
    }

    /* ===================== 结息：小时 / 区间小时 / 日 / 月 ===================== */

    function _accrueWithFactor(
        uint256 factor,
        uint256 denom
    ) internal returns (uint256 minted18) {
        for (uint256 i = 0; i < _holders.length; i++) {
            address h = _holders[i];
            uint256 bal = principal.balanceOf(h);
            if (bal == 0) continue;

            uint256 micro = Math.mulDiv(bal, factor, denom);
            if (micro == 0) continue;

            uint256 acc = pendingMicroCents[h] + micro;
            uint256 payableCents = acc / MICRO_PER_CENT;
            uint256 remainder = acc % MICRO_PER_CENT;

            // 不可接收（冻结入/暂停/制裁）时先累计，解冻后 flush
            if (payableCents > 0 && guard.canReceive(h)) {
                uint256 amt18 = payableCents * ONE_CENT_IN_18;
                interest.mint(h, amt18);
                minted18 += amt18;
                pendingMicroCents[h] = remainder;
            } else {
                pendingMicroCents[h] = acc;
            }
        }
    }

    function accrueForHour(uint32 hourNo, bool onTime) external onlyOwner {
        require(distributed, "init first");
        require(hourNo >= 1 && hourNo <= DURATION_HOURS, "hour OOR");
        require(hourNo == lastAccruedHour + 1, "seq");

        uint256 annualBps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 denom = HOURS_PER_YEAR * 10_000;
        uint256 factor = annualBps * 100 * MICRO_PER_CENT;

        uint256 minted = _accrueWithFactor(factor, denom);
        lastAccruedHour = hourNo;
        emit AccruedHour(hourNo, onTime, annualBps, minted);
        if (!onTime)
            emit DefaultNotified("hour", hourNo, unicode"逾期：18%/8760 计息");
    }

    function accrueRange(
        uint32 startHour,
        uint32 endHour,
        bool onTime
    ) external onlyOwner {
        require(distributed, "init first");
        require(startHour == lastAccruedHour + 1, "start!=next");
        require(endHour >= startHour && endHour <= DURATION_HOURS, "bad range");
        uint32 span = endHour - startHour + 1;
        require(span <= MAX_HOUR_BATCH, "range too long");

        uint256 annualBps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 denom = HOURS_PER_YEAR * 10_000;
        uint256 factor = annualBps * 100 * MICRO_PER_CENT;

        uint256 mintedTotal = 0;
        for (uint32 i = 0; i < span; i++) {
            mintedTotal += _accrueWithFactor(factor, denom);
        }
        lastAccruedHour = endHour;
        emit AccruedHourBatch(startHour, endHour, onTime, mintedTotal);
        if (!onTime)
            emit DefaultNotified(
                "hourRange",
                endHour,
                unicode"区间逾期：18%/8760 计息"
            );
    }

    function accrueForDay(uint32 dayNo, bool onTime) external onlyOwner {
        require(distributed, "init first");
        require(dayNo >= 1 && dayNo <= DURATION_DAYS, "day OOR");
        require(dayNo == lastAccruedDay + 1, "seq");

        uint256 annualBps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 denom = 365 * 10_000;
        uint256 factor = annualBps * 100 * MICRO_PER_CENT;

        uint256 minted = _accrueWithFactor(factor, denom);
        lastAccruedDay = dayNo;
        emit AccruedDay(dayNo, onTime, annualBps, minted);
        if (!onTime)
            emit DefaultNotified("day", dayNo, unicode"逾期：18%/365 计息");
    }

    function accrueForMonth(uint32 monthNo, bool onTime) external onlyOwner {
        require(distributed, "init first");
        require(monthNo >= 1 && monthNo <= DURATION_MONTHS, "month OOR");
        require(monthNo == lastAccruedMonth + 1, "seq");

        uint256 annualBps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 denom = 12 * 10_000;
        uint256 factor = annualBps * 100 * MICRO_PER_CENT;

        uint256 minted = _accrueWithFactor(factor, denom);
        lastAccruedMonth = monthNo;
        emit AccruedMonth(monthNo, onTime, annualBps, minted);
        if (!onTime)
            emit DefaultNotified("month", monthNo, unicode"逾期：18%/12 计息");
    }

    /* 解冻后批量补发“整分” */
    function flushPending(
        address[] calldata addrs,
        uint256 maxAddrs
    ) external onlyOwner {
        uint256 m = addrs.length;
        if (maxAddrs > 0 && maxAddrs < m) m = maxAddrs;
        for (uint256 i = 0; i < m; i++) {
            address h = addrs[i];
            if (!guard.canReceive(h)) continue;
            uint256 acc = pendingMicroCents[h];
            if (acc < MICRO_PER_CENT) continue;
            uint256 cents = acc / MICRO_PER_CENT;
            pendingMicroCents[h] = acc % MICRO_PER_CENT;
            interest.mint(h, cents * ONE_CENT_IN_18);
        }
    }

    /* 还本（若地址冻结转出/未到锁定时间，会被拒绝） */
    function repayPrincipal(address from, uint256 amount) external onlyOwner {
        require(distributed, "init first");
        require(from != address(0) && amount > 0, "bad args");
        principal.burnFrom(from, amount);
        emit PrincipalRepaid(from, amount);
    }

    /* 查询 */
    function getAllHolders()
        external
        view
        returns (
            address[] memory h,
            uint256[] memory p,
            uint256[] memory i,
            uint256[] memory micro
        )
    {
        h = _holders;
        p = new uint256[](h.length);
        i = new uint256[](h.length);
        micro = new uint256[](h.length);
        for (uint256 k = 0; k < h.length; k++) {
            address a = h[k];
            p[k] = principal.balanceOf(a);
            i[k] = interest.balanceOf(a);
            micro[k] = pendingMicroCents[a];
        }
    }

    function tokens()
        external
        view
        returns (
            address principalToken,
            address interestToken,
            address guardAddr
        )
    {
        return (address(principal), address(interest), address(guard));
    }

    /* 名册登记：本金首次到帐 */
    function registerOnReceive(address to) external {
        require(msg.sender == address(principal), "only principal");
        _register(to);
    }

    function _register(address to) internal {
        if (!_seen[to]) {
            _seen[to] = true;
            _holders.push(to);
            emit HolderAdded(to);
        }
    }
}
