// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {SurfToken} from "../src/SurfToken.sol";
import {BuyGateHook} from "../src/BuyGateHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLaunchFactory} from "./mocks/MockLaunchFactory.sol";

/// @notice A voter that tries to cast its vote inside a PoolManager unlock, after flash-taking every token
/// the manager holds so that the quorum snapshot would see a manager balance of zero.
contract FlashVoter is IUnlockCallback {
    PoolManager immutable manager;
    SurfToken immutable token;
    BuyGateHook immutable hook;

    constructor(PoolManager _manager, SurfToken _token, BuyGateHook _hook) {
        manager = _manager;
        token = _token;
        hook = _hook;
    }

    function prepare() external {
        token.approve(address(hook), 1);
        hook.deposit(1);
    }

    function voteWhileUnlocked(bool support) external {
        manager.unlock(abi.encode(support));
    }

    function voteLocked(bool support) external {
        hook.vote(support);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Currency surf = Currency.wrap(address(token));
        uint256 amount = token.balanceOf(address(manager));
        manager.take(surf, address(this), amount);
        hook.vote(abi.decode(data, (bool))); // reverts: the hook refuses to vote while the manager is unlocked
        manager.sync(surf);
        token.transfer(address(manager), amount);
        manager.settle();
        return "";
    }
}

/// @notice A liquidity router anyone can call that also initializes pools, the way PositionManager's
/// `initializePool` does. Models a launch that goes through shared infrastructure.
contract SharedLaunchRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }
}

/// @notice Lifecycle tests for the hook against a real PoolManager: initialization, buys, blocked sells,
/// votes, the one-hour window and the 50% allowance.
contract BuyGateHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant START = 1_800_000_000;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;

    PoolManager manager;
    SurfToken token;
    BuyGateHook hook;
    Deploy deployer;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public {
        vm.warp(START);
        manager = new PoolManager(address(this));
        deployer = new Deploy();
        (token, hook) = deployer.deploy(IPoolManager(address(manager)), address(deployer));

        // The script deployed the token, so it holds the supply; take it for the tests.
        uint256 supply = token.totalSupply();
        vm.prank(address(deployer));
        token.transfer(address(this), supply);

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        vm.deal(address(this), 100_000 ether);

        // Full-range liquidity at 1:1, roughly 10,000 ETH and 10,000 tokens.
        lpRouter.modifyLiquidity{value: 10_100 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 10_000 ether, bytes32(0)), ""
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function buyExactIn(uint256 ethIn) internal returns (uint256 tokensOut) {
        BalanceDelta delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        tokensOut = uint256(int256(delta.amount1()));
    }

    function buyExactOut(uint256 tokensWanted, uint256 maxEth) internal returns (uint256 ethIn) {
        BalanceDelta delta = swapRouter.swap{value: maxEth}(
            key,
            SwapParams(true, int256(tokensWanted), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ethIn = uint256(-int256(delta.amount0()));
    }

    function sellExactIn(uint256 tokensIn) internal returns (uint256 ethOut) {
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams(false, -int256(tokensIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ethOut = uint256(int256(delta.amount0()));
    }

    function sellExactOut(uint256 ethWanted) internal returns (uint256 tokensIn) {
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams(false, int256(ethWanted), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        tokensIn = uint256(-int256(delta.amount1()));
    }

    /// @dev The PoolManager wraps a hook revert in `WrappedError(hook, callbackSelector, reason, HookCallFailed)`.
    function expectHookRevert(bytes4 callback, bytes memory reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function giveStake(address voter, uint256 amount) internal {
        token.transfer(voter, amount);
        vm.startPrank(voter);
        token.approve(address(hook), amount);
        hook.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Moves to the start of `day` (plus `offset` seconds).
    function warpToDay(uint256 day, uint256 offset) internal {
        vm.warp(hook.dayStart(day) + offset);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment and permissions
    // ---------------------------------------------------------------------------------------------

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        uint160 expected =
            HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
        assertEq(expected, 0x28C0);
        assertEq(HookFlags.flagsOf(address(hook)), expected);
        assertEq(deployer.hookFlags(), expected);

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_constructorRefusesAnAddressWithoutTheFlags() public {
        // A plain `new` lands on an address with (almost surely) the wrong bits.
        vm.expectRevert();
        new BuyGateHook(IPoolManager(address(manager)));
    }

    function test_poolManagerIsTheConstructorArgument() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------

    function test_initializationBoundThePool() public view {
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(poolId));
        assertEq(address(hook.token()), address(token));
        assertEq(hook.genesis(), START);
        assertEq(hook.initializer(), address(this), "the caller of initialize is recorded");
        assertTrue(hook.seeded(), "setUp added the first position");
        assertEq(hook.currentDay(), 0);
        assertFalse(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), 0);
    }

    function test_secondPoolIsRefused() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000 ether);
        PoolKey memory second = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(other)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        expectHookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(BuyGateHook.AlreadyBound.selector));
        manager.initialize(second, SQRT_PRICE_1_1);
    }

    function test_initializationRefusesWrongFeeTickSpacingAndNonNativeQuote() public {
        // A fresh hook that is not bound yet.
        BuyGateHook fresh = deployer.deployHook(IPoolManager(address(manager)), address(deployer));
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000 ether);

        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyGateHook.WrongFee.selector, uint24(10_000)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        k.fee = 3_000;
        k.tickSpacing = 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyGateHook.WrongTickSpacing.selector, int24(10)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        k.tickSpacing = 60;
        (Currency c0, Currency c1) = address(other) < address(token)
            ? (Currency.wrap(address(other)), Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), Currency.wrap(address(other)));
        k.currency0 = c0;
        k.currency1 = c1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyGateHook.QuoteMustBeNativeEth.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        assertEq(fresh.genesis(), 0, "a refused initialization must not bind");
    }

    function test_unboundHookRejectsGovernanceAndViews() public {
        BuyGateHook fresh = deployer.deployHook(IPoolManager(address(manager)), address(deployer));
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.currentDay();
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.deposit(1);
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.vote(true);
    }

    // ---------------------------------------------------------------------------------------------
    // Caller checks
    // ---------------------------------------------------------------------------------------------

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(BuyGateHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(BuyGateHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0)), "");

        vm.expectRevert(BuyGateHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");

        vm.expectRevert(BuyGateHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), ""
        );
    }

    function test_unimplementedCallbacksRevertEvenForThePoolManager() public {
        vm.startPrank(address(manager));
        vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(
            address(this),
            key,
            ModifyLiquidityParams(-60, 60, 1, bytes32(0)),
            BalanceDelta.wrap(0),
            BalanceDelta.wrap(0),
            ""
        );
        vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, -1, bytes32(0)), "");
        vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Buys
    // ---------------------------------------------------------------------------------------------

    function test_buyExactInPassesAndIsRecorded() public {
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 out = buyExactIn(1 ether);
        assertGt(out, 0);
        assertEq(token.balanceOf(address(this)), tokensBefore + out);
        (,,,, uint256 bought,) = hook.records(0);
        assertEq(bought, out);
    }

    function test_buyExactOutPassesAndIsRecorded() public {
        uint256 ethBefore = address(this).balance;
        uint256 paid = buyExactOut(5 ether, 10 ether);
        assertGt(paid, 5 ether, "0.3% fee and slippage make ETH in exceed tokens out at 1:1");
        assertEq(address(this).balance, ethBefore - paid, "router refunded the unused ETH");
        (,,,, uint256 bought,) = hook.records(0);
        assertEq(bought, 5 ether);
    }

    function test_buysAccumulatePerDay() public {
        uint256 a = buyExactIn(1 ether);
        uint256 b = buyExactIn(2 ether);
        (,,,, uint256 day0,) = hook.records(0);
        assertEq(day0, a + b);

        warpToDay(1, 10 minutes);
        uint256 c = buyExactIn(3 ether);
        (,,,, uint256 day1,) = hook.records(1);
        assertEq(day1, c);
        (,,,, day0,) = hook.records(0);
        assertEq(day0, a + b, "earlier days are untouched");
    }

    function test_buyWorksOnATokensOnlyPool() public {
        // A pool seeded the way the launch seeds it: tokens only. Token is currency1, so the range sits
        // below the current price, where a buy (ETH in, price down) finds it.
        PoolManager freshManager = new PoolManager(address(this));
        BuyGateHook freshHook = deployer.deployHook(IPoolManager(address(freshManager)), address(deployer));
        PoolSwapTest freshSwap = new PoolSwapTest(IPoolManager(address(freshManager)));
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(IPoolManager(address(freshManager)));
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });
        freshManager.initialize(k, SQRT_PRICE_1_1);
        token.approve(address(freshLp), type(uint256).max);
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1_000 ether, bytes32(0)), "");
        assertEq(address(freshManager).balance, 0, "no ETH in the manager");

        uint256 before = token.balanceOf(address(this));
        BalanceDelta delta = freshSwap.swap{value: 1 ether}(
            k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 out = uint256(int256(delta.amount1()));
        assertGt(out, 0);
        assertEq(token.balanceOf(address(this)), before + out);
        (,,,, uint256 bought,) = freshHook.records(0);
        assertEq(bought, out);
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity belongs to the launch
    // ---------------------------------------------------------------------------------------------

    function expectLiquidityRefused(address sender) internal {
        expectHookRevert(
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, sender)
        );
    }

    function test_thirdPartyCannotAddLiquidityAfterTheSeed() public {
        // The pool is seeded (setUp). A holder who tries to add through the same router is refused: the
        // pool is seeded and this is not the initialization transaction.
        token.transfer(alice, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), "");
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1 ether, bytes32(0)), ""
        );
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000 ether, "nothing left the holder");

        // The launch itself cannot add after the seed either, through any router: the hook cannot tell
        // the callers of a shared router apart, so it admits nobody once the initialization transaction ends.
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1 ether, bytes32(0)), ""
        );
    }

    function test_usersOfTheRouterThatInitializedThePoolAreRefusedAfterTheSeed() public {
        // The independent review's scenario: the launch initializes and seeds through a router that anyone
        // can drive (PositionManager.initializePool then modifyLiquidities). A rule keyed on the router that
        // called `initialize` would admit every user of that router; the hook keys on nothing of the kind,
        // so a stranger's position through the launch router is refused and the single-sided exit stays shut.
        PoolManager freshManager = new PoolManager(address(this));
        BuyGateHook freshHook = deployer.deployHook(IPoolManager(address(freshManager)), address(deployer));
        SharedLaunchRouter shared = new SharedLaunchRouter(IPoolManager(address(freshManager)));
        PoolSwapTest freshSwap = new PoolSwapTest(IPoolManager(address(freshManager)));
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });

        // Launch: initialize, then seed in a later call, both through the shared router.
        shared.initializePool(k, SQRT_PRICE_1_1);
        token.approve(address(shared), type(uint256).max);
        shared.modifyLiquidity{value: 10_100 ether}(
            k, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 10_000 ether, bytes32(0)), ""
        );
        assertEq(freshHook.initializer(), address(shared), "the shared router is what initialize saw");
        assertTrue(freshHook.seeded());

        // A stranger parks SURF just below the price through the very same router: refused.
        token.transfer(alice, 1_000 ether);
        vm.deal(bob, 10_000 ether);
        uint256 aliceEthBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(shared), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(freshHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, address(shared)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        shared.modifyLiquidity(k, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), "");
        vm.stopPrank();

        // A buy walks the price down through launch liquidity only; nothing reaches the stranger.
        vm.prank(bob);
        freshSwap.swap{value: 2_000 ether}(
            k, SwapParams(true, -1_200 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(alice.balance, aliceEthBefore, "no ETH reached the stranger");
        assertEq(token.balanceOf(alice), 1_000 ether, "the stranger still has every token");
        assertFalse(freshHook.sellWindowOpen());
    }

    function test_holderCannotExitThroughASingleSidedPositionWhileSellsAreClosed() public {
        // The reviewers' scenario: park SURF just below the price as a resting sell order, let a buy fill
        // it, remove the position and walk away with ETH. The add is refused, so nothing of the kind happens.
        token.transfer(alice, 1_000 ether);
        vm.deal(bob, 10_000 ether);
        uint256 aliceEthBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), "");
        vm.stopPrank();

        vm.prank(bob);
        swapRouter.swap{value: 2_000 ether}(
            key,
            SwapParams(true, -1_200 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(alice.balance, aliceEthBefore, "no ETH reached the holder");
        assertEq(token.balanceOf(alice), 1_000 ether, "the holder still has every token");
        assertFalse(hook.sellWindowOpen());
    }

    function test_selfLiquidityWashCannotInflateBought() public {
        // The reviewers' scenario: add a dense SURF-only position one spacing below the price, buy through
        // it with a price limit at its lower edge, remove it in the same breath. With the add refused, the
        // buy only takes what the launch liquidity sells in that range and `bought` equals exactly that.
        token.transfer(alice, 1_000_000 ether);
        vm.deal(alice, 2_000_000 ether);
        uint256 managerSurfBefore = token.balanceOf(address(manager));

        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 333_000_000 ether, bytes32(0)), "");

        BalanceDelta delta = swapRouter.swap{value: 1_100_000 ether}(
            key,
            SwapParams(true, -1_050_000 ether, TickMath.getSqrtPriceAtTick(-60)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        uint256 out = uint256(int256(delta.amount1()));
        uint256 netOut = managerSurfBefore - token.balanceOf(address(manager));
        (,,,, uint256 bought,) = hook.records(0);
        assertEq(bought, out);
        assertEq(bought, netOut, "every token counted as bought really left the pool");
        assertLt(bought, 100 ether, "a tick-spacing worth of launch liquidity, not a million tokens");
        assertEq(hook.sellAllowance(1), bought / 2);
    }

    function test_launchSeedsSeveralPositionsInTheInitializationTransaction() public {
        // The way the factory does it: initialize and seed in one transaction, as its own router. The
        // transient initialization flag admits every position in that transaction, even with a router the
        // hook has never seen.
        PoolManager freshManager = new PoolManager(address(this));
        BuyGateHook freshHook = deployer.deployHook(IPoolManager(address(freshManager)), address(deployer));
        MockLaunchFactory factory = new MockLaunchFactory(IPoolManager(address(freshManager)));
        token.transfer(address(factory), 1_000_000 ether);
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });

        ModifyLiquidityParams[] memory seed = new ModifyLiquidityParams[](2);
        seed[0] = ModifyLiquidityParams(MIN_TICK, -60, 400_000 ether, bytes32(0));
        seed[1] = ModifyLiquidityParams(-6_000, -60, 1_000 ether, bytes32(0));
        factory.launch(k, SQRT_PRICE_1_1, seed);

        assertEq(freshHook.initializer(), address(factory));
        assertTrue(freshHook.seeded());
        assertGt(token.balanceOf(address(freshManager)), 0);

        // Later, not even the factory may add, acting as its own router: the hook does not know whether a
        // router's later calls come from the launch or from anyone else, so it admits nobody after the
        // initialization transaction.
        ModifyLiquidityParams[] memory more = new ModifyLiquidityParams[](1);
        more[0] = ModifyLiquidityParams(MIN_TICK, -60, 1_000 ether, bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(freshHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, address(factory)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        factory.addLater(k, more);

        // Nobody else may either, and the flag did not leak out of the initialization transaction.
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(IPoolManager(address(freshManager)));
        token.approve(address(freshLp), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(freshHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, address(freshLp)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(-60, 0, 1_000 ether, bytes32(0)), "");

        // Buys still work on the factory-seeded pool.
        PoolSwapTest freshSwap = new PoolSwapTest(IPoolManager(address(freshManager)));
        BalanceDelta delta = freshSwap.swap{value: 1 ether}(
            k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertGt(uint256(int256(delta.amount1())), 0);
    }

    function test_firstPositionIsAcceptedFromAnyRouterOnlyOnce() public {
        // Seed in a later transaction through a shared router: the pool's first position is accepted
        // (this is what setUp relies on); a second position from the same router is not.
        PoolManager freshManager = new PoolManager(address(this));
        BuyGateHook freshHook = deployer.deployHook(IPoolManager(address(freshManager)), address(deployer));
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(IPoolManager(address(freshManager)));
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });
        freshManager.initialize(k, SQRT_PRICE_1_1);
        assertFalse(freshHook.seeded());

        token.approve(address(freshLp), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(freshHook));
        emit BuyGateHook.Seeded(address(freshLp));
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1_000 ether, bytes32(0)), "");
        assertTrue(freshHook.seeded());

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(freshHook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, address(freshLp)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1_000 ether, bytes32(0)), "");
    }

    function test_launchCanRemoveAndReaddItsLiquidity() public {
        // Removal is not gated: the launch unwinds through the router that holds its position. Re-adding
        // through that router is refused like any other add after the seed, so the launch should size its
        // seed once and keep it.
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, -5_000 ether, bytes32(0)), "");
        assertGt(address(this).balance, ethBefore);
        assertGt(token.balanceOf(address(this)), tokensBefore);

        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity{value: 5_100 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 5_000 ether, bytes32(0)), ""
        );
    }

    function testFuzz_thirdPartyPositionsAreAlwaysRefused(int24 lower, int24 upper, uint128 liquidity) public {
        lower = int24(bound(int256(lower), MIN_TICK / 60, MAX_TICK / 60 - 1)) * 60;
        upper = int24(bound(int256(upper), int256(lower) / 60 + 1, MAX_TICK / 60)) * 60;
        liquidity = uint128(bound(liquidity, 1, 1_000_000 ether));

        token.transfer(alice, 1_000_000 ether);
        vm.deal(alice, 1_000_000 ether);
        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity{value: 1_000_000 ether}(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)), ""
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Sells are closed by default
    // ---------------------------------------------------------------------------------------------

    function test_sellRevertsOnDayZero() public {
        buyExactIn(1 ether);
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(0.1 ether);
    }

    function test_sellRevertsWithoutAVote() public {
        buyExactIn(1 ether);
        warpToDay(1, 0);
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(0.1 ether);
    }

    function test_exactOutputSellRevertsWhenClosed() public {
        buyExactIn(1 ether);
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactOut(0.1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Voting mechanics
    // ---------------------------------------------------------------------------------------------

    function test_depositAndWithdrawWithoutVoting() public {
        giveStake(alice, 100 ether);
        assertEq(hook.stakeOf(alice), 100 ether);
        assertEq(token.balanceOf(address(hook)), 100 ether);

        vm.prank(alice);
        hook.withdraw(40 ether);
        assertEq(hook.stakeOf(alice), 60 ether);
        assertEq(token.balanceOf(alice), 40 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.InsufficientStake.selector, 61 ether, 60 ether));
        hook.withdraw(61 ether);

        vm.prank(alice);
        vm.expectRevert(BuyGateHook.ZeroAmount.selector);
        hook.withdraw(0);

        vm.prank(alice);
        vm.expectRevert(BuyGateHook.ZeroAmount.selector);
        hook.deposit(0);
    }

    function test_voteNeedsStake() public {
        vm.prank(alice);
        vm.expectRevert(BuyGateHook.NoStake.selector);
        hook.vote(true);
    }

    function test_voteOncePerDayAndLockedUntilDayEnds() public {
        giveStake(alice, 100 ether);
        assertFalse(hook.hasVoted(alice, 0));
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.hasVoted(alice, 0));
        assertEq(hook.lockedUntil(alice), hook.dayStart(1));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.AlreadyVoted.selector, 0));
        hook.vote(false);

        uint256 unlockAt = hook.dayStart(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.StakeLocked.selector, unlockAt));
        hook.withdraw(1 ether);

        warpToDay(1, 0);
        vm.prank(alice);
        hook.withdraw(100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertFalse(hook.hasVoted(alice, 1));
    }

    function test_hasVotedRemembersEveryDayAVoterVotedOn() public {
        giveStake(alice, 10 ether);
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, 0);
        vm.prank(alice);
        hook.vote(false);
        warpToDay(2, 0);

        assertTrue(hook.hasVoted(alice, 0), "day 0 is still tallied");
        assertTrue(hook.hasVoted(alice, 1));
        assertFalse(hook.hasVoted(alice, 2));
        assertFalse(hook.hasVoted(bob, 0));
        (uint256 yes0,,,,,) = hook.records(0);
        (, uint256 no1,,,,) = hook.records(1);
        assertEq(yes0, 10 ether);
        assertEq(no1, 10 ether);

        // Still one vote per day: day 2 accepts exactly one more.
        vm.prank(alice);
        hook.vote(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.AlreadyVoted.selector, 2));
        hook.vote(true);
    }

    function test_voteIsRefusedWhileTheManagerIsUnlocked() public {
        // A griefer with 1 wei of stake flash-takes every SURF the manager holds inside an unlock and tries
        // to cast the day's first vote, which would snapshot the quorum from a manager balance of zero.
        FlashVoter griefer = new FlashVoter(manager, token, hook);
        token.transfer(address(griefer), 1);
        griefer.prepare();

        uint256 managerBalance = token.balanceOf(address(manager));
        vm.expectRevert(BuyGateHook.ManagerUnlocked.selector);
        griefer.voteWhileUnlocked(false);
        assertEq(token.balanceOf(address(manager)), managerBalance, "the revert undid the flash take");

        (,, uint256 quorum, bool hasVotes,,) = hook.records(0);
        assertFalse(hasVotes, "no vote was recorded");
        assertEq(quorum, 0);

        // The same griefer votes fine once the manager is locked again, and the snapshot is honest.
        uint256 circulating = token.totalSupply() - token.balanceOf(address(manager));
        griefer.voteLocked(false);
        (,, quorum, hasVotes,,) = hook.records(0);
        assertTrue(hasVotes);
        assertEq(quorum, circulating * hook.QUORUM_BPS() / hook.BPS());

        // A yes vote that clears the honest quorum opens the window.
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.votePassed(0));
        warpToDay(1, 0);
        assertTrue(hook.sellWindowOpen());
    }

    function test_voteWeightIsTheStakeAtVoteTime() public {
        giveStake(alice, 100 ether);
        vm.prank(alice);
        hook.vote(true);
        (uint256 yes, uint256 no,,,,) = hook.records(0);
        assertEq(yes, 100 ether);
        assertEq(no, 0);

        // Depositing more after voting does not change today's weight.
        giveStake(alice, 50 ether);
        (yes,,,,,) = hook.records(0);
        assertEq(yes, 100 ether);
    }

    function test_quorumIsSnapshottedAtTheFirstVote() public {
        buyExactIn(10 ether); // puts tokens outside the manager
        uint256 circulating = token.totalSupply() - token.balanceOf(address(manager));
        giveStake(alice, 1 ether);
        vm.prank(alice);
        hook.vote(true);
        (,, uint256 quorum, bool hasVotes,,) = hook.records(0);
        assertTrue(hasVotes);
        assertEq(quorum, circulating * hook.QUORUM_BPS() / hook.BPS());

        // A later buy does not move the quorum of a day already snapshotted.
        buyExactIn(10 ether);
        giveStake(bob, 1 ether);
        vm.prank(bob);
        hook.vote(true);
        (,, uint256 quorumAfter,,,) = hook.records(0);
        assertEq(quorumAfter, quorum);
    }

    // ---------------------------------------------------------------------------------------------
    // Vote outcomes
    // ---------------------------------------------------------------------------------------------

    /// @dev The supply held by this test is "circulating", so quorum is 5% of nearly the whole supply
    /// minus what the pool holds. A big enough stake clears it.
    function stakeAboveQuorum() internal view returns (uint256) {
        return (token.totalSupply() - token.balanceOf(address(manager))) * hook.QUORUM_BPS() / hook.BPS() + 1;
    }

    function test_passedVoteOpensSellsForOneHourAtHalfOfPreviousDaysBuys() public {
        uint256 bought = buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.votePassed(0));
        assertFalse(hook.sellWindowOpen(), "the window opens tomorrow, not now");

        warpToDay(1, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellAllowance(1), bought / 2);
        assertEq(hook.sellRemaining(), bought / 2);

        uint256 ethBefore = address(this).balance;
        uint256 ethOut = sellExactIn(bought / 4);
        assertGt(ethOut, 0);
        assertEq(address(this).balance, ethBefore + ethOut);
        assertEq(hook.sellRemaining(), bought / 2 - bought / 4);
        (,,,,, uint256 sold) = hook.records(1);
        assertEq(sold, bought / 4);

        // The rest of the allowance, to the wei.
        sellExactIn(bought / 2 - bought / 4);
        assertEq(hook.sellRemaining(), 0);

        // One more wei is refused before the pool does anything.
        expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, 1, 0)
        );
        sellExactIn(1);
    }

    function test_sellLargerThanAllowanceIsRefusedUpFront() public {
        uint256 bought = buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, 30 minutes);
        expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, bought / 2 + 1, bought / 2)
        );
        sellExactIn(bought / 2 + 1);
    }

    function test_exactOutputSellIsCheckedAgainstTheAllowanceAfterTheSwap() public {
        uint256 bought = buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, 0);

        // Asking for a small amount of ETH needs fewer tokens than the allowance: passes, and the
        // actual token input is what gets charged.
        uint256 tokensIn = sellExactOut(0.5 ether);
        assertGt(tokensIn, 0);
        (,,,,, uint256 sold) = hook.records(1);
        assertEq(sold, tokensIn);

        // Asking for more ETH than half of yesterday's buys can pay for fails in afterSwap.
        vm.expectRevert(); // reason carries the exact token amount, which depends on pool math
        sellExactOut(bought);
        (,,,,, uint256 soldAfter) = hook.records(1);
        assertEq(soldAfter, tokensIn, "a reverted sell charges nothing");
    }

    function test_windowClosesAfterOneHour() public {
        buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);

        warpToDay(1, 1 hours - 1);
        assertTrue(hook.sellWindowOpen());
        sellExactIn(1 ether);

        warpToDay(1, 1 hours);
        assertFalse(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), 0);
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(1 ether);
    }

    function test_windowDoesNotCarryOverToTheNextDay() public {
        buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);

        // Nobody voted on day 1, so day 2 is closed even though day 0's vote passed.
        warpToDay(2, 0);
        assertFalse(hook.sellWindowOpen());
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(1 ether);
    }

    function test_voteFailsWithoutMajority() public {
        buyExactIn(10 ether);
        uint256 stake = stakeAboveQuorum();
        giveStake(alice, stake);
        giveStake(bob, stake + 1);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);
        assertFalse(hook.votePassed(0));

        warpToDay(1, 0);
        assertFalse(hook.sellWindowOpen());
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(1 ether);
    }

    function test_tieIsNotAMajority() public {
        buyExactIn(10 ether);
        uint256 stake = stakeAboveQuorum();
        giveStake(alice, stake);
        giveStake(bob, stake);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);
        assertFalse(hook.votePassed(0));
    }

    function test_voteFailsBelowQuorum() public {
        buyExactIn(10 ether);
        giveStake(alice, 1 ether); // far below 5% of circulating supply
        vm.prank(alice);
        hook.vote(true);
        (uint256 yes, uint256 no, uint256 quorum,,,) = hook.records(0);
        assertLt(yes + no, quorum);
        assertFalse(hook.votePassed(0));

        warpToDay(1, 0);
        assertFalse(hook.sellWindowOpen());
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(0.5 ether);
    }

    function test_passedVoteWithNoBuysOpensAnEmptyWindow() public {
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), 0);
        expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, 1 ether, 0)
        );
        sellExactIn(1 ether);
    }

    function test_votesCanRepeatEveryDay() public {
        uint256 day0 = buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);

        warpToDay(1, 10 minutes);
        sellExactIn(day0 / 2);
        uint256 day1 = buyExactIn(5 ether);
        vm.prank(alice);
        hook.vote(true);

        warpToDay(2, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), day1 / 2);
        sellExactIn(day1 / 2);
        assertEq(hook.sellRemaining(), 0);
    }

    function test_buysDuringTheWindowDoNotRaiseTheWindowsAllowance() public {
        uint256 day0 = buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);

        warpToDay(1, 0);
        buyExactIn(20 ether);
        assertEq(hook.sellAllowance(1), day0 / 2, "today's buys count for tomorrow");
        expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, day0 / 2 + 1, day0 / 2)
        );
        sellExactIn(day0 / 2 + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_buysAreAlwaysAllowedAndRecorded(uint256 ethIn, uint256 secondsIntoLaunch) public {
        ethIn = bound(ethIn, 1 wei, 1_000 ether);
        secondsIntoLaunch = bound(secondsIntoLaunch, 0, 30 days);
        vm.warp(START + secondsIntoLaunch);
        uint256 day = hook.currentDay();
        (,,,, uint256 before,) = hook.records(day);
        uint256 out = buyExactIn(ethIn);
        (,,,, uint256 after_,) = hook.records(day);
        assertEq(after_, before + out);
    }

    function testFuzz_sellsNeverExceedHalfOfYesterdaysBuys(uint256 ethIn, uint256 sellFraction, uint256 offset) public {
        ethIn = bound(ethIn, 0.01 ether, 1_000 ether);
        sellFraction = bound(sellFraction, 1, 20_000); // in bps of the allowance: up to 2x
        offset = bound(offset, 0, 1 hours - 1);

        uint256 bought = buyExactIn(ethIn);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, offset);

        uint256 allowance = bought / 2;
        uint256 attempt = allowance * sellFraction / 10_000;
        vm.assume(attempt > 0);

        if (attempt <= allowance) {
            sellExactIn(attempt);
            (,,,,, uint256 sold) = hook.records(1);
            assertEq(sold, attempt);
            assertLe(sold, allowance);
        } else {
            expectHookRevert(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, attempt, allowance)
            );
            sellExactIn(attempt);
        }
    }

    function testFuzz_sellsOutsideTheWindowAlwaysFail(uint256 offset) public {
        offset = bound(offset, 1 hours, 1 days - 1);
        buyExactIn(10 ether);
        giveStake(alice, stakeAboveQuorum());
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, offset);
        assertFalse(hook.sellWindowOpen());
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(1);
    }

    function testFuzz_majorityAndQuorumDecideTheVote(uint256 yesStake, uint256 noStake) public {
        buyExactIn(10 ether);
        uint256 quorum = stakeAboveQuorum() - 1;
        yesStake = bound(yesStake, 1, quorum * 2);
        noStake = bound(noStake, 1, quorum * 2);
        giveStake(alice, yesStake);
        giveStake(bob, noStake);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);

        (,, uint256 recordedQuorum,,,) = hook.records(0);
        bool expected = yesStake > noStake && yesStake + noStake >= recordedQuorum;
        assertEq(hook.votePassed(0), expected);
        warpToDay(1, 0);
        assertEq(hook.sellWindowOpen(), expected);
    }

    function testFuzz_depositsAreAlwaysRecoverable(uint256 amount, bool votes) public {
        amount = bound(amount, 1, 1_000_000 ether);
        giveStake(alice, amount);
        if (votes) {
            vm.prank(alice);
            hook.vote(true);
            warpToDay(1, 0);
        }
        vm.prank(alice);
        hook.withdraw(amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(hook.stakeOf(alice), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
