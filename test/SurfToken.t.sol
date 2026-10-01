// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SurfToken} from "../src/SurfToken.sol";

contract SurfTokenTest is Test {
    SurfToken token;

    function setUp() public {
        token = new SurfToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "SurfSurf");
        assertEq(token.symbol(), "SURF");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        uint256 before = token.balanceOf(address(this));
        assertTrue(token.transfer(to, 1_000 ether));
        assertEq(token.balanceOf(to), 1_000 ether);
        assertEq(token.balanceOf(address(this)), before - 1_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferMoreThanBalanceReverts() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "setFee(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), token.totalSupply());
    }
}
