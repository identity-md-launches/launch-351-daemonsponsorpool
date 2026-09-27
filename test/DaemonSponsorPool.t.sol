// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DaemonSponsorPool} from "../src/DaemonSponsorPool.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DaemonSponsorPoolTest is Test {
    LaunchToken internal token;
    DaemonSponsorPool internal app;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint256 internal constant BOND = 100_000 ether;

    function setUp() public {
        vm.warp(1_800_012_345);
        token = new LaunchToken();
        app = new DaemonSponsorPool(address(token));
        token.approve(address(app), type(uint256).max);
        address[3] memory workers = [ALICE, BOB, CAROL];
        for (uint256 i; i < workers.length; ++i) {
            token.transfer(workers[i], 2 * BOND);
            vm.prank(workers[i]);
            token.approve(address(app), type(uint256).max);
        }
    }

    function test_constructorNeedsOnlyTokenAndNoFunding() public view {
        assertEq(address(app.token()), address(token));
        assertEq(app.genesis(), block.timestamp);
        assertEq(app.currentEpoch(), 0);
        assertEq(app.BOND(), BOND);
        assertEq(app.EPOCH_DURATION(), 1 days);
        assertEq(token.balanceOf(address(app)), 0);
        _assertEpoch(0, 0, 0, false);
        _assertAccounting();
    }

    function test_rejectsZeroAndNonContractToken() public {
        vm.expectRevert(DaemonSponsorPool.InvalidToken.selector);
        new DaemonSponsorPool(address(0));
        vm.expectRevert(DaemonSponsorPool.InvalidToken.selector);
        new DaemonSponsorPool(ALICE);
    }

    function test_boundaryIs24HoursFromDeployment() public {
        _register(ALICE);
        app.sponsor(700 ether);
        vm.warp(app.genesis() + 1 days - 1);
        assertEq(app.currentEpoch(), 0);
        _checkIn(ALICE);
        _assertEpoch(0, 0, 1, false);
        _warpEpoch(1);
        assertEq(app.currentEpoch(), 1);
        _checkIn(ALICE);
        _assertEpoch(0, 0, 1, true);
        _assertEpoch(1, 100 ether, 1, false);
        assertEq(app.claimable(1, ALICE), 0);
        vm.warp(app.genesis() + 2 days - 1);
        assertEq(app.currentEpoch(), 1);
        _warpEpoch(2);
        assertEq(app.currentEpoch(), 2);
        assertEq(app.claimable(1, ALICE), 100 ether);
        // Viewing an ended epoch computes entitlement without mutating its stored finalisation flag.
        _assertEpoch(1, 100 ether, 1, false);
    }

    function test_sponsoringFirstAndCheckingInFirstUseSameSnapshot() public {
        DaemonSponsorPool other = new DaemonSponsorPool(address(token));
        token.approve(address(other), type(uint256).max);
        vm.prank(ALICE);
        token.approve(address(other), type(uint256).max);
        vm.prank(ALICE);
        other.register();
        _register(ALICE);
        app.sponsor(70);
        other.sponsor(70);
        _warpEpoch(1);
        app.sponsor(70);
        _checkIn(ALICE);
        vm.prank(ALICE);
        other.checkIn();
        other.sponsor(70);
        _assertEpoch(1, 10, 1, false);
        (uint256 budget, uint256 count, bool finalised) = other.epochInfo(1);
        assertEq(budget, 10);
        assertEq(count, 1);
        assertFalse(finalised);
        assertEq(app.pool(), 130);
        assertEq(other.pool(), 130);
        // New sponsorship never enlarges an already-open epoch, even on its first action.
        _checkIn(BOB, false);
        _assertAccounting();
    }

    function test_firstEverActionAfterIdleGapAllocatesOnlyCurrentEpoch() public {
        _warpEpoch(50);
        app.sponsor(700);
        _assertEpoch(0, 0, 0, false);
        _assertEpoch(49, 0, 0, false);
        _assertEpoch(50, 0, 0, false);
        assertEq(app.lastBudgetEpoch(), 50);
        assertEq(app.pool(), 700);
        _assertAccounting();
    }

    function test_noCheckInsReturnEntireBudgetBeforeNextSnapshot() public {
        _register(ALICE);
        app.sponsor(700);
        _warpEpoch(1);
        _register(BOB);
        _assertEpoch(1, 100, 0, false);
        assertEq(app.pool(), 600);
        _warpEpoch(2);
        _checkIn(ALICE);
        _assertEpoch(1, 100, 0, true);
        _assertEpoch(2, 100, 1, false);
        assertEq(app.pool(), 600);
        assertEq(app.reservedRewards(), 100);
        _assertAccounting();
    }

    function test_dustReturnsBeforeNextSnapshotAndClaimsStayFixed() public {
        _register(ALICE);
        _register(BOB);
        _register(CAROL);
        app.sponsor(70);
        _warpEpoch(1);
        _checkIn(ALICE);
        _checkIn(BOB);
        _checkIn(CAROL);
        _warpEpoch(2);
        assertEq(app.claimable(1, ALICE), 3);
        _claim(ALICE, 1);
        _assertEpoch(1, 10, 3, true);
        _assertEpoch(2, 8, 0, false);
        assertEq(app.pool(), 53); // (60 + 1 dust) - floor(61 / 7).
        assertEq(app.reservedRewards(), 14); // Two remaining shares of 3, plus the new 8.
        _claim(CAROL, 1);
        _claim(BOB, 1);
        assertEq(app.reservedRewards(), 8);
        assertEq(token.balanceOf(ALICE), BOND + 3);
        assertEq(token.balanceOf(BOB), BOND + 3);
        assertEq(token.balanceOf(CAROL), BOND + 3);
        _assertAccounting();
    }

    function test_idleGapDoesNotAllocateSkippedEpochsOrExpireClaims() public {
        _register(ALICE);
        app.sponsor(700);
        _warpEpoch(1);
        _checkIn(ALICE);
        _warpEpoch(1_000_000);
        _claim(ALICE, 1);
        _assertEpoch(1, 100, 1, true);
        _assertEpoch(2, 0, 0, false);
        _assertEpoch(999_999, 0, 0, false);
        _assertEpoch(1_000_000, 85, 0, false);
        assertEq(app.pool(), 515);
        assertEq(token.balanceOf(ALICE), BOND + 100);
        _assertAccounting();
    }

    function test_idleGapReturnsAnEmptyBudgetExactlyOnce() public {
        _register(ALICE);
        app.sponsor(700);
        _warpEpoch(1);
        _register(BOB);
        _warpEpoch(777);
        _checkIn(ALICE);
        _checkIn(BOB);
        _assertEpoch(777, 100, 2, false);
        assertEq(app.pool(), 600);
        assertEq(app.reservedRewards(), 100);
        _assertAccounting();
    }

    function test_doubleCheckInRevertsAndUnregisteredCannotCheckIn() public {
        _checkIn(ALICE, false);
        _register(ALICE);
        _checkIn(ALICE);
        vm.expectRevert(DaemonSponsorPool.AlreadyCheckedIn.selector);
        _checkIn(ALICE);
        _assertEpoch(0, 0, 1, false);
        _warpEpoch(1);
        _checkIn(ALICE);
        _assertEpoch(1, 0, 1, false);
    }

    function test_claimOnlyPastCheckedInEpochAndOnlyOnce() public {
        _register(ALICE);
        app.sponsor(700);
        _warpEpoch(1);
        _checkIn(ALICE);
        vm.expectRevert(DaemonSponsorPool.EpochNotPast.selector);
        _claim(ALICE, 1);
        vm.expectRevert(DaemonSponsorPool.EpochNotPast.selector);
        _claim(ALICE, 2);
        _warpEpoch(2);
        vm.expectRevert(DaemonSponsorPool.NotCheckedIn.selector);
        _claim(BOB, 1);
        vm.expectRevert(DaemonSponsorPool.NotCheckedIn.selector);
        _claim(ALICE, 0);
        _claim(ALICE, 1);
        vm.expectRevert(DaemonSponsorPool.AlreadyClaimed.selector);
        _claim(ALICE, 1);
        assertTrue(app.claimed(1, ALICE));
        assertEq(app.claimable(1, ALICE), 0);
        assertEq(token.balanceOf(ALICE), BOND + 100);
        _assertAccounting();
    }

    function test_zeroSharesReturnAllDustAndCanBeClaimedOnce() public {
        _register(ALICE);
        _register(BOB);
        app.sponsor(7);
        _warpEpoch(1);
        _checkIn(ALICE);
        _checkIn(BOB);
        _warpEpoch(2);
        _claim(ALICE, 1);
        _claim(BOB, 1);
        _assertEpoch(2, 1, 0, false);
        assertEq(app.pool(), 6);
        assertEq(app.reservedRewards(), 1);
        assertTrue(app.claimed(1, ALICE));
        vm.expectRevert(DaemonSponsorPool.AlreadyClaimed.selector);
        _claim(ALICE, 1);
        _assertAccounting();
    }

    function test_withdrawBondAtNextBoundaryThenReregister() public {
        _register(ALICE);
        vm.expectRevert(DaemonSponsorPool.StillRegistered.selector);
        vm.prank(ALICE);
        app.withdrawBond();
        vm.warp(app.genesis() + 1 days - 1);
        vm.prank(ALICE);
        app.deregister();
        assertFalse(app.isRegistered(ALICE));
        assertEq(app.bondUnlockEpoch(ALICE), 1);
        assertEq(app.totalBonds(), BOND);
        _checkIn(ALICE, false);
        vm.expectRevert(DaemonSponsorPool.BondAlreadyHeld.selector);
        _register(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonSponsorPool.BondLocked.selector, 1));
        vm.prank(ALICE);
        app.withdrawBond();
        _warpEpoch(1);
        vm.prank(ALICE);
        app.withdrawBond();
        assertEq(app.bondOf(ALICE), 0);
        assertEq(app.bondUnlockEpoch(ALICE), 0);
        assertEq(app.totalBonds(), 0);
        assertEq(token.balanceOf(ALICE), 2 * BOND);
        vm.expectRevert(DaemonSponsorPool.NoBond.selector);
        vm.prank(ALICE);
        app.withdrawBond();
        _register(ALICE);
        _checkIn(ALICE);
        assertTrue(app.isRegistered(ALICE));
        _assertAccounting();
    }

    function test_deregisterAtBoundaryWaitsAnotherFullEpoch() public {
        _register(ALICE);
        _warpEpoch(1);
        vm.prank(ALICE);
        app.deregister();
        assertEq(app.bondUnlockEpoch(ALICE), 2);
        vm.warp(app.genesis() + 2 days - 1);
        vm.expectRevert(abi.encodeWithSelector(DaemonSponsorPool.BondLocked.selector, 2));
        vm.prank(ALICE);
        app.withdrawBond();
        _warpEpoch(2);
        vm.prank(ALICE);
        app.withdrawBond();
        _assertAccounting();
    }

    function test_oldClaimsSurviveDeregistrationWithdrawalAndReregistration() public {
        _register(ALICE);
        app.sponsor(700);
        _warpEpoch(1);
        _checkIn(ALICE);
        vm.prank(ALICE);
        app.deregister();
        _warpEpoch(2);
        vm.prank(ALICE);
        app.withdrawBond();
        _claim(ALICE, 1);
        _register(ALICE);
        _checkIn(ALICE);
        vm.expectRevert(DaemonSponsorPool.AlreadyClaimed.selector);
        _claim(ALICE, 1);
        _warpEpoch(3);
        _claim(ALICE, 2);
        assertEq(token.balanceOf(ALICE), BOND + 185);
        _assertAccounting();
    }

    function test_invalidWorkerActionsRevert() public {
        vm.expectRevert(DaemonSponsorPool.NotRegistered.selector);
        vm.prank(ALICE);
        app.deregister();
        vm.expectRevert(DaemonSponsorPool.NoBond.selector);
        vm.prank(ALICE);
        app.withdrawBond();
        _register(ALICE);
        vm.expectRevert(DaemonSponsorPool.BondAlreadyHeld.selector);
        _register(ALICE);
        vm.prank(ALICE);
        app.deregister();
        vm.expectRevert(DaemonSponsorPool.NotRegistered.selector);
        vm.prank(ALICE);
        app.deregister();
        _assertAccounting();
    }

    function test_failedIncomingPaymentRollsBackCreditAndEpochRoll() public {
        app.sponsor(700);
        _warpEpoch(1);
        vm.prank(ALICE);
        token.approve(address(app), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 0, BOND));
        _register(ALICE);
        assertFalse(app.isRegistered(ALICE));
        assertEq(app.bondOf(ALICE), 0);
        assertEq(app.lastBudgetEpoch(), 0);
        _assertEpoch(0, 0, 0, false);
        _assertEpoch(1, 0, 0, false);
        assertEq(app.pool(), 700);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 0, 1));
        vm.prank(ALICE);
        app.sponsor(1);
        assertEq(app.pool(), 700);
        _assertAccounting();
    }

    function test_zeroSponsorshipAndInsufficientBalanceRevert() public {
        vm.expectRevert(DaemonSponsorPool.ZeroAmount.selector);
        app.sponsor(0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 2 * BOND, 2 * BOND + 1)
        );
        vm.prank(ALICE);
        app.sponsor(2 * BOND + 1);
        assertEq(app.pool(), 0);
        _assertAccounting();
    }

    function test_bondsAreNeverSponsorshipEvenOnWithdrawalRoll() public {
        _register(ALICE);
        _warpEpoch(1);
        _checkIn(ALICE);
        _assertEpoch(1, 0, 1, false);
        vm.prank(ALICE);
        app.deregister();
        _warpEpoch(2);
        vm.prank(ALICE);
        app.withdrawBond();
        _assertEpoch(2, 0, 0, false);
        assertEq(app.pool(), 0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_rejectsEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool emptyCall,) = address(app).call{value: 1}("");
        (bool payableCall,) = address(app).call{value: 1}(abi.encodeCall(app.sponsor, (1)));
        (bool adminCall,) = address(app).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(emptyCall);
        assertFalse(payableCall);
        assertFalse(adminCall);
        assertEq(address(app).balance, 0);
    }

    function testFuzz_rewardsAndBondsConserveFunds(uint256 gift) public {
        gift = bound(gift, 1, 100_000_000 ether);
        _register(ALICE);
        _register(BOB);
        _register(CAROL);
        app.sponsor(gift);
        _assertAccounting();
        _warpEpoch(1);
        _checkIn(ALICE);
        _checkIn(BOB);
        _checkIn(CAROL);
        uint256 share = (gift / 7) / 3;
        _warpEpoch(2);
        _claim(BOB, 1);
        _claim(ALICE, 1);
        _claim(CAROL, 1);
        assertEq(token.balanceOf(ALICE), BOND + share);
        assertEq(token.balanceOf(address(app)), 3 * BOND + gift - 3 * share);
        assertEq(app.pool() + app.reservedRewards(), gift - 3 * share);
        _assertAccounting();
    }

    function test_requiredEventsSupportFrontendHistory() public {
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.EpochRolled(0, 0);
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.Registered(ALICE);
        _register(ALICE);
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.Sponsored(address(this), 700);
        app.sponsor(700);
        _warpEpoch(1);
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.EpochRolled(1, 100);
        vm.expectEmit(true, true, false, true, address(app));
        emit DaemonSponsorPool.CheckedIn(1, ALICE);
        _checkIn(ALICE);
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.Deregistered(ALICE, 2);
        vm.prank(ALICE);
        app.deregister();
        _warpEpoch(2);
        vm.expectEmit(true, true, false, true, address(app));
        emit DaemonSponsorPool.Claimed(1, ALICE, 100);
        _claim(ALICE, 1);
        vm.expectEmit(true, false, false, true, address(app));
        emit DaemonSponsorPool.BondWithdrawn(ALICE, BOND);
        vm.prank(ALICE);
        app.withdrawBond();
    }

    function _register(address worker) internal {
        vm.prank(worker);
        app.register();
    }

    function _checkIn(address worker) internal {
        vm.prank(worker);
        app.checkIn();
    }

    function _checkIn(address worker, bool expected) internal {
        if (!expected) vm.expectRevert(DaemonSponsorPool.NotRegistered.selector);
        _checkIn(worker);
    }

    function _claim(address worker, uint256 epoch) internal {
        vm.prank(worker);
        app.claim(epoch);
    }

    function _warpEpoch(uint256 epoch) internal {
        vm.warp(app.genesis() + epoch * 1 days);
    }

    function _assertEpoch(uint256 epoch, uint256 budget, uint256 count, bool finalised) internal view {
        (uint256 actualBudget, uint256 actualCount, bool actualFinalised) = app.epochInfo(epoch);
        assertEq(actualBudget, budget);
        assertEq(actualCount, count);
        assertEq(actualFinalised, finalised);
    }

    function _assertAccounting() internal view {
        assertEq(token.balanceOf(address(app)), app.pool() + app.reservedRewards() + app.totalBonds());
    }
}
