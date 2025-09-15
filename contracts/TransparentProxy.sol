// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================
   TransparentProxy.sol（最小 EIP-1967 透明代理 + changeAdmin）
   ========================= */

contract TransparentProxy {
    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // keccak256("eip1967.proxy.admin") - 1
    bytes32 private constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    event Upgraded(address indexed newImplementation);
    event AdminChanged(address previousAdmin, address newAdmin);

    modifier ifAdmin() {
        if (msg.sender == _admin()) {
            _;
        } else {
            _fallback();
        }
    }

    // ⚠️ 这里把参数由 `implementation` 改成 `impl_`
    constructor(address impl_, address admin_, bytes memory initCalldata) {
        require(impl_ != address(0) && admin_ != address(0), "bad params");
        _setAdmin(admin_);
        _setImplementation(impl_);
        if (initCalldata.length > 0) {
            (bool ok, ) = impl_.delegatecall(initCalldata);
            require(ok, "init fail");
        }
    }

    function implementation() external ifAdmin returns (address impl) {
        assembly { impl := sload(_IMPLEMENTATION_SLOT) }
    }

    function admin() external ifAdmin returns (address a) {
        assembly { a := sload(_ADMIN_SLOT) }
    }

    function changeAdmin(address newAdmin) external ifAdmin {
        require(newAdmin != address(0), "0 admin");
        address prev = _admin();
        _setAdmin(newAdmin);
        emit AdminChanged(prev, newAdmin);
    }

    function upgradeTo(address newImplementation) external ifAdmin returns (address) {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
        return newImplementation;
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data) external ifAdmin {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
        (bool ok, ) = newImplementation.delegatecall(data);
        require(ok, "upg call fail");
    }

    fallback() external payable { _fallback(); }
    receive() external payable { _fallback(); }

    function _fallback() internal {
        address impl = _implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _implementation() internal view returns (address impl) {
        assembly { impl := sload(_IMPLEMENTATION_SLOT) }
    }

    function _admin() internal view returns (address a) {
        assembly { a := sload(_ADMIN_SLOT) }
    }

    function _setImplementation(address newImplementation) internal {
        require(newImplementation.code.length > 0, "no code");
        assembly { sstore(_IMPLEMENTATION_SLOT, newImplementation) }
    }

    function _setAdmin(address newAdmin) internal {
        assembly { sstore(_ADMIN_SLOT, newAdmin) }
    }
}

