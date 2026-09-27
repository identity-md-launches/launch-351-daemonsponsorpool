// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Sponsor");
        assertEq(token.symbol(), "SPON");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transferHasNoFee(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), amount);
    }

    function test_approveAndTransferFrom() public {
        token.approve(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40 ether));
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.allowance(address(this), ALICE), 60 ether);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_insufficientBalanceAndAllowanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_zeroAddressAndDeadAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertTrue(token.transfer(address(0xdead), 1 ether));
        assertEq(token.balanceOf(address(0xdead)), 1 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_noMintOrAdminSelectorsForAnyone() public {
        string[12] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "burn(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], ALICE, uint256(1));
            (bool deployerSuccess,) = address(token).call(data);
            vm.prank(ALICE);
            (bool outsiderSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            assertFalse(outsiderSuccess);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
