// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stands in for the launch factory: initializes the pool and seeds it with token-only positions
/// in a single call, acting as its own liquidity router. It pays the token side itself and never needs ETH.
contract MockLaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Initializes `key` and adds every position in `positions`, all in this one call.
    function launch(PoolKey calldata key, uint160 sqrtPriceX96, ModifyLiquidityParams[] calldata positions) external {
        manager.initialize(key, sqrtPriceX96);
        manager.unlock(abi.encode(key, positions));
    }

    /// @notice Adds positions in a later transaction, still with this contract as the router.
    function addLater(PoolKey calldata key, ModifyLiquidityParams[] calldata positions) external {
        manager.unlock(abi.encode(key, positions));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, ModifyLiquidityParams[] memory positions) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams[]));

        int256 owed1;
        for (uint256 i = 0; i < positions.length; i++) {
            (BalanceDelta delta,) = manager.modifyLiquidity(key, positions[i], "");
            require(delta.amount0() == 0, "token-only positions expected");
            owed1 += delta.amount1();
        }
        if (owed1 < 0) {
            Currency token = key.currency1;
            manager.sync(token);
            IERC20(Currency.unwrap(token)).transfer(address(manager), uint256(-owed1));
            manager.settle();
        }
        return "";
    }
}
