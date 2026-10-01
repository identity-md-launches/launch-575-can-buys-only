// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Lock} from "v4-core/src/libraries/Lock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BuyGateHook
/// @notice A Uniswap v4 hook for one native-ETH / token pool that only lets the token be bought,
/// unless the holders voted the day before to open a one-hour sell window.
///
/// Rules, in the words of the brief:
///   - buys only: a swap that pays ETH and receives the token always passes; a swap that pays the token
///     is refused outside a sell window;
///   - every day, people can vote whether to open sells for one hour. A vote cast on day `d` decides the
///     window at the start of day `d + 1`. It passes with a majority of the weight cast (`yes > no`) and
///     at least the quorum, a fixed share of the circulating supply snapshotted at the first vote of the
///     day;
///   - if sells open, 50% of the previous day's buys can be sold: the aggregate token amount sold during
///     the window of day `d + 1` may not exceed half the token amount bought during day `d`.
///
/// Time is measured in days from the pool's initialization (`genesis`), so day `d` is the interval
/// `[genesis + d days, genesis + (d + 1) days)` and the sell window of day `d` is its first hour.
///
/// Votes are weighted by tokens the voter has deposited into this contract. A deposit that voted today is
/// locked until the day ends, so the same tokens cannot vote twice in one day from two addresses. A vote
/// is refused while the pool manager is unlocked, because the quorum snapshot reads the manager's token
/// balance and that balance can be moved freely inside an unlock.
///
/// Liquidity is the launch's alone. A position just below the price is a resting sell order that a buy
/// fills, so an open pool would let any holder turn tokens into ETH with no vote, no window and no cap,
/// and would let a holder inflate "bought" by buying from their own position. `beforeAddLiquidity`
/// therefore accepts a position only from the launch: during the transaction that initialized the pool,
/// from the account that initialized it, or as the pool's very first position. Removing liquidity is not
/// restricted: only the launch can have any.
///
/// The hook charges nothing, overrides no LP fee and returns no deltas. The pool keeps its ordinary
/// 0.3% LP fee (`fee` 3000, `tickSpacing` 60), which goes to liquidity providers as on any pool. Nobody can
/// change any of this: there is no owner and every parameter is a constant.
contract BuyGateHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Length of one voting day.
    uint256 public constant DAY = 1 days;

    /// @notice How long sells stay open at the start of a day whose vote passed.
    uint256 public constant SELL_WINDOW = 1 hours;

    /// @notice Share of the previous day's buys that may be sold during the window, in basis points.
    uint256 public constant SELL_SHARE_BPS = 5_000;

    /// @notice Minimum voting weight, as a share of the circulating supply, for a day's vote to count.
    uint256 public constant QUORUM_BPS = 500;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice The only LP fee the hook accepts at initialization: the standard 0.3% tier.
    uint24 public constant POOL_FEE = 3_000;

    /// @notice The only tick spacing the hook accepts at initialization.
    int24 public constant POOL_TICK_SPACING = 60;

    /// @dev Transient slot that is non-zero for the rest of the transaction that initialized the pool.
    /// Transient storage starts every transaction at zero, so no later transaction can reproduce it.
    /// Value: `bytes32(uint256(keccak256("BuyGateHook.initializing")) - 1)`, spelled out because inline
    /// assembly only accepts literal constants.
    bytes32 private constant INITIALIZING_SLOT = 0x0fff2561bcab1d02c072205a567a00fb4a1ea4b4b7282575981b59ff68913127;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The pool manager that is allowed to drive the callbacks.
    IPoolManager public immutable poolManager;

    /// @notice The id of the one pool this hook governs; zero until a pool is initialized.
    PoolId public poolId;

    /// @notice The launch token (`currency1` of the governed pool); zero until a pool is initialized.
    IERC20 public token;

    /// @notice The timestamp the governed pool was initialized at; day 0 starts here.
    uint256 public genesis;

    /// @notice The account that initialized the pool (the launch); it may add liquidity at any time.
    address public initializer;

    /// @notice True once the pool holds its first position. From then on only the launch may add.
    bool public seeded;

    /// @notice Everything the hook tracks about one day.
    /// @param yes      weight that voted to open sells on the next day
    /// @param no       weight that voted against
    /// @param quorum   minimum `yes + no` for the vote to count, snapshotted at the day's first vote
    /// @param hasVotes true once at least one vote was cast on this day
    /// @param bought   tokens bought from the pool during this day
    /// @param sold     tokens sold to the pool during this day's sell window
    struct DayRecord {
        uint256 yes;
        uint256 no;
        uint256 quorum;
        bool hasVotes;
        uint256 bought;
        uint256 sold;
    }

    /// @notice Per-day tallies and volumes, by day index.
    mapping(uint256 day => DayRecord) public records;

    /// @notice Tokens each voter has deposited and not withdrawn.
    mapping(address voter => uint256) public stakeOf;

    /// @notice Whether the voter has cast a vote on a given day.
    mapping(address voter => mapping(uint256 day => bool)) private _voted;

    /// @notice Earliest timestamp at which the voter may withdraw again.
    mapping(address voter => uint256) public lockedUntil;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event PoolBound(PoolId indexed poolId, address indexed token, uint256 genesis, address initializer);
    event Seeded(address indexed sender);
    event Deposited(address indexed voter, uint256 amount);
    event Withdrawn(address indexed voter, uint256 amount);
    event VoteCast(uint256 indexed day, address indexed voter, bool support, uint256 weight);
    event QuorumSnapshot(uint256 indexed day, uint256 circulating, uint256 quorum);
    event Bought(uint256 indexed day, uint256 amount);
    event Sold(uint256 indexed day, uint256 amount, uint256 remaining);

    error NotPoolManager();
    error HookNotImplemented();
    error AlreadyBound();
    error NotBound();
    error WrongFee(uint24 fee);
    error WrongTickSpacing(int24 tickSpacing);
    error QuoteMustBeNativeEth();
    error LiquidityNotFromLaunch(address sender);
    error ManagerUnlocked();
    error SellsClosed();
    error SellAllowanceExceeded(uint256 requested, uint256 remaining);
    error ZeroAmount();
    error NoStake();
    error InsufficientStake(uint256 requested, uint256 available);
    error AlreadyVoted(uint256 day);
    error StakeLocked(uint256 until);
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The chain's PoolManager. Never hardcoded: the deployer supplies it.
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        // Reverts if this contract was placed at an address whose permission bits disagree with
        // `getHookPermissions`, so a mis-mined deployment fails instead of producing a broken pool.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements; the deployed address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Pool lifecycle callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Binds the hook to its one pool. The pool must pair native ETH (`currency0`) with the token
    /// (`currency1`) at the standard 0.3% static fee and tick spacing 60. A second initialization is
    /// refused, so no other pool can ever share this hook's accounting. The caller of `initialize` is
    /// recorded as the launch, and the rest of this transaction is marked as the initialization
    /// transaction, during which any router may seed liquidity.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (genesis != 0) revert AlreadyBound();
        if (key.fee != POOL_FEE) revert WrongFee(key.fee);
        if (key.tickSpacing != POOL_TICK_SPACING) revert WrongTickSpacing(key.tickSpacing);
        if (!key.currency0.isAddressZero()) revert QuoteMustBeNativeEth();

        PoolId id = key.toId();
        poolId = id;
        token = IERC20(Currency.unwrap(key.currency1));
        genesis = block.timestamp;
        initializer = sender;
        assembly ("memory-safe") {
            tstore(INITIALIZING_SLOT, 1)
        }
        emit PoolBound(id, Currency.unwrap(key.currency1), block.timestamp, sender);

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Only the launch may add liquidity. A position is accepted when any of these hold:
    ///   - the call is in the transaction that initialized the pool (the factory seeds right after it);
    ///   - `sender` is the account that initialized the pool, acting as its own router;
    ///   - the pool has never held a position (the seed arrives in a later transaction).
    /// Every accepted position marks the pool as seeded, which closes the third case for good.
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (genesis == 0) revert NotBound();
        if (!_inInitializationTransaction() && sender != initializer && seeded) revert LiquidityNotFromLaunch(sender);
        if (!seeded) {
            seeded = true;
            emit Seeded(sender);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Buys (`zeroForOne`: ETH in, token out) always pass. Sells are refused unless the current day's
    /// window is open; an exact-input sell larger than the remaining allowance fails here, before the
    /// pool does any work. Exact-output sells are checked in `afterSwap`, once the token input is known.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (genesis == 0) revert NotBound();
        if (!params.zeroForOne) {
            (, uint256 remaining) = _openWindow();
            if (params.amountSpecified < 0) {
                // casting to 'uint256' is safe because the operand is the negation of a negative int256
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 requested = uint256(-params.amountSpecified);
                if (requested > remaining) revert SellAllowanceExceeded(requested, remaining);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Records the token amount a buy received into today's `bought`, or charges the token amount a
    /// sell paid against the window's allowance. Returns no delta: the hook takes nothing.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (genesis == 0) revert NotBound();
        int256 tokenDelta = int256(delta.amount1());
        uint256 day = currentDay();

        if (params.zeroForOne) {
            if (tokenDelta > 0) {
                // casting to 'uint256' is safe because tokenDelta was just checked to be positive
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 amount = uint256(tokenDelta);
                records[day].bought += amount;
                emit Bought(day, amount);
            }
        } else {
            (uint256 allowance, uint256 remaining) = _openWindow();
            // casting to 'uint256' is safe because the operand is the negation of a negative int128
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = tokenDelta < 0 ? uint256(-tokenDelta) : 0;
            if (amount > remaining) revert SellAllowanceExceeded(amount, remaining);
            uint256 soldSoFar = records[day].sold + amount;
            records[day].sold = soldSoFar;
            emit Sold(day, amount, allowance - soldSoFar);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Voting
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposits tokens to vote with. The voter must have approved this contract first.
    /// @dev Deposits are never counted as "bought" or "sold": they move between the voter and this
    /// contract, not through the pool.
    function deposit(uint256 amount) external {
        if (genesis == 0) revert NotBound();
        if (amount == 0) revert ZeroAmount();
        stakeOf[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @notice Withdraws deposited tokens. Refused until the day the voter last voted on has ended.
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 until = lockedUntil[msg.sender];
        if (block.timestamp < until) revert StakeLocked(until);
        uint256 available = stakeOf[msg.sender];
        if (amount > available) revert InsufficientStake(amount, available);
        stakeOf[msg.sender] = available - amount;
        emit Withdrawn(msg.sender, amount);
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
    }

    /// @notice Votes with the caller's whole deposit on whether tomorrow starts with a sell window.
    /// @dev One vote per address per day, weighted by the deposit at the time of the call. The deposit is
    /// locked until the day ends. The first vote of a day snapshots the quorum from the circulating supply,
    /// so voting is refused while the pool manager is unlocked: inside an unlock anyone can `take` the
    /// manager's whole token balance for the duration of the call and settle it back afterwards, which
    /// would let a single wei of stake snapshot a quorum of 5% of the total supply.
    /// @param support true to open sells for the first hour of the next day
    function vote(bool support) external {
        uint256 day = currentDay();
        uint256 weight = stakeOf[msg.sender];
        if (weight == 0) revert NoStake();
        if (_voted[msg.sender][day]) revert AlreadyVoted(day);
        if (poolManager.exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0)) revert ManagerUnlocked();

        DayRecord storage record = records[day];
        if (!record.hasVotes) {
            record.hasVotes = true;
            uint256 circulating = circulatingSupply();
            uint256 quorum = circulating * QUORUM_BPS / BPS;
            record.quorum = quorum;
            emit QuorumSnapshot(day, circulating, quorum);
        }
        if (support) record.yes += weight;
        else record.no += weight;

        _voted[msg.sender][day] = true;
        lockedUntil[msg.sender] = dayStart(day + 1);
        emit VoteCast(day, msg.sender, support, weight);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The index of the current day, counting from the pool's initialization.
    function currentDay() public view returns (uint256) {
        if (genesis == 0) revert NotBound();
        return (block.timestamp - genesis) / DAY;
    }

    /// @notice The timestamp at which `day` starts.
    function dayStart(uint256 day) public view returns (uint256) {
        if (genesis == 0) revert NotBound();
        return genesis + day * DAY;
    }

    /// @notice True when the voter cast a vote on `day`, for any past or current day.
    function hasVoted(address voter, uint256 day) external view returns (bool) {
        return _voted[voter][day];
    }

    /// @notice Tokens held outside the pool manager: total supply minus the manager's balance.
    /// @dev Deposits held by this contract count as circulating; they belong to voters. The manager's
    /// balance covers every pool and every ERC-6909 claim on it, not only this pool, and it can be moved
    /// while the manager is unlocked, which is why `vote` refuses to snapshot it then.
    function circulatingSupply() public view returns (uint256) {
        if (genesis == 0) revert NotBound();
        return token.totalSupply() - token.balanceOf(address(poolManager));
    }

    /// @notice Whether the vote cast during `day` opens a sell window at the start of `day + 1`.
    /// @dev Majority of the weight cast, and at least the quorum. A day with no votes never passes.
    function votePassed(uint256 day) public view returns (bool) {
        DayRecord storage record = records[day];
        return record.hasVotes && record.yes > record.no && record.yes + record.no >= record.quorum;
    }

    /// @notice The total tokens that may be sold during `day`'s window: half of the previous day's buys.
    function sellAllowance(uint256 day) public view returns (uint256) {
        if (day == 0) return 0;
        return records[day - 1].bought * SELL_SHARE_BPS / BPS;
    }

    /// @notice True while a sell window is open right now.
    function sellWindowOpen() public view returns (bool) {
        uint256 day = currentDay();
        if (day == 0) return false;
        if (block.timestamp >= dayStart(day) + SELL_WINDOW) return false;
        return votePassed(day - 1);
    }

    /// @notice Tokens that can still be sold in the current window; zero when sells are closed.
    function sellRemaining() external view returns (uint256) {
        if (!sellWindowOpen()) return 0;
        uint256 day = currentDay();
        uint256 allowance = sellAllowance(day);
        uint256 sold = records[day].sold;
        return sold >= allowance ? 0 : allowance - sold;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Reverts unless a sell window is open now; otherwise returns its allowance and what is left.
    function _openWindow() internal view returns (uint256 allowance, uint256 remaining) {
        if (!sellWindowOpen()) revert SellsClosed();
        uint256 day = currentDay();
        allowance = sellAllowance(day);
        uint256 sold = records[day].sold;
        remaining = sold >= allowance ? 0 : allowance - sold;
    }

    /// @dev True for the rest of the transaction in which `beforeInitialize` ran.
    function _inInitializationTransaction() internal view returns (bool initializing) {
        assembly ("memory-safe") {
            initializing := tload(INITIALIZING_SLOT)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not implement; the address carries no bit for them, so the pool
    // manager never calls them. They revert so a direct call cannot pretend otherwise. Removing
    // liquidity is deliberately among them: only the launch can hold a position, and it may unwind it.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
