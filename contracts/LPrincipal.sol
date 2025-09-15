// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ========== 外部接口（与原套件一致的最小集） ========== */
interface IComplianceGuard {
    function checkPrincipal(address from, address to) external view;
}

interface IHolderRegistry {
    function register(address to) external;
}

/* ========== 最小 Ownable（兼容 OZ v5 构造：Ownable(owner_)） ========== */
abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

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
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

/* ========== 最小 ERC20（v5 风格：一切经由 _update） ========== */
abstract contract ERC20 {
    /* 标准事件 */
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    /* 元数据 */
    string private _name;
    string private _symbol;

    /* 账本 */
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /* --- 视图函数 --- */
    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(
        address owner_,
        address spender
    ) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    /* --- 状态变更 --- */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        _update(msg.sender, to, value);
        return true;
    }

    function approve(
        address spender,
        uint256 value
    ) public virtual returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public virtual returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _update(from, to, value);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            msg.sender,
            spender,
            _allowances[msg.sender][spender] + addedValue
        );
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        uint256 current = _allowances[msg.sender][spender];
        require(
            current >= subtractedValue,
            "ERC20: decreased allowance below zero"
        );
        unchecked {
            _allowances[msg.sender][spender] = current - subtractedValue;
        }
        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    /* --- v5 风格核心：所有路径走 _update --- */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // mint
            require(to != address(0), "ERC20: mint to zero");
            _totalSupply += value;
            _balances[to] += value;
            emit Transfer(address(0), to, value);
        } else if (to == address(0)) {
            // burn
            uint256 fromBal = _balances[from];
            require(fromBal >= value, "ERC20: burn exceeds balance");
            unchecked {
                _balances[from] = fromBal - value;
            }
            _totalSupply -= value;
            emit Transfer(from, address(0), value);
        } else {
            // transfer
            uint256 fromBal2 = _balances[from];
            require(fromBal2 >= value, "ERC20: transfer exceeds balance");
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

    function _approve(
        address owner_,
        address spender,
        uint256 value
    ) internal virtual {
        require(
            owner_ != address(0) && spender != address(0),
            "ERC20: zero address"
        );
        _allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    function _spendAllowance(
        address owner_,
        address spender,
        uint256 value
    ) internal virtual {
        uint256 current = _allowances[owner_][spender];
        if (current != type(uint256).max) {
            require(current >= value, "ERC20: insufficient allowance");
            unchecked {
                _allowances[owner_][spender] = current - value;
            }
            emit Approval(owner_, spender, _allowances[owner_][spender]);
        }
    }
}

/* ========== LPrincipal（6位小数、仅构造时铸造、无外部 mint/burn） ========== */
contract LPrincipal is ERC20, Ownable {
    IComplianceGuard public guard;
    IHolderRegistry public registry;

    uint8 private constant _DECIMALS = 6;

    event GuardSet(address indexed guard);
    event RegistrySet(address indexed registry);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply6, // 例如 1_000_000 * 1e6
        address supplyReceiver, // 初始库存接收方
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        require(supplyReceiver != address(0), "supplyReceiver=0");
        _mint(supplyReceiver, initialSupply6);
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /* --- 管理配置 --- */
    function setGuard(address g) external onlyOwner {
        guard = IComplianceGuard(g);
        emit GuardSet(g);
    }

    function setRegistry(address r) external onlyOwner {
        registry = IHolderRegistry(r);
        emit RegistrySet(r);
    }

    /* --- _update 钩子：合规在前、登记在后（含 mint/transfer；burn 跳过） --- */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (to != address(0) && address(guard) != address(0)) {
            // 对“接收”进行合规校验（包含 mint 与普通转账）
            guard.checkPrincipal(from, to);
        }
        super._update(from, to, value);
        if (to != address(0) && address(registry) != address(0)) {
            // 自动入册（失败不中断主流程）
            try registry.register(to) {} catch {}
        }
    }

    // ❌ 不提供对外 mint/burn；总量固定为构造函数铸造量
}
