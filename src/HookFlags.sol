// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookFlags
/// @notice The 14 permission bits a Uniswap v4 hook address carries, and helpers to read them.
/// @dev Mirrors `Hooks.sol` from v4-core as plain constants so scripts and tests can mine and check
/// addresses without pulling the whole library in.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask of every permission bit.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The permission bits carried by `hook`.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook` carries exactly the permission bits in `flags` (and no others).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }

    /// @notice Computes the CREATE2 address `deployer` would produce for `initCodeHash` and `salt`.
    function create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Finds the first salt (counting up from zero) that lands `initCode` on an empty address whose
    /// permission bits are exactly `flags` when deployed by `deployer` with CREATE2.
    /// @dev Bounded so a script or test cannot spin forever; 3 fixed bits out of 14 means roughly 16k tries
    /// on average. Addresses that already hold code are skipped so a second deployment finds a fresh salt.
    function mineSalt(address deployer, uint160 flags, bytes32 initCodeHash, uint256 maxTries)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i = 0; i < maxTries; i++) {
            salt = bytes32(i);
            predicted = create2Address(deployer, salt, initCodeHash);
            if (matches(predicted, flags) && predicted.code.length == 0) return (salt, predicted);
        }
        revert("HookFlags: no salt found");
    }
}
