// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   ComplianceGuardV2 (single-file, no external imports)
   - 白名单/黑名单/冻结/暂停/赎回屏蔽/时间锁/制裁Oracle
   - KYC 等级(kycTier) 与过期(kycExpireAt)
   - EIP-712 后台签名 setWhitelistBySig(...)
   - Merkle 批量激活 activateByProof(...)
   与旧版函数签名保持兼容。
   ========================================================= */

/* ============== Minimal Ownable (constructor: Ownable(owner_)) ============== */
abstract contract Ownable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: zero owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }
    modifier onlyOwner() { require(msg.sender == _owner, "Ownable: not owner"); _; }
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

/* ============== Minimal ECDSA (subset) ============== */
library ECDSA {
    // secp256k1n/2
    // 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
    bytes32 private constant _HALF_ORDER = bytes32(
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
    );

    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        require(uint256(s) <= uint256(_HALF_ORDER), "ECDSA: invalid 's'");
        require(v == 27 || v == 28, "ECDSA: invalid 'v'");
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "ECDSA: invalid signature");
        return signer;
    }
}

/* ============== Minimal EIP712 (OZ-like) ============== */
abstract contract EIP712 {
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _TYPE_HASH;

    // Cache chainId & domain separator like OZ
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;

    constructor(string memory name, string memory version) {
        _HASHED_NAME    = keccak256(bytes(name));
        _HASHED_VERSION = keccak256(bytes(version));
        _TYPE_HASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_THIS = address(this);
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    function _buildDomainSeparator(
        bytes32 typeHash,
        bytes32 nameHash,
        bytes32 versionHash
    ) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }
}

/* ============== Minimal MerkleProof (sorted pair) ============== */
library MerkleProof {
    function verifyCalldata(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        return processProofCalldata(proof, leaf) == root;
    }

    function processProofCalldata(
        bytes32[] calldata proof,
        bytes32 leaf
    ) internal pure returns (bytes32 computedHash) {
        computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
    }
}

/* ============== External Oracle Interface ============== */
interface ISanctionsOracle {
    function isSanctioned(address a) external view returns (bool);
}

/* ============== ComplianceGuardV2 ============== */
contract ComplianceGuardV2 is Ownable, EIP712 {
    using ECDSA for bytes32;

    /* ---------- 旧版存储（兼容） ---------- */
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blocked;
    mapping(address => bool) public freezeInPrincipal;
    mapping(address => bool) public freezeOutPrincipal;
    mapping(address => bool) public freezeInInterest;
    mapping(address => bool) public freezeOutInterest;
    mapping(address => uint64) public lockUntil;
    mapping(address => bool) public redeemBlocked;
    ISanctionsOracle public oracle;
    bool public transfersPaused;

    /* ---------- 新增：KYC 等级 & 过期 ---------- */
    mapping(address => uint8)  public kycTier;      // 0=未评级/最低
    mapping(address => uint64) public kycExpireAt;  // 0=不过期

    // 不同动作的 KYC 等级门槛（默认0）
    uint8 public minTierPrincipal;
    uint8 public minTierInterest;
    uint8 public minTierRedeem;

    /* ---------- 新增：EIP-712 后台签名 ---------- */
    address public verifier; // 后台签名公钥（可轮换）
    mapping(address => uint256) public nonces; // 每个 user 的防重放 nonce

    // keccak256("WhitelistPermit(address user,bool allow,uint8 tier,uint64 expireAt,uint256 nonce,uint256 deadline)")
    bytes32 public constant WHITELIST_TYPEHASH =
        0x0f6fc71c5a5f4b09d8e1b5c8e1a70a4b9f9d5b8a8b7db0babb7b6a7f7c8c2a1a;

    /* ---------- 新增：Merkle 批量 ---------- */
    bytes32 public whitelistMerkleRoot; // 叶子 = keccak256(abi.encode(user, allow, tier, expireAt))

    /* ---------- 事件 ---------- */
    event WhitelistSet(address indexed a, bool v);
    event BlockedSet(address indexed a, bool v);
    event FreezeInP(address indexed a, bool v);
    event FreezeOutP(address indexed a, bool v);
    event FreezeInI(address indexed a, bool v);
    event FreezeOutI(address indexed a, bool v);
    event LockUntil(address indexed a, uint64 ts);
    event RedeemBlocked(address indexed a, bool v);
    event TransfersPaused(bool v);
    event OracleSet(address indexed o);

    event VerifierSet(address indexed v);
    event MinTiersSet(uint8 principal, uint8 interest, uint8 redeem);
    event KycStamped(address indexed user, bool allow, uint8 tier, uint64 expireAt);
    event WhitelistBySig(
        address indexed user,
        bool allow,
        uint8 tier,
        uint64 expireAt,
        uint256 nonce,
        uint256 deadline,
        address indexed relayer
    );
    event WhitelistMerkleRootSet(bytes32 root);
    event ActivatedByProof(address indexed user, bool allow, uint8 tier, uint64 expireAt);

    constructor(address owner_, address verifier_)
        Ownable(owner_)
        EIP712("ComplianceGuardV2", "1")
    {
        verifier = verifier_;
        emit VerifierSet(verifier_);
    }

    /* ======================== 管理接口 ======================== */
    function setWhitelist(address a, bool v) external onlyOwner { whitelist[a] = v; emit WhitelistSet(a, v); }
    function setBlocked(address a, bool v) external onlyOwner { blocked[a] = v; emit BlockedSet(a, v); }
    function setFreezeInPrincipal(address a, bool v) external onlyOwner { freezeInPrincipal[a]=v; emit FreezeInP(a,v); }
    function setFreezeOutPrincipal(address a, bool v) external onlyOwner { freezeOutPrincipal[a]=v; emit FreezeOutP(a,v); }
    function setFreezeInInterest(address a, bool v) external onlyOwner { freezeInInterest[a]=v; emit FreezeInI(a,v); }
    function setFreezeOutInterest(address a, bool v) external onlyOwner { freezeOutInterest[a]=v; emit FreezeOutI(a,v); }
    function setLockUntil(address a, uint64 ts) external onlyOwner { lockUntil[a]=ts; emit LockUntil(a, ts); }
    function setRedeemBlocked(address a, bool v) external onlyOwner { redeemBlocked[a]=v; emit RedeemBlocked(a,v); }
    function setPaused(bool v) external onlyOwner { transfersPaused = v; emit TransfersPaused(v); }
    function setOracle(address o) external onlyOwner { oracle = ISanctionsOracle(o); emit OracleSet(o); }

    function setVerifier(address v_) external onlyOwner { verifier = v_; emit VerifierSet(v_); }
    function setMinTiers(uint8 principal, uint8 interest, uint8 redeem) external onlyOwner {
        minTierPrincipal = principal; minTierInterest = interest; minTierRedeem = redeem;
        emit MinTiersSet(principal, interest, redeem);
    }
    function setWhitelistMerkleRoot(bytes32 root) external onlyOwner { whitelistMerkleRoot = root; emit WhitelistMerkleRootSet(root); }

    /* ======================== EIP-712 自动上白 ======================== */
    /// @notice 后台签名，将 user 上白/撤白，并写入 tier/expireAt；任何人可代付gas调用
    function setWhitelistBySig(
        address user,
        bool allow,
        uint8 tier,
        uint64 expireAt,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(block.timestamp <= deadline, "sig expired");
        require(nonce == nonces[user], "bad nonce");

        bytes32 structHash = keccak256(abi.encode(
            WHITELIST_TYPEHASH,
            user, allow, tier, expireAt, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        require(signer == verifier, "bad signer");

        // consume nonce & stamp KYC
        unchecked { nonces[user] = nonce + 1; }
        _stampKyc(user, allow, tier, expireAt);
        emit WhitelistBySig(user, allow, tier, expireAt, nonce, deadline, msg.sender);
    }

    /* ======================== Merkle 批量激活（可选） ======================== */
    function activateByProof(
        address user,
        bool allow,
        uint8 tier,
        uint64 expireAt,
        bytes32[] calldata proof
    ) external {
        bytes32 leaf = keccak256(abi.encode(user, allow, tier, expireAt));
        require(MerkleProof.verifyCalldata(proof, whitelistMerkleRoot, leaf), "bad proof");
        _stampKyc(user, allow, tier, expireAt);
        emit ActivatedByProof(user, allow, tier, expireAt);
    }

    /* ======================== 内部：写入KYC状态 ======================== */
    function _stampKyc(address user, bool allow, uint8 tier, uint64 expireAt) internal {
        whitelist[user]  = allow;
        kycTier[user]    = tier;
        kycExpireAt[user]= expireAt;
        emit KycStamped(user, allow, tier, expireAt);
    }

    /* ======================== 旧接口：Token 钩子检查 ======================== */
    function _baseFrom(address from) internal view {
        if (from == address(0)) return; // mint
        require(!transfersPaused, "paused");
        require(!blocked[from], "from blocked");
        require(lockUntil[from]==0 || block.timestamp >= lockUntil[from], "from locked");
        if (address(oracle) != address(0)) require(!oracle.isSanctioned(from), "from sanctioned");
    }

    function _passesKyc(address a, uint8 minTierReq) internal view returns (bool ok, string memory reason) {
        if (transfersPaused)      return (false, "paused");
        if (blocked[a])           return (false, "blocked");
        if (!whitelist[a])        return (false, "not whitelisted");
        if (lockUntil[a]!=0 && block.timestamp < lockUntil[a]) return (false, "locked");
        if (address(oracle) != address(0) && oracle.isSanctioned(a)) return (false, "sanctioned");
        if (kycExpireAt[a]!=0 && block.timestamp > kycExpireAt[a])  return (false, "kyc expired");
        if (kycTier[a] < minTierReq) return (false, "kyc tier");
        return (true, "");
    }

    function checkPrincipal(address from, address to) external view {
        _baseFrom(from);
        if (to != address(0)) {
            (bool ok, string memory why) = _passesKyc(to, minTierPrincipal);
            require(ok, string.concat("principal to: ", why));
            require(!freezeInPrincipal[to],  "principal: to frozen");
        }
        if (from != address(0)) require(!freezeOutPrincipal[from], "principal: from frozen");
    }

    function checkInterest(address from, address to) external view {
        _baseFrom(from);
        if (to != address(0)) {
            (bool ok, string memory why) = _passesKyc(to, minTierInterest);
            require(ok, string.concat("interest to: ", why));
            require(!freezeInInterest[to],  "interest: to frozen");
        }
        if (from != address(0)) require(!freezeOutInterest[from], "interest: from frozen");
    }

    /* ======================== 旧接口：便捷布尔 ======================== */
    function canReceivePrincipal(address a) external view returns (bool) {
        (bool ok,) = _passesKyc(a, minTierPrincipal);
        return ok && !freezeInPrincipal[a];
    }

    function canReceiveInterest(address a) external view returns (bool) {
        (bool ok,) = _passesKyc(a, minTierInterest);
        return ok && !freezeInInterest[a];
    }

    function canRedeem(address a) external view returns (bool) {
        (bool ok,) = _passesKyc(a, minTierRedeem);
        if (!ok) return false;
        if (redeemBlocked[a]) return false;
        return true;
    }
}
