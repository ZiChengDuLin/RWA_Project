// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================
   AccrualModule.sol（计息模块：模式锁定 + 统一期号 + 保持 T+1 兼容）
   ========================= */

interface IPrincipal {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IInterest {
    function mint(address to, uint256 amount18) external;
}

interface IHolderRegistryA {
    function holderCount() external view returns (uint256);
    function holderAt(uint256 idx) external view returns (address);
}

interface IComplianceGuardA {
    function canReceiveInterest(address a) external view returns (bool);
}

/* ========= Minimal Ownable (constructor: Ownable(owner_)) ========= */
abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: zero owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: not owner");
        _;
    }

    function owner() public view returns (address) { return _owner; }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: zero newOwner");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

contract AccrualModule is Ownable {
    enum Mode { None, Hour, Day, Month }
    Mode public mode;

    IPrincipal public principal;
    IInterest  public interest;
    IComplianceGuardA public guard;
    IHolderRegistryA  public registry;

    uint256 public constant ANNUAL_RATE_BPS  = 990;   // 9.90%
    uint256 public constant LATE_ANNUAL_BPS  = 1800;  // 18.00%
    uint32  public constant DURATION_DAYS    = 365;

    uint32  public lastAccruedHour;
    uint32  public lastAccruedDay;
    uint32  public lastAccruedMonth;
    uint32  public lastAccruedPeriod; // 与 mode 同步推进

    uint256 private constant MICRO_PER_CENT = 1_000_000; // 1分=1e6微分
    uint256 private constant ONE_CENT_IN_18 = 1e16;      // 1分=1e16利息币单位

    mapping(address => uint256) public pendingMicroCents;

    error ModeLocked(Mode expected);

    event AccruedHour(uint32 hourNo, bool onTime, uint256 bps, uint256 minted18);
    event AccruedDay(uint32 dayNo, bool onTime, uint256 bps, uint256 minted18);
    event AccruedMonth(uint32 monthNo, bool onTime, uint256 bps, uint256 minted18);

    constructor(address owner_) Ownable(owner_) {}

    function wire(
        address principal_,
        address interest_,
        address guard_,
        address registry_
    ) external onlyOwner {
        principal = IPrincipal(principal_);
        interest  = IInterest(interest_);
        guard     = IComplianceGuardA(guard_);
        registry  = IHolderRegistryA(registry_);
    }

    function _assertMode(Mode expected) internal {
        if (mode == Mode.None) { mode = expected; return; }
        if (mode != expected) revert ModeLocked(expected);
    }

    function _accrue(uint256 annualBps, uint256 periodDenom) internal returns (uint256 minted18) {
        uint256 pSupply = principal.totalSupply();
        if (pSupply == 0) return 0;

        uint256 factor = annualBps * 100 * MICRO_PER_CENT; // annualBps×分×微分
        uint256 n = registry.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = registry.holderAt(i);
            uint256 pb = principal.balanceOf(h);
            if (pb == 0) continue;

            uint256 micro = pb * factor / periodDenom / pSupply;
            uint256 acc = pendingMicroCents[h] + micro;
            uint256 cents = acc / MICRO_PER_CENT;
            uint256 rem = acc % MICRO_PER_CENT;

            if (cents > 0 && guard.canReceiveInterest(h)) {
                uint256 amt18 = cents * ONE_CENT_IN_18;
                interest.mint(h, amt18);
                minted18 += amt18;
                pendingMicroCents[h] = rem;
            } else {
                pendingMicroCents[h] = acc;
            }
        }
    }

    function accrueForHour(uint32 hourNo, bool onTime) external onlyOwner {
        _assertMode(Mode.Hour);
        require(hourNo == lastAccruedHour + 1, "hour seq");
        uint256 bps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 minted = _accrue(bps, 365 * 24 * 10_000);
        lastAccruedHour = hourNo;
        lastAccruedPeriod = hourNo;
        emit AccruedHour(hourNo, onTime, bps, minted);
    }

    function accrueForDay(uint32 dayNo, bool onTime) external onlyOwner {
        _assertMode(Mode.Day);
        require(dayNo == lastAccruedDay + 1, "day seq");
        uint256 bps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 minted = _accrue(bps, 365 * 10_000);
        lastAccruedDay = dayNo;
        lastAccruedPeriod = dayNo;
        emit AccruedDay(dayNo, onTime, bps, minted);
    }

    function accrueForMonth(uint32 monthNo, bool onTime) external onlyOwner {
        _assertMode(Mode.Month);
        require(monthNo == lastAccruedMonth + 1 && monthNo >= 1 && monthNo <= 12, "month seq");
        uint256 bps = onTime ? ANNUAL_RATE_BPS : LATE_ANNUAL_BPS;
        uint256 minted = _accrue(bps, 12 * 10_000);
        lastAccruedMonth = monthNo;
        lastAccruedPeriod = monthNo;
        emit AccruedMonth(monthNo, onTime, bps, minted);
    }

    /* 便于外部读取 */
    function lastAccruedPeriodView() external view returns (uint32) { return lastAccruedPeriod; }
    function modeView() external view returns (Mode) { return mode; }

    /* （可选）“本息完成”判断 */
    function interestComplete() external view returns (bool) {
        if (mode == Mode.Day) return lastAccruedDay >= DURATION_DAYS;
        if (mode == Mode.Month) return lastAccruedMonth >= 12;
        if (mode == Mode.Hour) return lastAccruedHour >= (365*24);
        return false;
    }
}
