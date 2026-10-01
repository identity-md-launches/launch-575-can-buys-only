// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SurfToken
/// @notice The launch token: a fixed-supply ERC-20 with nothing else.
/// @dev No constructor arguments, 18 decimals, exactly 1,000,000,000 tokens minted to the deployer.
/// There is no mint, burn-by-admin, owner, pause, blocklist, fee or upgrade path: every rule the
/// brief asks for (buys only, daily sell votes, the 50% sell cap) lives in the hook and applies to the
/// hook's pool only.
contract SurfToken is ERC20 {
    /// @notice 1,000,000,000 tokens in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("SurfSurf", "SURF") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
