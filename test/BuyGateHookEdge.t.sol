// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

import {SurfToken} from "../src/SurfToken.sol";
import {BuyGateHook} from "../src/BuyGateHook.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @notice A voter contract that acts from inside a PoolManager unlock: deposits, withdraws or votes
/// while the manager is unlocked, without taking anything from it. Used to pin which governance calls
/// the unlock guard refuses (only `vote`) and which it leaves alone.
contract UnlockActor is IUnlockCallback {
    PoolManager immutable manager;
    SurfToken immutable token;
    BuyGateHook immutable hook;

    enum Action {
        Deposit,
        Withdraw,
        Vote
    }

    constructor(PoolManager _manager, SurfToken _token, BuyGateHook _hook) {
        manager = _manager;
        token = _token;
        hook = _hook;
        token.approve(address(hook), type(uint256).max);
    }

    function depositLocked(uint256 amount) external {
        hook.deposit(amount);
    }

    function act(Action action, uint256 amount) external {
        manager.unlock(abi.encode(action, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Action action, uint256 amount) = abi.decode(data, (Action, uint256));
        if (action == Action.Deposit) hook.deposit(amount);
        else if (action == Action.Withdraw) hook.withdraw(amount);
        else hook.vote(true);
        return "";
    }
}

/// @notice A liquidity router anyone can call that also initializes pools, like PositionManager's
/// `initializePool`. When a launch goes through it, the hook records it as `initializer`.
contract InitializingRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }
}

/// @notice Adversarial and failure-path tests for `BuyGateHook`, beside the lifecycle suite in
/// `BuyGateHook.t.sol`: inputs the implementation did not obviously consider (zero, one wei, exact
/// boundaries, the same call twice, a caller the code did not expect, partial fills, claims-settled
/// swaps) and the arithmetic of the quorum and the allowance at its edges.
///
/// The two defects reported from the first version of this file (the one-sided liquidity exit and the
/// forgetful `hasVoted`) were fixed in the implementation's revision: `beforeAddLiquidity` now gates
/// positions and `hasVoted` keeps every day. The second revision dropped the gate's trust in the router
/// that called `initialize`. The tests at the end of this file probe that surface from the side the launch
/// does not control: strangers, hook data, an emptied pool, the initializing router, an unlock callback.
/// forge-config: default.fuzz.runs = 512
contract BuyGateHookEdgeTest is Test {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

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
    PoolClaimsTest claimsRouter;
    PoolKey key;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    receive() external payable {}

    function setUp() public {
        vm.warp(START);
        manager = new PoolManager(address(this));
        deployer = new Deploy();
        (token, hook) = deployer.deploy(IPoolManager(address(manager)), address(deployer));
        uint256 supply = token.totalSupply();
        vm.prank(address(deployer));
        token.transfer(address(this), supply);

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        claimsRouter = new PoolClaimsTest(IPoolManager(address(manager)));

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
        token.approve(address(claimsRouter), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        vm.deal(address(this), 100_000 ether);

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

    function sellExactIn(uint256 tokensIn) internal returns (uint256 ethOut) {
        return sellExactInWithLimit(tokensIn, TickMath.MAX_SQRT_PRICE - 1);
    }

    function sellExactInWithLimit(uint256 tokensIn, uint160 limit) internal returns (uint256 ethOut) {
        BalanceDelta delta = swapRouter.swap(
            key, SwapParams(false, -int256(tokensIn), limit), PoolSwapTest.TestSettings(false, false), ""
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

    function warpToDay(uint256 day, uint256 offset) internal {
        vm.warp(hook.dayStart(day) + offset);
    }

    function circulating() internal view returns (uint256) {
        return token.totalSupply() - token.balanceOf(address(manager));
    }

    /// @dev Five percent of what circulates right now: what the next first-vote-of-the-day snapshots.
    function quorumNow() internal view returns (uint256) {
        return circulating() * hook.QUORUM_BPS() / hook.BPS();
    }

    function bought(uint256 day) internal view returns (uint256 amount) {
        (,,,, amount,) = hook.records(day);
    }

    function sold(uint256 day) internal view returns (uint256 amount) {
        (,,,,, amount) = hook.records(day);
    }

    /// @dev Opens a window on day 1 backed by `ethIn` of day-0 buys; returns the day-0 token volume.
    function openDayOneWindow(uint256 ethIn) internal returns (uint256 boughtDay0) {
        boughtDay0 = buyExactIn(ethIn);
        // 5% of circulating supply plus a margin that covers every later buy (the pool holds 10,000 SURF).
        giveStake(alice, quorumNow() + 1_000 ether);
        vm.prank(alice);
        hook.vote(true);
        warpToDay(1, 0);
        assertTrue(hook.sellWindowOpen());
    }

    // ---------------------------------------------------------------------------------------------
    // Governance: the failure paths
    // ---------------------------------------------------------------------------------------------

    function test_depositWithoutApprovalReverts() public {
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1 ether)
        );
        hook.deposit(1 ether);
        assertEq(hook.stakeOf(alice), 0, "a failed deposit leaves no stake behind");
    }

    function test_depositMoreThanBalanceReverts() public {
        token.transfer(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1)
        );
        hook.deposit(1 ether + 1);
        vm.stopPrank();
        assertEq(hook.stakeOf(alice), 0);
    }

    function test_withdrawWithNoStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.InsufficientStake.selector, 1, 0));
        hook.withdraw(1);
    }

    function test_withdrawCannotTakeAnotherVotersStake() public {
        giveStake(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.InsufficientStake.selector, 1, 0));
        hook.withdraw(1);
        assertEq(hook.stakeOf(alice), 10 ether);
        assertEq(token.balanceOf(address(hook)), 10 ether);
    }

    function test_voteAfterWithdrawingEverythingReverts() public {
        giveStake(alice, 10 ether);
        vm.startPrank(alice);
        hook.withdraw(10 ether);
        vm.expectRevert(BuyGateHook.NoStake.selector);
        hook.vote(true);
        vm.stopPrank();
    }

    function test_depositAfterVotingIsLockedTooAndAddsNoWeight() public {
        giveStake(alice, 10 ether);
        vm.prank(alice);
        hook.vote(true);
        giveStake(alice, 5 ether);

        (uint256 yes,,,,,) = hook.records(0);
        assertEq(yes, 10 ether, "the later deposit does not vote today");

        // The whole stake, including the 5 ether that never voted, is locked until the day ends.
        uint256 until = hook.dayStart(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.StakeLocked.selector, until));
        hook.withdraw(1);

        warpToDay(1, 0);
        vm.prank(alice);
        hook.withdraw(15 ether);
        assertEq(token.balanceOf(alice), 15 ether);
    }

    function test_twoVotersTheSameDayAddUpAndAreBothLocked() public {
        giveStake(alice, 10 ether);
        giveStake(bob, 7 ether);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);

        (uint256 yes, uint256 no, uint256 quorum, bool hasVotes,,) = hook.records(0);
        assertEq(yes, 10 ether);
        assertEq(no, 7 ether);
        assertTrue(hasVotes);
        assertGt(quorum, 0);
        assertEq(hook.lockedUntil(alice), hook.dayStart(1));
        assertEq(hook.lockedUntil(bob), hook.dayStart(1));

        uint256 until = hook.dayStart(1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.StakeLocked.selector, until));
        hook.withdraw(1);
    }

    function test_sameVoterVotesOnConsecutiveDays() public {
        giveStake(alice, 10 ether);
        vm.prank(alice);
        hook.vote(true);

        warpToDay(1, 0);
        vm.prank(alice);
        hook.vote(false);
        assertEq(hook.lockedUntil(alice), hook.dayStart(2), "the lock moved to the end of day 1");

        (uint256 yes0,,,,,) = hook.records(0);
        (, uint256 no1,,,,) = hook.records(1);
        assertEq(yes0, 10 ether);
        assertEq(no1, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.AlreadyVoted.selector, 1));
        hook.vote(true);
    }

    function test_voteInTheLastSecondOfTheDayCountsForThatDayAndUnlocksNextSecond() public {
        giveStake(alice, quorumNow() + 1);
        warpToDay(1, 0);
        vm.warp(hook.dayStart(1) - 1);
        assertEq(hook.currentDay(), 0);
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.votePassed(0));
        assertEq(hook.lockedUntil(alice), hook.dayStart(1));

        vm.warp(hook.dayStart(1));
        assertTrue(hook.sellWindowOpen(), "a last-second vote still opens the next day");
        vm.prank(alice);
        hook.withdraw(1);
    }

    function test_voteAtExactlyTheDayBoundaryBelongsToTheNewDay() public {
        giveStake(alice, 10 ether);
        warpToDay(1, 0);
        vm.prank(alice);
        hook.vote(true);
        (uint256 yes0,,, bool hasVotes0,,) = hook.records(0);
        (uint256 yes1,,, bool hasVotes1,,) = hook.records(1);
        assertEq(yes0, 0);
        assertFalse(hasVotes0);
        assertEq(yes1, 10 ether);
        assertTrue(hasVotes1);
    }

    function test_partialWithdrawThenVoteWeighsTheRemainder() public {
        giveStake(alice, 10 ether);
        vm.startPrank(alice);
        hook.withdraw(4 ether);
        hook.vote(true);
        vm.stopPrank();
        (uint256 yes,,,,,) = hook.records(0);
        assertEq(yes, 6 ether);
    }

    function test_hasVotedIsFalseForDaysWithoutAVoteAndForTheFuture() public {
        giveStake(alice, 10 ether);
        assertFalse(hook.hasVoted(alice, 0));
        assertFalse(hook.hasVoted(bob, 0));
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.hasVoted(alice, 0));
        assertFalse(hook.hasVoted(alice, 1));
        assertFalse(hook.hasVoted(alice, 1_000));
        assertFalse(hook.hasVoted(bob, 0));
    }

    function test_votePassedIsFalseForEmptyAndFutureDays() public {
        assertFalse(hook.votePassed(0));
        assertFalse(hook.votePassed(1));
        assertFalse(hook.votePassed(type(uint256).max));
        assertEq(hook.sellAllowance(type(uint256).max), 0, "untouched days have no buys");
    }

    // ---------------------------------------------------------------------------------------------
    // Quorum and majority at their edges
    // ---------------------------------------------------------------------------------------------

    function test_turnoutExactlyAtQuorumPasses() public {
        buyExactIn(10 ether);
        uint256 q = quorumNow();
        // Moving tokens from this test to alice to the hook keeps them all outside the manager, so the
        // quorum alice's first vote snapshots is still `q`.
        giveStake(alice, q);
        vm.prank(alice);
        hook.vote(true);
        (uint256 yes,, uint256 quorum,,,) = hook.records(0);
        assertEq(quorum, q);
        assertEq(yes, q);
        assertTrue(hook.votePassed(0));
    }

    function test_turnoutOneWeiBelowQuorumFails() public {
        buyExactIn(10 ether);
        uint256 q = quorumNow();
        giveStake(alice, q - 1);
        vm.prank(alice);
        hook.vote(true);
        (,, uint256 quorum,,,) = hook.records(0);
        assertEq(quorum, q);
        assertFalse(hook.votePassed(0));
        warpToDay(1, 0);
        assertFalse(hook.sellWindowOpen());
    }

    function test_oneWeiMajorityWithQuorumPasses() public {
        buyExactIn(10 ether);
        uint256 q = quorumNow();
        giveStake(alice, q / 2 + 1);
        giveStake(bob, q / 2);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);
        assertTrue(hook.votePassed(0));
    }

    function test_hugeTurnoutWithoutMajorityFails() public {
        buyExactIn(10 ether);
        uint256 q = quorumNow();
        giveStake(alice, q * 10);
        giveStake(bob, q * 10 + 1);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);
        assertFalse(hook.votePassed(0));
    }

    function test_noVotesCannotPassEvenWithStake() public {
        giveStake(alice, quorumNow() + 1);
        giveStake(bob, quorumNow() + 1);
        vm.prank(alice);
        hook.vote(false);
        vm.prank(bob);
        hook.vote(false);
        assertFalse(hook.votePassed(0));
    }

    /// @dev Tokens parked in the manager as ERC-6909 claims leave the circulating supply, so they lower
    /// the quorum the next first vote snapshots. Each parked token lowers the quorum by one twentieth of
    /// itself, whereas each staked token adds a whole token of weight, so parking never beats staking;
    /// this pins the arithmetic the README states rather than a loophole.
    function testFuzz_quorumIsFivePercentOfSupplyOutsideTheManager(uint256 parked, uint256 stake) public {
        parked = bound(parked, 0, 100_000_000 ether);
        stake = bound(stake, 1, 100_000_000 ether);
        if (parked > 0) claimsRouter.deposit(key.currency1, address(this), parked);
        giveStake(alice, stake);

        uint256 expectedCirculating = token.totalSupply() - token.balanceOf(address(manager));
        vm.prank(alice);
        hook.vote(true);

        (uint256 yes,, uint256 quorum,,,) = hook.records(0);
        assertEq(quorum, expectedCirculating * 500 / 10_000);
        assertEq(hook.votePassed(0), yes >= quorum, "a lone yes passes exactly when it reaches the quorum");
    }

    function testFuzz_voteWeightAndLockFollowTheDeposit(uint256 stake, uint256 secondsIntoDay) public {
        stake = bound(stake, 1, 10_000_000 ether);
        secondsIntoDay = bound(secondsIntoDay, 0, 1 days - 1);
        giveStake(alice, stake);
        vm.warp(START + 3 days + secondsIntoDay);
        vm.prank(alice);
        hook.vote(true);
        (uint256 yes,,,,,) = hook.records(3);
        assertEq(yes, stake);
        assertEq(hook.lockedUntil(alice), START + 4 days);
        vm.warp(START + 4 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BuyGateHook.StakeLocked.selector, START + 4 days));
        hook.withdraw(stake);
        vm.warp(START + 4 days);
        vm.prank(alice);
        hook.withdraw(stake);
        assertEq(token.balanceOf(alice), stake);
    }

    // ---------------------------------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------------------------------

    function testFuzz_dayIndexAndDayStartAreConsistent(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 100 * 365 days);
        vm.warp(START + elapsed);
        uint256 day = hook.currentDay();
        assertLe(hook.dayStart(day), block.timestamp);
        assertGt(hook.dayStart(day + 1), block.timestamp);
        assertEq(hook.dayStart(day + 1) - hook.dayStart(day), 1 days);
    }

    function test_buysFarInTheFutureAreStillRecorded() public {
        vm.warp(START + 50 * 365 days);
        uint256 day = hook.currentDay();
        uint256 out = buyExactIn(1 ether);
        assertEq(bought(day), out);
        assertFalse(hook.sellWindowOpen());
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: partial fills, claims, exact-output refusal, the smallest amounts
    // ---------------------------------------------------------------------------------------------

    function test_partialFillChargesOnlyTheTokensActuallySold() public {
        uint256 day0 = openDayOneWindow(10 ether);
        uint256 allowance = day0 / 2;

        // A price limit one tick above the current price stops the swap early: the pool takes fewer
        // tokens than specified, and the hook charges the actual input, not the request.
        (uint160 sqrtPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint160 limit = TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(sqrtPrice) + 1);
        uint256 balanceBefore = token.balanceOf(address(this));
        sellExactInWithLimit(allowance, limit);
        uint256 actuallySold = balanceBefore - token.balanceOf(address(this));

        assertLt(actuallySold, allowance, "the limit cut the fill short");
        assertGt(actuallySold, 0);
        assertEq(sold(1), actuallySold);
        assertEq(hook.sellRemaining(), allowance - actuallySold);

        // The unspent part of the allowance is still usable.
        sellExactIn(allowance - actuallySold);
        assertEq(hook.sellRemaining(), 0);
    }

    function test_requestedAmountIsCheckedUpFrontEvenIfTheFillWouldBeSmaller() public {
        uint256 day0 = openDayOneWindow(10 ether);
        (uint160 sqrtPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint160 limit = TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(sqrtPrice) + 1);
        // Specified over the allowance: refused before the pool runs, although the limit would have
        // kept the fill under it. Conservative by design and worth pinning.
        expectHookRevert(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, day0 / 2 + 1, day0 / 2)
        );
        sellExactInWithLimit(day0 / 2 + 1, limit);
    }

    function test_oneWeiSellIsAcceptedAndCounted() public {
        openDayOneWindow(10 ether);
        uint256 remainingBefore = hook.sellRemaining();
        sellExactIn(1);
        assertEq(sold(1), 1);
        assertEq(hook.sellRemaining(), remainingBefore - 1);
    }

    function test_exactOutputSellOverTheAllowanceFailsInAfterSwapWithTheRealAmounts() public {
        uint256 day0 = openDayOneWindow(10 ether);
        uint256 allowance = day0 / 2;

        (bool ok, bytes memory ret) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(false, int256(day0), TickMath.MAX_SQRT_PRICE - 1),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );
        assertFalse(ok, "asking for more ETH than half of yesterday's buys can pay must fail");

        // Unwrap WrappedError(target, selector, reason, details) without knowing the token amount.
        assertEq(bytes4(ret), CustomRevert.WrappedError.selector);
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = ret[i + 4];
        }
        (address target, bytes4 callback, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector, "exact-output sells are checked after the swap");
        assertEq(bytes4(reason), BuyGateHook.SellAllowanceExceeded.selector);
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = reason[i + 4];
        }
        (uint256 requested, uint256 remaining) = abi.decode(args, (uint256, uint256));
        assertGt(requested, remaining);
        assertEq(remaining, allowance);
        assertEq(sold(1), 0, "nothing was charged");
    }

    function test_exactOutputSellsAccumulateAgainstTheAllowance() public {
        uint256 day0 = openDayOneWindow(10 ether);
        uint256 first = sellExactOut(0.2 ether);
        uint256 second = sellExactOut(0.3 ether);
        assertEq(sold(1), first + second);
        assertEq(hook.sellRemaining(), day0 / 2 - first - second);
    }

    function test_buyTakenAsClaimsIsStillRecordedAndKeepsTokensInsideTheManager() public {
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams(true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        uint256 out = uint256(int256(delta.amount1()));
        assertGt(out, 0);
        assertEq(bought(0), out, "a claims buy counts towards tomorrow's allowance");
        assertEq(token.balanceOf(address(manager)), managerBefore, "the tokens never left the manager");
        assertEq(manager.balanceOf(address(this), key.currency1.toId()), out);
        assertEq(hook.circulatingSupply(), token.totalSupply() - managerBefore, "claims do not circulate");
    }

    function test_sellSettledByBurningClaimsIsGatedLikeAnyOther() public {
        uint256 day0 = openDayOneWindow(10 ether);
        claimsRouter.deposit(key.currency1, address(this), day0);
        manager.setOperator(address(swapRouter), true);

        // Closed path: still refused when burning claims instead of transferring tokens.
        warpToDay(1, 1 hours);
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        swapRouter.swap(
            key,
            SwapParams(false, -int256(day0 / 4), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, true),
            ""
        );

        // Open path: the burnt claims count as tokens sold.
        warpToDay(1, 10 minutes);
        swapRouter.swap(
            key,
            SwapParams(false, -int256(day0 / 4), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, true),
            ""
        );
        assertEq(sold(1), day0 / 4);
    }

    function test_depositsAndWithdrawalsAreNotBuysOrSells() public {
        giveStake(alice, 100 ether);
        vm.prank(alice);
        hook.withdraw(50 ether);
        assertEq(bought(0), 0);
        assertEq(sold(0), 0);
    }

    function test_hookNeverHoldsEthOrTokensBeyondStake() public {
        uint256 day0 = openDayOneWindow(10 ether);
        sellExactIn(day0 / 2);
        buyExactIn(3 ether);
        assertEq(address(hook).balance, 0, "no hook fee in ETH");
        assertEq(token.balanceOf(address(hook)), hook.stakeOf(alice), "no hook fee in tokens");
    }

    // ---------------------------------------------------------------------------------------------
    // Days in sequence
    // ---------------------------------------------------------------------------------------------

    function test_windowsFollowEachDaysVoteIndependently() public {
        // Day 0: buys, vote passes -> day 1 opens.
        uint256 day0 = buyExactIn(10 ether);
        uint256 big = quorumNow() + 1_000 ether;
        giveStake(alice, big);
        giveStake(bob, big + 1);
        vm.prank(alice);
        hook.vote(true);

        // Day 1: window open with day-0 allowance; bob outvotes alice -> day 2 closed.
        warpToDay(1, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), day0 / 2);
        uint256 day1 = buyExactIn(4 ether);
        vm.prank(alice);
        hook.vote(true);
        vm.prank(bob);
        hook.vote(false);

        // Day 2: closed although day 1 had buys; alice alone votes yes -> day 3 opens.
        warpToDay(2, 0);
        assertFalse(hook.sellWindowOpen());
        assertEq(hook.sellAllowance(2), day1 / 2, "the allowance exists on paper");
        assertEq(hook.sellRemaining(), 0, "but nothing can be sold");
        expectHookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellsClosed.selector));
        sellExactIn(1);
        uint256 day2 = buyExactIn(2 ether);
        vm.prank(alice);
        hook.vote(true);

        // Day 3: open, and only day 2's buys back it. Day 0 and day 1 volumes are gone.
        warpToDay(3, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), day2 / 2);
        assertLt(day2 / 2, day0 / 2);
        sellExactIn(day2 / 2);
        expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, 1, 0)
        );
        sellExactIn(1);
    }

    function test_buysDuringTheWindowHourCountForTheNextDay() public {
        openDayOneWindow(10 ether);
        uint256 inWindow = buyExactIn(6 ether);
        warpToDay(1, 2 hours);
        uint256 afterWindow = buyExactIn(2 ether);
        assertEq(bought(1), inWindow + afterWindow);
        vm.prank(alice);
        hook.vote(true);
        warpToDay(2, 0);
        assertEq(hook.sellRemaining(), (inWindow + afterWindow) / 2);
    }

    function test_voteCastDuringTheWindowCounts() public {
        openDayOneWindow(10 ether);
        warpToDay(1, 30 minutes);
        vm.prank(alice);
        hook.vote(true);
        assertTrue(hook.votePassed(1));
    }

    function test_unspentAllowanceDoesNotRollOver() public {
        uint256 day0 = openDayOneWindow(10 ether);
        // Nothing sold on day 1. Day 1 has no buys; vote passes again.
        vm.prank(alice);
        hook.vote(true);
        warpToDay(2, 0);
        assertTrue(hook.sellWindowOpen());
        assertEq(hook.sellRemaining(), 0, "day 0's unsold half does not carry into day 2");
        expectHookRevert(
            IHooks.beforeSwap.selector, abi.encodeWithSelector(BuyGateHook.SellAllowanceExceeded.selector, day0 / 2, 0)
        );
        sellExactIn(day0 / 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks driven directly, as the manager, with inputs the pool would never produce
    // ---------------------------------------------------------------------------------------------

    function test_afterSwapAsManagerStillRefusesAClosedSell() public {
        vm.prank(address(manager));
        vm.expectRevert(BuyGateHook.SellsClosed.selector);
        hook.afterSwap(
            address(this),
            key,
            SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1),
            toBalanceDelta(int128(1 ether), -int128(1 ether)),
            ""
        );
    }

    function test_afterSwapAsManagerIgnoresABuyWithNoTokenOutput() public {
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            toBalanceDelta(-int128(1 ether), 0),
            ""
        );
        assertEq(bought(0), 0);
    }

    function test_swapCallbacksOnAnUnboundHookRevertNotBound() public {
        BuyGateHook fresh = deployer.deployHook(IPoolManager(address(manager)), address(deployer));
        vm.startPrank(address(manager));
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.beforeSwap(address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.afterSwap(
            address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), ""
        );
        vm.stopPrank();
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.circulatingSupply();
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.dayStart(0);
    }

    function test_liquidityCallbacksRevertForEveryone() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        for (uint256 i = 0; i < 2; i++) {
            address caller = i == 0 ? address(manager) : address(this);
            vm.startPrank(caller);
            vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
            hook.afterAddLiquidity(address(this), key, p, zero, zero, "");
            vm.expectRevert(BuyGateHook.HookNotImplemented.selector);
            hook.afterRemoveLiquidity(address(this), key, p, zero, zero, "");
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance arithmetic at the top of the range
    // ---------------------------------------------------------------------------------------------

    /// @dev Writes `records[day].bought` directly. The slot is located through the `records(uint256)`
    /// getter (`bought` is its fifth return value, depth 4) rather than hard-coded, so a change in the
    /// hook's storage layout, like the `initializer` and `seeded` variables the revision added ahead of
    /// `records`, cannot silently point this at the wrong slot.
    function setBought(uint256 day, uint256 volume) internal {
        uint256 slot = stdstore.target(address(hook)).sig(hook.records.selector).with_key(day).depth(4).find();
        vm.store(address(hook), bytes32(slot), bytes32(volume));
    }

    function testFuzz_allowanceIsHalfRoundedDownForAnyVolume(uint256 volume, uint256 day) public {
        volume = bound(volume, 0, type(uint256).max / 10_000);
        day = bound(day, 0, type(uint256).max - 1);
        setBought(day, volume);
        assertEq(bought(day), volume, "the slot is where this test believes it is");

        uint256 allowance = hook.sellAllowance(day + 1);
        assertLe(allowance * 2, volume);
        assertLe(volume - allowance * 2, 1);
    }

    function test_allowanceOverflowsForVolumesAboveTheSupplyScale() public {
        // Unreachable with a 10^27 supply, but the formula multiplies before dividing: pinned so a
        // future change of SELL_SHARE_BPS or supply cannot drift past it unnoticed.
        setBought(0, type(uint256).max / 5_000 + 1);
        vm.expectRevert();
        hook.sellAllowance(1);
    }

    // ---------------------------------------------------------------------------------------------
    // The liquidity gate, from the side the launch does not control
    // ---------------------------------------------------------------------------------------------

    function expectLiquidityRefused(address sender) internal {
        expectHookRevert(
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, sender)
        );
    }

    function test_hookDataCannotImpersonateTheLaunch() public {
        // The gate reads neither hookData nor, since the revision, `sender`: whatever a stranger puts in
        // hookData is noise, and naming the recorded initializer there earns nothing.
        token.transfer(alice, 1_000 ether);
        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        bytes[3] memory forged = [
            abi.encode(hook.initializer()), abi.encodePacked(hook.initializer()), abi.encode(true, hook.initializer())
        ];
        for (uint256 i = 0; i < forged.length; i++) {
            expectLiquidityRefused(address(lpRouter));
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), forged[i]);
        }
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function test_zeroLiquidityAddFromAStrangerIsRefusedToo() public {
        // The smallest possible add. Refusing it matters: an accepted empty position would still run
        // `beforeAddLiquidity`, and a later version that keyed anything on "has a position" would be fooled.
        vm.prank(alice);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 1, bytes32(0)), "");
    }

    function test_seededStaysTrueAfterTheLaunchRemovesEverything() public {
        // The launch unwinds its whole position. The pool is empty, but it has held a position, so the
        // "first position" exception does not reopen: a stranger still cannot become the pool's liquidity.
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, -10_000 ether, bytes32(0)), "");
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0, "the pool is empty");
        assertTrue(hook.seeded(), "seeded is a latch");

        token.transfer(alice, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1 ether, bytes32(0)), ""
        );
        expectLiquidityRefused(address(lpRouter));
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), "");
        vm.stopPrank();
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0);
    }

    function test_beforeAddLiquidityOnAnUnboundHookRevertsNotBound() public {
        BuyGateHook fresh = deployer.deployHook(IPoolManager(address(manager)), address(deployer));
        vm.prank(address(manager));
        vm.expectRevert(BuyGateHook.NotBound.selector);
        fresh.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0)), "");
        assertFalse(fresh.seeded(), "a refused call does not latch seeded");
    }

    function test_strangerCannotSeedBeforeTheLaunchByFrontRunningTheInitializedPool() public {
        // A hook bound by `initialize` alone, no seed yet: the first position is accepted from anyone (the
        // README states this), and from then on nobody. Pinned so the gap stays exactly one position wide
        // and does not widen to "anyone, until the launch shows up". The consequence for the launch, that
        // its own seed is refused after such a front-run, is reported in `.imd-findings.json`, not asserted.
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

        token.transfer(alice, 2_000 ether);
        vm.startPrank(alice);
        token.approve(address(freshLp), type(uint256).max);
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(-60, 0, 1, bytes32(0)), "");
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
        freshLp.modifyLiquidity(k, ModifyLiquidityParams(-60, 0, 333_000 ether, bytes32(0)), "");
        vm.stopPrank();
    }

    /// @dev The revision dropped the `sender == initializer` clause. A position is keyed on (router, ticks,
    /// salt), so when the launch initializes and seeds through a router other people can drive, a stranger
    /// calling the same router with the same ticks and salt would be topping up the launch's own position,
    /// and the manager would report it as `sender == initializer`. Both that stranger and the launch itself
    /// must be refused after the seed: the hook cannot tell them apart, so it admits neither.
    function test_launchPositionCannotBeToppedUpThroughTheRouterThatInitializedThePool() public {
        PoolManager freshManager = new PoolManager(address(this));
        BuyGateHook freshHook = deployer.deployHook(IPoolManager(address(freshManager)), address(deployer));
        InitializingRouter shared = new InitializingRouter(IPoolManager(address(freshManager)));
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(freshHook))
        });
        PoolId freshId = k.toId();

        // The launch (this contract) initializes and seeds through the shared router, in two transactions.
        shared.initializePool(k, SQRT_PRICE_1_1);
        token.approve(address(shared), type(uint256).max);
        shared.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 10_000 ether, bytes32(0)), "");
        assertEq(freshHook.initializer(), address(shared));
        (uint128 seedLiquidity,,) =
            IPoolManager(address(freshManager)).getPositionInfo(freshId, address(shared), MIN_TICK, -60, bytes32(0));
        assertEq(seedLiquidity, 10_000 ether);

        bytes memory refused = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(freshHook),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(BuyGateHook.LiquidityNotFromLaunch.selector, address(shared)),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );

        // A stranger tops up the launch's exact position key through the router that initialized the pool.
        token.transfer(alice, 1_000 ether);
        vm.startPrank(alice);
        token.approve(address(shared), type(uint256).max);
        vm.expectRevert(refused);
        shared.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1, bytes32(0)), "");
        // ...and a fresh position of their own with a different salt, same router.
        vm.expectRevert(refused);
        shared.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1, bytes32(uint256(1))), "");
        vm.stopPrank();

        // The launch itself, same router, same position key: refused all the same.
        vm.expectRevert(refused);
        shared.modifyLiquidity(k, ModifyLiquidityParams(MIN_TICK, -60, 1 ether, bytes32(0)), "");

        (uint128 after_,,) =
            IPoolManager(address(freshManager)).getPositionInfo(freshId, address(shared), MIN_TICK, -60, bytes32(0));
        assertEq(after_, seedLiquidity, "the seed position did not change");
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // The unlock guard: only `vote` is refused inside an unlock, and it is refused even when nothing
    // was taken from the manager
    // ---------------------------------------------------------------------------------------------

    function test_voteInsideAnUnlockIsRefusedEvenWithoutAFlashTake() public {
        UnlockActor actor = new UnlockActor(manager, token, hook);
        token.transfer(address(actor), 10 ether);
        actor.depositLocked(10 ether);

        vm.expectRevert(BuyGateHook.ManagerUnlocked.selector);
        actor.act(UnlockActor.Action.Vote, 0);
        (,,, bool hasVotes,,) = hook.records(0);
        assertFalse(hasVotes);
        assertFalse(hook.hasVoted(address(actor), 0));
        assertEq(hook.lockedUntil(address(actor)), 0, "a refused vote locks nothing");
    }

    function test_depositAndWithdrawInsideAnUnlockAreAllowedAndChangeNoTally() public {
        UnlockActor actor = new UnlockActor(manager, token, hook);
        token.transfer(address(actor), 10 ether);

        actor.act(UnlockActor.Action.Deposit, 10 ether);
        assertEq(hook.stakeOf(address(actor)), 10 ether);
        actor.act(UnlockActor.Action.Withdraw, 4 ether);
        assertEq(hook.stakeOf(address(actor)), 6 ether);
        assertEq(token.balanceOf(address(actor)), 4 ether);
        assertEq(token.balanceOf(address(hook)), 6 ether);

        (,,, bool hasVotes, uint256 boughtToday, uint256 soldToday) = hook.records(0);
        assertFalse(hasVotes);
        assertEq(boughtToday, 0);
        assertEq(soldToday, 0);

        // Outside the unlock the same contract votes with what it kept.
        vm.prank(address(actor));
        hook.vote(true);
        (uint256 yes,,,,,) = hook.records(0);
        assertEq(yes, 6 ether);
    }
}
