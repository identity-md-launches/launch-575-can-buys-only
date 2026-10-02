// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

import {SurfToken} from "../src/SurfToken.sol";
import {BuyGateHook} from "../src/BuyGateHook.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @notice A liquidity router anyone can call that also initializes pools, like PositionManager's
/// `initializePool`. The launch goes through it in `setUp`, so the hook records it as `initializer` and
/// it holds the seed position; the actors then drive the very same router.
contract LaunchRouter is PoolModifyLiquidityTest {
    constructor(IPoolManager m) PoolModifyLiquidityTest(m) {}

    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }
}

/// @notice Drives the hook, the pool and three actors through random sequences of buys, sells (both
/// exact-input and exact-output), deposits, withdrawals, votes, ERC-6909 parking, stranger liquidity
/// attempts through a third-party router and through the router that initialized and seeded the pool,
/// flash votes from inside an unlock, and time travel.
/// Every call that the rules say must fail is attempted anyway and its revert is checked; every call
/// that must succeed is asserted to. Ghost variables record what the hook should hold and what each
/// day's tallies and volumes should be, from bookkeeping independent of the hook's own storage.
/// The handler itself holds a one-wei stake, deposited in its constructor, which it only ever tries to
/// vote with from inside an unlock; that vote must always be refused.
contract BuyGateHandler is Test, IUnlockCallback {
    PoolManager public manager;
    SurfToken public token;
    BuyGateHook public hook;
    PoolKey public key;
    PoolSwapTest public swapRouter;
    PoolClaimsTest public claimsRouter;
    PoolModifyLiquidityTest public lpRouter;
    LaunchRouter public launchRouter;

    address[3] public actors;

    /// @notice The launch's seed position, keyed under `launchRouter`: the one position a stranger could
    /// top up by calling that router with the same ticks and salt.
    int24 public constant SEED_LOWER = -887_220;
    int24 public constant SEED_UPPER = 887_220;

    /// @notice The handler's own stake, used only for flash-vote attempts.
    uint256 public constant HANDLER_STAKE = 1;

    // ---- ghosts: stake custody ----
    mapping(address => uint256) public ghostDeposited;
    mapping(address => uint256) public ghostWithdrawn;
    uint256 public ghostSumStake;
    mapping(address => uint256) public ghostLockedUntil;

    // ---- ghosts: per-day tallies and volumes ----
    mapping(uint256 => uint256) public ghostYes;
    mapping(uint256 => uint256) public ghostNo;
    mapping(uint256 => uint256) public ghostQuorum;
    mapping(uint256 => bool) public ghostHasVotes;
    mapping(uint256 => uint256) public ghostBought;
    mapping(uint256 => uint256) public ghostSold;
    mapping(address => mapping(uint256 => bool)) public ghostVoted;
    uint256[] public touchedDays;
    mapping(uint256 => bool) internal _touched;

    // ---- ghosts: what moved through the manager ----
    uint256 public managerEthAtStart;
    uint256 public managerTokenAtStart;
    uint256 public ghostEthIn;
    uint256 public ghostEthOut;
    uint256 public ghostTokensOut;
    uint256 public ghostTokensIn;
    uint256 public ghostParked;

    // ---- coverage counters (read by the smoke test, never asserted in invariants) ----
    uint256 public countBuys;
    uint256 public countSellsOk;
    uint256 public countSellsClosed;
    uint256 public countSellsOverCap;
    uint256 public countVotesOk;
    uint256 public countWithdrawLocked;
    uint256 public countOpenAtSell;
    uint256 public countLiquidityRefused;
    uint256 public countLaunchRouterRefused;
    uint256 public countFlashVotesRefused;

    constructor(
        PoolManager _manager,
        SurfToken _token,
        BuyGateHook _hook,
        PoolKey memory _key,
        PoolSwapTest _swapRouter,
        PoolClaimsTest _claimsRouter,
        PoolModifyLiquidityTest _lpRouter,
        LaunchRouter _launchRouter,
        address[3] memory _actors
    ) {
        manager = _manager;
        token = _token;
        hook = _hook;
        key = _key;
        swapRouter = _swapRouter;
        claimsRouter = _claimsRouter;
        lpRouter = _lpRouter;
        launchRouter = _launchRouter;
        actors = _actors;
        managerEthAtStart = address(manager).balance;
        managerTokenAtStart = token.balanceOf(address(manager));
    }

    /// @notice Deposits the handler's own one-wei stake. Called once from `setUp`, after the handler was
    /// sent HANDLER_STAKE tokens and before it becomes a fuzz target (it is not in the selector list).
    function stakeSelf() external {
        require(ghostDeposited[address(this)] == 0, "already staked");
        token.approve(address(hook), HANDLER_STAKE);
        hook.deposit(HANDLER_STAKE);
        ghostDeposited[address(this)] = HANDLER_STAKE;
        ghostSumStake += HANDLER_STAKE;
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------------------------
    // Ghost-side spec: what the window should be, from the handler's own tallies
    // ---------------------------------------------------------------------------------------------

    function ghostPassed(uint256 day) public view returns (bool) {
        return ghostHasVotes[day] && ghostYes[day] > ghostNo[day] && ghostYes[day] + ghostNo[day] >= ghostQuorum[day];
    }

    function ghostWindowOpen() public view returns (bool) {
        uint256 day = hook.currentDay();
        if (day == 0) return false;
        if (block.timestamp >= hook.dayStart(day) + 1 hours) return false;
        return ghostPassed(day - 1);
    }

    function touchedDaysLength() external view returns (uint256) {
        return touchedDays.length;
    }

    function _touch(uint256 day) internal {
        if (!_touched[day]) {
            _touched[day] = true;
            touchedDays.push(day);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Unwraps `WrappedError(hook, callback, reason, HookCallFailed)` into the hook's reason selector.
    function _hookReason(bytes memory ret) internal view returns (bytes4 callback, bytes4 reason) {
        if (ret.length < 4 || bytes4(ret) != CustomRevert.WrappedError.selector) return (0, 0);
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = ret[i + 4];
        }
        (address target, bytes4 cb, bytes memory r,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook), "a swap revert came from somewhere other than the hook");
        return (cb, bytes4(r));
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    /// @notice A buy always passes and is recorded against today.
    function buy(uint256 actorSeed, uint256 ethIn) public {
        address actor = _actor(actorSeed);
        ethIn = bound(ethIn, 1, 20 ether);
        vm.deal(actor, actor.balance + ethIn);
        uint256 day = hook.currentDay();

        vm.prank(actor);
        BalanceDelta delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 paid = uint256(-int256(delta.amount0()));
        uint256 out = uint256(int256(delta.amount1()));

        ghostEthIn += paid;
        ghostTokensOut += out;
        ghostBought[day] += out;
        _touch(day);
        countBuys++;
    }

    /// @notice An exact-input sell: refused when closed or over the allowance, otherwise charged exactly.
    function sellExactIn(uint256 actorSeed, uint256 amountSeed) public {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;

        uint256 day = hook.currentDay();
        bool open = hook.sellWindowOpen();
        assertEq(open, ghostWindowOpen(), "the hook's window disagrees with the ghost tallies");
        uint256 remaining = hook.sellRemaining();
        uint256 ethBefore = actor.balance;
        if (open) countOpenAtSell++;
        // Half of the attempts stay inside the remaining allowance so the success path is exercised;
        // the other half range over the whole balance and mostly overshoot it.
        uint256 amount = (amountSeed % 2 == 0 && remaining > 0)
            ? bound(amountSeed, 1, remaining < balance ? remaining : balance)
            : bound(amountSeed, 1, balance);

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );

        if (!open) {
            assertFalse(ok, "a sell went through while the window was closed");
            (bytes4 cb, bytes4 reason) = _hookReason(ret);
            assertEq(cb, IHooks.beforeSwap.selector);
            assertEq(reason, BuyGateHook.SellsClosed.selector);
            countSellsClosed++;
            return;
        }
        if (amount > remaining) {
            assertFalse(ok, "a sell above the remaining allowance went through");
            (bytes4 cb, bytes4 reason) = _hookReason(ret);
            assertEq(cb, IHooks.beforeSwap.selector);
            assertEq(reason, BuyGateHook.SellAllowanceExceeded.selector);
            countSellsOverCap++;
            return;
        }
        assertTrue(ok, "a sell within an open window and its allowance was refused");
        uint256 tokensIn = balance - token.balanceOf(actor);
        assertLe(tokensIn, amount, "the pool took more than the exact input");
        ghostTokensIn += tokensIn;
        ghostEthOut += actor.balance - ethBefore;
        ghostSold[day] += tokensIn;
        _touch(day);
        countSellsOk++;
    }

    /// @notice An exact-output sell: refused when closed; when open, either charged exactly or refused
    /// in afterSwap once the token input turns out larger than the allowance.
    function sellExactOut(uint256 actorSeed, uint256 ethSeed) public {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 ethWanted = bound(ethSeed, 1, 1 ether);

        uint256 day = hook.currentDay();
        bool open = hook.sellWindowOpen();
        assertEq(open, ghostWindowOpen(), "the hook's window disagrees with the ghost tallies");
        uint256 remaining = hook.sellRemaining();
        uint256 ethBefore = actor.balance;
        if (open) countOpenAtSell++;

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(swapRouter)
            .call(
                abi.encodeCall(
                    swapRouter.swap,
                    (
                        key,
                        SwapParams(false, int256(ethWanted), TickMath.MAX_SQRT_PRICE - 1),
                        PoolSwapTest.TestSettings(false, false),
                        ""
                    )
                )
            );

        if (!open) {
            assertFalse(ok, "an exact-output sell went through while the window was closed");
            (bytes4 cb, bytes4 reason) = _hookReason(ret);
            assertEq(cb, IHooks.beforeSwap.selector);
            assertEq(reason, BuyGateHook.SellsClosed.selector);
            countSellsClosed++;
            return;
        }
        if (!ok) {
            // Either the hook refused the realised input in afterSwap, or the actor could not pay it.
            if (bytes4(ret) == IERC20Errors.ERC20InsufficientBalance.selector) return;
            (bytes4 cb, bytes4 reason) = _hookReason(ret);
            assertEq(cb, IHooks.afterSwap.selector, "an open exact-output sell may only fail in afterSwap");
            assertEq(reason, BuyGateHook.SellAllowanceExceeded.selector);
            countSellsOverCap++;
            return;
        }
        uint256 tokensIn = balance - token.balanceOf(actor);
        assertLe(tokensIn, remaining, "an exact-output sell took more than the remaining allowance");
        assertEq(actor.balance - ethBefore, ethWanted, "exact output was not delivered exactly");
        ghostTokensIn += tokensIn;
        ghostEthOut += ethWanted;
        ghostSold[day] += tokensIn;
        _touch(day);
        countSellsOk++;
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 amountSeed) public {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        // Half of the deposits are large (a quarter of the balance or more) so stakes can reach the
        // quorum; the other half range over everything down to one wei.
        uint256 amount =
            amountSeed % 2 == 0 ? bound(amountSeed, balance / 4 + 1, balance) : bound(amountSeed, 1, balance);
        _deposit(actor, amount);
    }

    function _deposit(address actor, uint256 amount) internal {
        vm.prank(actor);
        hook.deposit(amount);
        ghostDeposited[actor] += amount;
        ghostSumStake += amount;
    }

    /// @notice Stakes whatever is missing to reach the quorum alone (if the actor can afford it), then votes.
    function voteBig(uint256 actorSeed, bool support) public {
        address actor = _actor(actorSeed);
        uint256 quorum = (token.totalSupply() - token.balanceOf(address(manager))) * 500 / 10_000;
        uint256 stake = hook.stakeOf(actor);
        if (stake <= quorum) {
            uint256 needed = quorum - stake + 1;
            if (token.balanceOf(actor) < needed) return;
            _deposit(actor, needed);
        }
        vote(actorSeed, support);
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) public {
        address actor = _actor(actorSeed);
        uint256 stake = hook.stakeOf(actor);
        uint256 amount = bound(amountSeed, 1, stake + 1);
        uint256 until = ghostLockedUntil[actor];

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(hook.withdraw, (amount)));

        if (block.timestamp < until) {
            assertFalse(ok, "a locked voter withdrew");
            assertEq(bytes4(ret), BuyGateHook.StakeLocked.selector);
            countWithdrawLocked++;
            return;
        }
        if (amount > stake) {
            assertFalse(ok, "a withdrawal above the stake went through");
            assertEq(bytes4(ret), BuyGateHook.InsufficientStake.selector);
            return;
        }
        assertTrue(ok, "an unlocked withdrawal within the stake was refused");
        ghostWithdrawn[actor] += amount;
        ghostSumStake -= amount;
    }

    function vote(uint256 actorSeed, bool support) public {
        address actor = _actor(actorSeed);
        uint256 day = hook.currentDay();
        uint256 stake = hook.stakeOf(actor);
        uint256 circulatingBefore = token.totalSupply() - token.balanceOf(address(manager));

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(hook.vote, (support)));

        if (stake == 0) {
            assertFalse(ok, "a voter with no stake voted");
            assertEq(bytes4(ret), BuyGateHook.NoStake.selector);
            return;
        }
        if (ghostVoted[actor][day]) {
            assertFalse(ok, "a voter voted twice on one day");
            assertEq(bytes4(ret), BuyGateHook.AlreadyVoted.selector);
            return;
        }
        assertTrue(ok, "a staked first vote of the day was refused");
        if (!ghostHasVotes[day]) {
            ghostHasVotes[day] = true;
            ghostQuorum[day] = circulatingBefore * 500 / 10_000;
        }
        if (support) ghostYes[day] += stake;
        else ghostNo[day] += stake;
        ghostVoted[actor][day] = true;
        ghostLockedUntil[actor] = hook.dayStart(day + 1);
        _touch(day);
        countVotesOk++;
    }

    // ---------------------------------------------------------------------------------------------
    // Tokens parked in the manager as ERC-6909 claims: they leave circulation without a swap
    // ---------------------------------------------------------------------------------------------

    function park(uint256 actorSeed, uint256 amountSeed) public {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(actor);
        claimsRouter.deposit(key.currency1, actor, amount);
        ghostParked += amount;
    }

    function unpark(uint256 actorSeed, uint256 amountSeed) public {
        address actor = _actor(actorSeed);
        uint256 claims = manager.balanceOf(actor, key.currency1.toId());
        if (claims == 0) return;
        uint256 amount = bound(amountSeed, 1, claims);
        vm.prank(actor);
        claimsRouter.withdraw(key.currency1, actor, amount);
        ghostParked -= amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Strangers at the liquidity gate: every add from an actor is refused, whatever the range or size
    // ---------------------------------------------------------------------------------------------

    function addLiquidityAsStranger(uint256 actorSeed, int24 lowerSeed, int24 upperSeed, uint128 liquiditySeed) public {
        address actor = _actor(actorSeed);
        int24 lower = int24(bound(int256(lowerSeed), -887_220 / 60, 887_220 / 60 - 1)) * 60;
        int24 upper = int24(bound(int256(upperSeed), int256(lower) / 60 + 1, 887_220 / 60)) * 60;
        uint256 liquidity = bound(uint256(liquiditySeed), 1, 1_000_000 ether);
        uint256 tokensBefore = token.balanceOf(actor);
        uint256 ethBefore = actor.balance;

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(lpRouter)
            .call(
                abi.encodeWithSignature(
                    "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)",
                    key,
                    ModifyLiquidityParams(lower, upper, int256(liquidity), bytes32(0)),
                    ""
                )
            );
        assertFalse(ok, "a stranger added liquidity to the launch pool");
        (bytes4 cb, bytes4 reason) = _hookReason(ret);
        assertEq(cb, IHooks.beforeAddLiquidity.selector);
        assertEq(reason, BuyGateHook.LiquidityNotFromLaunch.selector);
        assertEq(token.balanceOf(actor), tokensBefore, "a refused add moved tokens");
        assertEq(actor.balance, ethBefore, "a refused add moved ETH");
        countLiquidityRefused++;
    }

    /// @notice The same attempt through the router that initialized and seeded the pool, which the manager
    /// reports as `sender == initializer`. Half of the attempts aim at the launch's own position key (same
    /// ticks, salt zero), which would top it up; the rest open a position of the actor's own under that
    /// router. Every one of them must be refused: the revision removed the initializer's privilege because
    /// a shared router's users cannot be told apart.
    function addLiquidityThroughTheLaunchRouter(
        uint256 actorSeed,
        int24 lowerSeed,
        int24 upperSeed,
        uint128 liquiditySeed,
        bool aimAtSeedPosition
    ) public {
        address actor = _actor(actorSeed);
        int24 lower;
        int24 upper;
        bytes32 salt;
        if (aimAtSeedPosition) {
            (lower, upper, salt) = (SEED_LOWER, SEED_UPPER, bytes32(0));
        } else {
            lower = int24(bound(int256(lowerSeed), -887_220 / 60, 887_220 / 60 - 1)) * 60;
            upper = int24(bound(int256(upperSeed), int256(lower) / 60 + 1, 887_220 / 60)) * 60;
            salt = bytes32(uint256(uint160(actor)));
        }
        uint256 liquidity = bound(uint256(liquiditySeed), 1, 1_000_000 ether);
        uint256 tokensBefore = token.balanceOf(actor);
        uint256 ethBefore = actor.balance;

        vm.prank(actor);
        (bool ok, bytes memory ret) = address(launchRouter)
            .call(
                abi.encodeWithSignature(
                    "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)",
                    key,
                    ModifyLiquidityParams(lower, upper, int256(liquidity), salt),
                    ""
                )
            );
        assertFalse(ok, "a stranger added liquidity through the router that initialized the pool");
        (bytes4 cb, bytes4 reason) = _hookReason(ret);
        assertEq(cb, IHooks.beforeAddLiquidity.selector);
        assertEq(reason, BuyGateHook.LiquidityNotFromLaunch.selector);
        assertEq(token.balanceOf(actor), tokensBefore, "a refused add moved tokens");
        assertEq(actor.balance, ethBefore, "a refused add moved ETH");
        countLaunchRouterRefused++;
    }

    // ---------------------------------------------------------------------------------------------
    // A vote from inside an unlock, after flash-taking every token the manager holds: always refused,
    // and the day's record is untouched by it
    // ---------------------------------------------------------------------------------------------

    function flashVote(bool support) public {
        manager.unlock(abi.encode(support));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        assertEq(msg.sender, address(manager));
        bool support = abi.decode(data, (bool));
        uint256 amount = token.balanceOf(address(manager));
        if (amount > 0) manager.take(key.currency1, address(this), amount);

        (bool ok, bytes memory ret) = address(hook).call(abi.encodeCall(hook.vote, (support)));
        assertFalse(ok, "a vote was accepted while the manager was unlocked");
        assertEq(bytes4(ret), BuyGateHook.ManagerUnlocked.selector);

        if (amount > 0) {
            manager.sync(key.currency1);
            token.transfer(address(manager), amount);
            manager.settle();
        }
        countFlashVotesRefused++;
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------------------------------

    function warp(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 36 hours));
    }

    /// @notice Jumps into the next day's first hour and a little beyond it, where the window lives.
    function warpToNextWindow(uint256 offsetSeed) public {
        uint256 next = hook.dayStart(hook.currentDay() + 1);
        vm.warp(next + bound(offsetSeed, 0, 70 minutes));
    }

    /// @notice The whole preparation a window needs, in one call: buys today, a passing vote today, and a
    /// jump into tomorrow's first hour. Each step is the ordinary handler, so the ghosts stay exact.
    function prepareWindow(uint256 actorSeed, uint256 ethIn, uint256 offsetSeed) public {
        buy(actorSeed, ethIn);
        voteBig(actorSeed, true);
        warpToNextWindow(offsetSeed);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract BuyGateHookInvariantTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant START = 1_800_000_000;
    int24 constant MIN_TICK = -887_220;
    int24 constant MAX_TICK = 887_220;
    uint128 constant SEED_LIQUIDITY = 10_000 ether;

    PoolManager manager;
    SurfToken token;
    BuyGateHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolClaimsTest claimsRouter;
    LaunchRouter launchRouter;
    PoolKey key;
    PoolId poolId;
    BuyGateHandler handler;

    address[3] actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2")];

    receive() external payable {}

    function setUp() public {
        vm.warp(START);
        manager = new PoolManager(address(this));
        Deploy deployer = new Deploy();
        (token, hook) = deployer.deploy(IPoolManager(address(manager)), address(deployer));
        uint256 supply = token.totalSupply();
        vm.prank(address(deployer));
        token.transfer(address(this), supply);

        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        claimsRouter = new PoolClaimsTest(IPoolManager(address(manager)));
        launchRouter = new LaunchRouter(IPoolManager(address(manager)));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // The launch initializes and seeds through a shared router, the way a position manager is used,
        // so `initializer()` names a contract every actor can drive and the seed is a position under it.
        launchRouter.initializePool(key, SQRT_PRICE_1_1);
        token.approve(address(launchRouter), type(uint256).max);
        vm.deal(address(this), 20_000 ether);
        launchRouter.modifyLiquidity{value: 10_100 ether}(
            key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(uint256(SEED_LIQUIDITY)), bytes32(0)), ""
        );

        // Holdings large enough that one or two actors can reach the 5% quorum (about 50M SURF).
        uint256[3] memory holdings = [uint256(200_000_000 ether), 100_000_000 ether, 60_000_000 ether];
        for (uint256 i = 0; i < actors.length; i++) {
            token.transfer(actors[i], holdings[i]);
            vm.startPrank(actors[i]);
            token.approve(address(hook), type(uint256).max);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(claimsRouter), type(uint256).max);
            manager.setOperator(address(claimsRouter), true);
            vm.stopPrank();
        }

        handler =
            new BuyGateHandler(manager, token, hook, key, swapRouter, claimsRouter, lpRouter, launchRouter, actors);
        // The handler's own one-wei stake, which it only ever tries to vote with from inside an unlock.
        token.transfer(address(handler), handler.HANDLER_STAKE());
        handler.stakeSelf();
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            token.approve(address(lpRouter), type(uint256).max);
            token.approve(address(launchRouter), type(uint256).max);
            vm.stopPrank();
        }

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = BuyGateHandler.buy.selector;
        selectors[1] = BuyGateHandler.sellExactIn.selector;
        selectors[2] = BuyGateHandler.sellExactOut.selector;
        selectors[3] = BuyGateHandler.deposit.selector;
        selectors[4] = BuyGateHandler.withdraw.selector;
        selectors[5] = BuyGateHandler.vote.selector;
        selectors[6] = BuyGateHandler.voteBig.selector;
        selectors[7] = BuyGateHandler.park.selector;
        selectors[8] = BuyGateHandler.unpark.selector;
        selectors[9] = BuyGateHandler.warp.selector;
        selectors[10] = BuyGateHandler.warpToNextWindow.selector;
        selectors[11] = BuyGateHandler.prepareWindow.selector;
        selectors[12] = BuyGateHandler.addLiquidityAsStranger.selector;
        selectors[13] = BuyGateHandler.flashVote.selector;
        selectors[14] = BuyGateHandler.addLiquidityThroughTheLaunchRouter.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------------------------------------
    // Custody: what the hook holds equals what it owes
    // ---------------------------------------------------------------------------------------------

    function invariant_hookHoldsExactlyTheStakes() public view {
        uint256 sum = hook.stakeOf(address(handler));
        for (uint256 i = 0; i < actors.length; i++) {
            sum += hook.stakeOf(actors[i]);
        }
        assertEq(token.balanceOf(address(hook)), sum, "hook token balance != sum of stakes");
        assertEq(sum, handler.ghostSumStake(), "sum of stakes != deposits - withdrawals");
        assertEq(hook.stakeOf(address(handler)), handler.HANDLER_STAKE(), "the handler's stake never moves");
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity: the launch's seed is the pool's only liquidity, whatever the actors try
    // ---------------------------------------------------------------------------------------------

    function invariant_poolLiquidityIsOnlyTheLaunchSeed() public view {
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), SEED_LIQUIDITY, "pool liquidity changed");
        (uint128 seedPosition,,) = IPoolManager(address(manager))
            .getPositionInfo(poolId, address(launchRouter), MIN_TICK, MAX_TICK, bytes32(0));
        assertEq(seedPosition, SEED_LIQUIDITY, "the launch's position under the shared router was topped up");
        assertTrue(hook.seeded());
        assertEq(hook.initializer(), address(launchRouter), "the initializer is the router that called initialize");
    }

    function invariant_flashVotesLeaveNoTrace() public view {
        assertFalse(hook.hasVoted(address(handler), hook.currentDay()), "a flash vote was recorded");
        assertEq(hook.lockedUntil(address(handler)), 0, "a flash vote locked the handler's stake");
    }

    function invariant_eachStakeIsDepositsMinusWithdrawals() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            assertEq(hook.stakeOf(a), handler.ghostDeposited(a) - handler.ghostWithdrawn(a));
            assertEq(hook.lockedUntil(a), handler.ghostLockedUntil(a), "lock differs from the vote that set it");
        }
    }

    function invariant_hookTakesNothing() public view {
        assertEq(address(hook).balance, 0, "the hook accumulated ETH");
        assertEq(token.balanceOf(address(hook)), handler.ghostSumStake(), "the hook accumulated tokens beyond stakes");
    }

    // ---------------------------------------------------------------------------------------------
    // Conservation: the manager's balances move only through swaps, parking and the hook's zero delta
    // ---------------------------------------------------------------------------------------------

    function invariant_managerBalancesFollowTheSwaps() public view {
        assertEq(
            address(manager).balance,
            handler.managerEthAtStart() + handler.ghostEthIn() - handler.ghostEthOut(),
            "manager ETH drifted from what buys paid and sells received"
        );
        assertEq(
            token.balanceOf(address(manager)),
            handler.managerTokenAtStart() + handler.ghostTokensIn() + handler.ghostParked() - handler.ghostTokensOut(),
            "manager tokens drifted from what sells paid, buys received and claims parked"
        );
    }

    function invariant_supplyIsConserved() public view {
        uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(hook))
            + token.balanceOf(address(manager)) + token.balanceOf(address(handler))
            + token.balanceOf(address(swapRouter)) + token.balanceOf(address(claimsRouter))
            + token.balanceOf(address(lpRouter)) + token.balanceOf(address(launchRouter));
        for (uint256 i = 0; i < actors.length; i++) {
            total += token.balanceOf(actors[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(total, token.totalSupply(), "tokens appeared or vanished");
    }

    // ---------------------------------------------------------------------------------------------
    // The rules, per day
    // ---------------------------------------------------------------------------------------------

    function invariant_soldNeverExceedsHalfOfThePreviousDaysBuys() public view {
        uint256 n = handler.touchedDaysLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 d = handler.touchedDays(i);
            (,,,,, uint256 soldD) = hook.records(d);
            if (d == 0) {
                assertEq(soldD, 0, "something sold on day 0");
                continue;
            }
            (,,,, uint256 boughtPrev,) = hook.records(d - 1);
            assertLe(soldD, boughtPrev / 2, "more than half of the previous day's buys was sold");
            assertLe(soldD, hook.sellAllowance(d));
        }
    }

    function invariant_nothingSoldOnADayWhoseVoteDidNotPass() public view {
        uint256 n = handler.touchedDaysLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 d = handler.touchedDays(i);
            (,,,,, uint256 soldD) = hook.records(d);
            if (d == 0 || !handler.ghostPassed(d - 1)) {
                assertEq(soldD, 0, "a sell happened without a passed vote the day before");
            }
        }
    }

    function invariant_recordsMatchTheGhostBooks() public view {
        uint256 n = handler.touchedDaysLength();
        for (uint256 i = 0; i < n; i++) {
            uint256 d = handler.touchedDays(i);
            (uint256 yes, uint256 no, uint256 quorum, bool hasVotes, uint256 boughtD, uint256 soldD) = hook.records(d);
            assertEq(yes, handler.ghostYes(d), "yes tally");
            assertEq(no, handler.ghostNo(d), "no tally");
            assertEq(quorum, handler.ghostQuorum(d), "quorum snapshot");
            assertEq(hasVotes, handler.ghostHasVotes(d), "hasVotes flag");
            assertEq(boughtD, handler.ghostBought(d), "bought volume");
            assertEq(soldD, handler.ghostSold(d), "sold volume");
            assertEq(hook.votePassed(d), handler.ghostPassed(d), "vote outcome");
        }
    }

    function invariant_windowAndRemainingAgreeWithTheTallies() public view {
        bool open = hook.sellWindowOpen();
        assertEq(open, handler.ghostWindowOpen(), "window state");
        uint256 day = hook.currentDay();
        (,,,,, uint256 soldToday) = hook.records(day);
        if (!open) {
            assertEq(hook.sellRemaining(), 0, "remaining must be zero while closed");
        } else {
            assertEq(hook.sellRemaining() + soldToday, hook.sellAllowance(day), "remaining + sold != allowance");
        }
        if (day > 0) assertTrue(hook.dayStart(day) <= block.timestamp && block.timestamp < hook.dayStart(day + 1));
    }

    // ---------------------------------------------------------------------------------------------
    // A scripted run through the handler, so the open-window sell path is known to be reachable and
    // the invariants above are not vacuous. Uses only handler entry points.
    // ---------------------------------------------------------------------------------------------

    function test_handlerReachesEveryPath() public {
        handler.buy(0, 10 ether);
        handler.voteBig(2, true); // actor2 stakes just over the 5% quorum and votes yes
        assertGt(hook.stakeOf(actors[2]), 0);
        handler.vote(2, true); // AlreadyVoted
        handler.vote(1, true); // NoStake
        handler.withdraw(2, 1); // StakeLocked
        handler.sellExactIn(0, 1 ether); // SellsClosed on day 0

        handler.warpToNextWindow(0);
        assertTrue(hook.sellWindowOpen());
        uint256 remaining = hook.sellRemaining();
        assertGt(remaining, 0);
        handler.sellExactIn(0, remaining + 1); // over the cap
        handler.sellExactIn(0, remaining / 2); // within the cap
        handler.sellExactOut(0, 0.01 ether); // small exact-output sell
        handler.park(1, 1_000 ether);
        handler.unpark(1, 500 ether);
        handler.withdraw(2, 1); // unlocked now
        handler.addLiquidityAsStranger(0, -1, 0, 333_000 ether); // the resting-sell-order shape, refused
        handler.addLiquidityAsStranger(1, type(int24).min, type(int24).max, 1); // full range, refused
        handler.addLiquidityThroughTheLaunchRouter(0, 0, 0, 1, true); // top-up of the seed position, refused
        handler.addLiquidityThroughTheLaunchRouter(2, -1, 0, 333_000 ether, false); // own position, refused
        handler.flashVote(true); // ManagerUnlocked, with the manager's whole balance flash-taken
        handler.flashVote(false);

        handler.warp(2 hours);
        handler.sellExactIn(0, 1); // closed again

        assertGt(handler.countBuys(), 0);
        assertGe(handler.countSellsOk(), 2);
        assertGe(handler.countSellsClosed(), 2);
        assertGe(handler.countSellsOverCap(), 1);
        assertGe(handler.countVotesOk(), 1);
        assertGe(handler.countWithdrawLocked(), 1);
        assertEq(handler.countLiquidityRefused(), 2);
        assertEq(handler.countLaunchRouterRefused(), 2);
        assertEq(handler.countFlashVotesRefused(), 2);

        invariant_hookHoldsExactlyTheStakes();
        invariant_poolLiquidityIsOnlyTheLaunchSeed();
        invariant_flashVotesLeaveNoTrace();
        invariant_eachStakeIsDepositsMinusWithdrawals();
        invariant_hookTakesNothing();
        invariant_managerBalancesFollowTheSwaps();
        invariant_supplyIsConserved();
        invariant_soldNeverExceedsHalfOfThePreviousDaysBuys();
        invariant_nothingSoldOnADayWhoseVoteDidNotPass();
        invariant_recordsMatchTheGhostBooks();
        invariant_windowAndRemainingAgreeWithTheTallies();
    }
}
