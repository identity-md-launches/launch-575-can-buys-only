// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyGateHook} from "../src/BuyGateHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title Deploy
/// @notice Rehearsal deployment of the launch token and the hook.
/// @dev On the network the launch factory deploys both contracts and initializes the pool itself; this
/// script exists so reviewers can reproduce the deployment offline and so tests exercise the same code
/// path. It reads no keys. Configuration comes from two environment variables read in `run()` only:
///   - `EXPECTED_CHAIN_ID`: 0 for a local rehearsal, 31337 for anvil, 11155111 for Sepolia;
///   - `POOL_MANAGER`: the chain's PoolManager (optional when EXPECTED_CHAIN_ID is 0 or 31337, where a
///     fresh manager is deployed for the rehearsal).
contract Deploy is Script {
    /// @notice The deterministic CREATE2 deployer `forge script` routes salted `new` through.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant ANVIL = 31337;
    uint256 public constant SEPOLIA = 11_155_111;

    /// @notice How many salts to try before giving up; matching all 14 bits needs ~16k on average.
    uint256 public constant MAX_SALT_TRIES = 500_000;

    /// @notice The permission bits the hook's address must carry: `0x28C0`.
    function hookFlags() public pure returns (uint160) {
        return
            HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
    }

    function run() external returns (SurfToken token, BuyGateHook hook) {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        if (expected != 0) {
            require(expected == ANVIL || expected == SEPOLIA, "Deploy: unsupported chain");
            require(block.chainid == expected, "Deploy: chain id mismatch");
        }

        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        if (poolManager == address(0)) {
            require(expected == 0 || expected == ANVIL, "Deploy: POOL_MANAGER required");
            // Local rehearsal only: a manager nobody else will use, deployed outside the broadcast.
            poolManager = address(new PoolManager(address(0)));
        }

        vm.startBroadcast();
        (token, hook) = deploy(IPoolManager(poolManager), CREATE2_DEPLOYER);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token and then the hook at a mined address.
    /// @param poolManager the chain's PoolManager
    /// @param create2Deployer the address whose CREATE2 will place the hook (the caller itself in tests,
    /// the deterministic deployer proxy under `forge script`)
    function deploy(IPoolManager poolManager, address create2Deployer)
        public
        returns (SurfToken token, BuyGateHook hook)
    {
        token = new SurfToken();
        hook = deployHook(poolManager, create2Deployer);
    }

    /// @notice Mines a salt for `create2Deployer` and deploys the hook with it.
    function deployHook(IPoolManager poolManager, address create2Deployer) public returns (BuyGateHook hook) {
        (bytes32 salt, address predicted) = mineHookSalt(poolManager, create2Deployer);
        hook = new BuyGateHook{salt: salt}(poolManager);
        require(address(hook) == predicted, "Deploy: hook landed on an unexpected address");
    }

    /// @notice The salt and address the hook deploys to for a given deployer and manager.
    function mineHookSalt(IPoolManager poolManager, address create2Deployer)
        public
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(BuyGateHook).creationCode, abi.encode(poolManager)));
        return HookFlags.mineSalt(create2Deployer, hookFlags(), initCodeHash, MAX_SALT_TRIES);
    }
}
