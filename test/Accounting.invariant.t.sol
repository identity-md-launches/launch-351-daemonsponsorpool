// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DaemonSponsorPool} from "../src/DaemonSponsorPool.sol";

contract PoolHandler is Test {
    LaunchToken public immutable token;
    DaemonSponsorPool public immutable app;
    address[4] public workers = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public gifts;
    uint256 public rewardsPaid;

    constructor(LaunchToken token_, DaemonSponsorPool app_) {
        token = token_;
        app = app_;
        for (uint256 i; i < workers.length; ++i) {
            vm.prank(workers[i]);
            token.approve(address(app), type(uint256).max);
        }
    }

    function register(uint256 seed) external {
        address worker = _worker(seed);
        if (app.bondOf(worker) != 0 || token.balanceOf(worker) < app.BOND()) return;
        vm.prank(worker);
        app.register();
    }

    function deregister(uint256 seed) external {
        address worker = _worker(seed);
        if (!app.isRegistered(worker)) return;
        vm.prank(worker);
        app.deregister();
    }

    function withdrawBond(uint256 seed) external {
        address worker = _worker(seed);
        if (app.isRegistered(worker) || app.bondOf(worker) == 0 || app.currentEpoch() < app.bondUnlockEpoch(worker)) {
            return;
        }
        uint256 beforeBalance = token.balanceOf(worker);
        vm.prank(worker);
        app.withdrawBond();
        assertEq(token.balanceOf(worker) - beforeBalance, app.BOND());
    }

    function sponsor(uint256 seed, uint256 amount) external {
        address worker = _worker(seed);
        uint256 limit = token.balanceOf(worker);
        if (limit == 0) return;
        if (limit > 10_000 ether) limit = 10_000 ether;
        amount = bound(amount, 1, limit);
        vm.prank(worker);
        app.sponsor(amount);
        gifts += amount;
    }

    function checkIn(uint256 seed) external {
        address worker = _worker(seed);
        if (!app.isRegistered(worker) || app.checkedIn(app.currentEpoch(), worker)) return;
        vm.prank(worker);
        app.checkIn();
    }

    function claim(uint256 seed, uint256 epoch) external {
        address worker = _worker(seed);
        uint256 current = app.currentEpoch();
        if (current == 0) return;
        epoch = bound(epoch, 0, current - 1);
        if (!app.checkedIn(epoch, worker) || app.claimed(epoch, worker)) return;
        (uint256 budget, uint256 count,) = app.epochInfo(epoch);
        uint256 expected = budget / count;
        uint256 beforeBalance = token.balanceOf(worker);
        vm.prank(worker);
        uint256 result = app.claim(epoch);
        assertEq(result, expected);
        assertEq(token.balanceOf(worker) - beforeBalance, expected);
        rewardsPaid += expected;
    }

    function elapse(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 0, 3 days));
    }

    function _worker(uint256 seed) private view returns (address) {
        return workers[seed % workers.length];
    }
}

contract AccountingInvariantTest is StdInvariant, Test {
    LaunchToken private token;
    DaemonSponsorPool private app;
    PoolHandler private handler;

    function setUp() public {
        vm.warp(1_800_012_345);
        token = new LaunchToken();
        app = new DaemonSponsorPool(address(token));
        handler = new PoolHandler(token, app);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.workers(i), 10_000_000 ether);
            handler.register(i);
        }
        // Start with useful state; random calls then mix payments, time jumps and worker lifecycle changes.
        handler.sponsor(0, 7_000 ether);
        handler.elapse(1 days);
        handler.checkIn(0);
        handler.checkIn(1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PoolHandler.register.selector;
        selectors[1] = PoolHandler.deregister.selector;
        selectors[2] = PoolHandler.withdrawBond.selector;
        selectors[3] = PoolHandler.sponsor.selector;
        selectors[4] = PoolHandler.checkIn.selector;
        selectors[5] = PoolHandler.claim.selector;
        selectors[6] = PoolHandler.elapse.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_balanceEqualsPoolUnclaimedBudgetsAndBonds() public view {
        uint256 reconstructedRewards;
        uint256 reconstructedBonds;
        uint256 circulating = token.balanceOf(address(this));
        for (uint256 i; i < 4; ++i) {
            address worker = handler.workers(i);
            uint256 bond = app.bondOf(worker);
            reconstructedBonds += bond;
            circulating += token.balanceOf(worker);
            if (app.isRegistered(worker)) {
                assertEq(bond, app.BOND());
                assertEq(app.bondUnlockEpoch(worker), 0);
            } else if (bond != 0) {
                assertEq(bond, app.BOND());
                assertGt(app.bondUnlockEpoch(worker), 0);
            }
        }
        uint256 current = app.currentEpoch();
        for (uint256 epoch; epoch <= current; ++epoch) {
            (uint256 budget, uint256 count, bool finalised) = app.epochInfo(epoch);
            uint256 checkedCount;
            uint256 paidCount;
            for (uint256 i; i < 4; ++i) {
                address worker = handler.workers(i);
                if (app.checkedIn(epoch, worker)) ++checkedCount;
                if (app.claimed(epoch, worker)) {
                    ++paidCount;
                    assertTrue(app.checkedIn(epoch, worker));
                    assertTrue(finalised);
                    assertLt(epoch, current);
                }
            }
            assertEq(checkedCount, count);
            if (finalised) {
                assertLt(epoch, current);
                if (count != 0) reconstructedRewards += (budget / count) * (count - paidCount);
            } else {
                // Includes the most recent budget while it awaits lazy finalisation, even if time has advanced.
                reconstructedRewards += budget;
            }
        }
        assertEq(app.totalBonds(), reconstructedBonds);
        assertEq(app.reservedRewards(), reconstructedRewards);
        assertEq(token.balanceOf(address(app)), app.pool() + reconstructedRewards + reconstructedBonds);
        assertEq(handler.gifts(), app.pool() + reconstructedRewards + handler.rewardsPaid());
        assertEq(circulating + token.balanceOf(address(app)), token.totalSupply());
        assertEq(token.totalSupply(), 1e27);
    }
}
