// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================
   HolderRegistry1.sol（名册：只增不删）
   ========================= */

contract HolderRegistry1 {
    address public owner;
    mapping(address => bool) public allowed;

    address[] private _holders;
    mapping(address => bool) private _seen;

    event OwnerChanged(address indexed prev, address indexed next);
    event AllowedSet(address indexed caller, bool allowed);
    event HolderAdded(address indexed holder);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address owner_) {
        owner = owner_;
        emit OwnerChanged(address(0), owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "0 owner");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setAllowed(address caller, bool isAllowed) external onlyOwner {
        allowed[caller] = isAllowed;
        emit AllowedSet(caller, isAllowed);
    }

    function register(address to) external {
        require(allowed[msg.sender], "not allowed");
        if (to == address(0)) return;
        if (!_seen[to]) {
            _seen[to] = true;
            _holders.push(to);
            emit HolderAdded(to);
        }
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    function holderAt(uint256 idx) external view returns (address) {
        return _holders[idx];
    }
}
