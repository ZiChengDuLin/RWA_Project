// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ========= 外部接口（与项目其余合约保持一致的最小集） ========= */
interface IComplianceGuard {
    // 利息代币收/转的合规检查；应在 Guard 内处理白名单、冻结、过期、制裁等逻辑
    function checkInterest(address from, address to) external view;
}

interface IHolderRegistry {
    // 自动入册：只增不删，用于计息遍历
    function register(address to) external;
}

/* ========= 最小 Ownable（兼容 OZ v5 构造：Ownable(owner_)） ========= */
abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: zero owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

/* ========= 最小 ERC20（v5 风格：公共方法经由 internal _update；_mint/_burn 也走 _update） ========= */
abstract contract ERC20 {
    /* --- ERC20 标准事件 --- */
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /* --- 元数据 --- */
    string private _name;
    string private _symbol;

    /* --- 供应与账本 --- */
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /* ---------- ERC20 公开视图 ---------- */
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view virtual returns (uint8) { return 18; }

    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    /* ---------- ERC20 交互 ---------- */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        _update(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public virtual returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _update(from, to, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        require(current >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(msg.sender, spender, current - subtractedValue);
        return true;
    }

    /* ---------- 内部核心（v5 风格） ---------- */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // mint
            require(to != address(0), "ERC20: mint to the zero address");
            _totalSupply += value;
            _balances[to] += value;
            emit Transfer(address(0), to, value);
        } else if (to == address(0)) {
            // burn
            uint256 fromBal = _balances[from];
            require(fromBal >= value, "ERC20: burn amount exceeds balance");
            unchecked { _balances[from] = fromBal - value; }
            _totalSupply -= value;
            emit Transfer(from, address(0), value);
        } else {
            // transfer
            uint256 fromBal2 = _balances[from];
            require(fromBal2 >= value, "ERC20: transfer amount exceeds balance");
            unchecked {
                _balances[from] = fromBal2 - value;
                _balances[to] += value;
            }
            emit Transfer(from, to, value);
        }
    }

    function _mint(address to, uint256 value) internal virtual {
        _update(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal virtual {
        _update(from, address(0), value);
    }

    function _approve(address owner_, address spender, uint256 value) internal virtual {
        require(owner_ != address(0) && spender != address(0), "ERC20: zero address");
        _allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal virtual {
        uint256 current = _allowances[owner_][spender];
        if (current != type(uint256).max) {
            require(current >= value, "ERC20: insufficient allowance");
            unchecked { _allowances[owner_][spender] = current - value; }
            emit Approval(owner_, spender, _allowances[owner_][spender]);
        }
    }
}

/* ========= 利息代币（18位，小数），无外部库依赖 =========
 * - 仅 manager 可 mint/burn（通常设置为 AccrualModule）
 * - 转账钩子：_update（v5）里先合规检查，再自动入册
 */
contract LInterest is ERC20, Ownable {
    IComplianceGuard public guard;
    IHolderRegistry public registry;
    address public manager;

    uint8 private constant _DECIMALS = 18;

    event GuardSet(address indexed guard);
    event RegistrySet(address indexed registry);
    event ManagerSet(address indexed manager);

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {}

    /* ---------- 基础参数 ---------- */
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /* ---------- 管理员配置 ---------- */
    function setGuard(address g) external onlyOwner {
        guard = IComplianceGuard(g);
        emit GuardSet(g);
    }

    function setRegistry(address r) external onlyOwner {
        registry = IHolderRegistry(r);
        emit RegistrySet(r);
    }

    function setManager(address m) external onlyOwner {
        manager = m;
        emit ManagerSet(m);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "!manager");
        _;
    }

    /* ---------- 铸/销（仅 manager） ---------- */
    /// @notice 由计息模块按应计铸造利息
    function mint(address to, uint256 amount18) external onlyManager {
        _mint(to, amount18);
    }

    /// @notice 如需回滚或更正，可由计息模块销毁
    function burnFrom(address from, uint256 amount18) external onlyManager {
        _burn(from, amount18);
    }

    /* ---------- 转账钩子（v5 风格 _update） ----------
     * 这里在 super._update 前做合规检查，在后做自动入册。
     * - 铸币：from=address(0)，to=接收者（会走检查和入册）
     * - 转账：from!=0 && to!=0（会走检查和入册）
     * - 销毁：to=address(0)（跳过检查与入册）
     */
    function _update(address from, address to, uint256 value) internal override {
        // 合规检查：仅在不是销毁时检查“接收方是否可接收利息代币”
        if (to != address(0) && address(guard) != address(0)) {
            guard.checkInterest(from, to);
        }

        // 先更新余额/总量
        super._update(from, to, value);

        // 自动入册：仅在不是销毁时登记，失败不影响主流程
        if (to != address(0) && address(registry) != address(0)) {
            try registry.register(to) {} catch {}
        }
    }
}
