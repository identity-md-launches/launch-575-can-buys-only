// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyGateHook} from "../src/BuyGateHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    Deploy script;
    PoolManager manager;

    function setUp() public {
        script = new Deploy();
        manager = new PoolManager(address(this));
    }

    function test_deployPlacesTheHookOnAFlaggedAddress() public {
        (SurfToken token, BuyGateHook hook) = script.deploy(IPoolManager(address(manager)), address(script));
        assertEq(HookFlags.flagsOf(address(hook)), script.hookFlags());
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.genesis(), 0, "not bound until a pool is initialized");
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(script)), 10 ** 27, "the deployer holds the whole supply");
    }

    function test_minedSaltIsDeterministicForADeployer() public view {
        (bytes32 a, address pa) = script.mineHookSalt(IPoolManager(address(manager)), address(script));
        (bytes32 b, address pb) = script.mineHookSalt(IPoolManager(address(manager)), address(script));
        assertEq(a, b);
        assertEq(pa, pb);
        assertTrue(HookFlags.matches(pa, script.hookFlags()));
    }

    function test_differentManagerGivesADifferentAddress() public {
        PoolManager other = new PoolManager(address(this));
        (, address pa) = script.mineHookSalt(IPoolManager(address(manager)), address(script));
        (, address pb) = script.mineHookSalt(IPoolManager(address(other)), address(script));
        assertTrue(pa != pb);
    }
}
