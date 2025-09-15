// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================
   RWAManager.sol（集中“布线”与常用运维入口）
   ========================= */

interface IRegistryAdmin {
    function setAllowed(address caller, bool isAllowed) external;
}

interface ITokenManager {
    function setManager(address m) external;
}

contract RWAManager {
    address public owner;

    address public guard;
    address public registry;
    address public principal;
    address public interest;
    address public accrual;
    address public exchange;

    event OwnerChanged(address indexed prev, address indexed next);

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

    function setAddresses(
        address guard_,
        address registry_,
        address principal_,
        address interest_,
        address accrual_,
        address exchange_
    ) external onlyOwner {
        guard = guard_; registry = registry_;
        principal = principal_; interest = interest_;
        accrual = accrual_; exchange = exchange_;
    }

    /* 一次性把名册的可调用方授权 + 配好两种 Token 的 manager  */
    function wireRegistryAndManagers(
        address[] calldata allowCallers,        // 建议传 [principal, interest, exchange, accrual]
        address principalManager,               // 一般填 ExchangeModule
        address interestManager                 // 一般填 AccrualModule
    ) external onlyOwner {
        if (registry != address(0)) {
            IRegistryAdmin R = IRegistryAdmin(registry);
            for (uint256 i=0; i<allowCallers.length; i++) {
                R.setAllowed(allowCallers[i], true);
            }
        }
        if (principal != address(0) && principalManager != address(0)) {
            ITokenManager(principal).setManager(principalManager);
        }
        if (interest != address(0) && interestManager != address(0)) {
            ITokenManager(interest).setManager(interestManager);
        }
    }
}
