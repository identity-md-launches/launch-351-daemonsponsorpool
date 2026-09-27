// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DaemonSponsorPool} from "../src/DaemonSponsorPool.sol";

/// @dev Independent ledger for supported SPON entrances (register/sponsor). No deals, mints,
///      direct transfers to the app, or reads of app accounting are used to advance the model.
///      Rejected actions are executed and their exact errors and rollback are checked.
contract AccountingModelHandler is Test {
    uint256 public constant BOND = 100_000 ether;
    uint256 public constant INITIAL_FUNDS = 10_000_000 ether;
    uint256 public constant WORKERS = 4;

    struct Worker {
        uint256 balance;
        uint256 allowance;
        uint256 bond;
        uint256 unlock;
        bool active;
    }

    struct Epoch {
        uint256 budget;
        uint256 members;
        uint256 claims;
        uint256 paid;
        bool finalised;
    }

    LaunchToken public immutable token;
    DaemonSponsorPool public immutable app;
    uint256 private immutable genesis;
    Worker[4] private workers;
    mapping(uint256 => Epoch) private epochs;
    uint256[] private touched;
    uint256 private available;
    uint256 private gifts;
    uint256 public rewardsPaid;
    uint256 public acceptedCalls;
    uint256 public rejectedCalls;
    uint256 public multiDayGaps;

    constructor(LaunchToken token_, DaemonSponsorPool app_) {
        token = token_;
        app = app_;
        genesis = vm.getBlockTimestamp();
        for (uint256 i; i < WORKERS; ++i) {
            workers[i].balance = INITIAL_FUNDS;
            workers[i].allowance = type(uint256).max;
            vm.prank(actor(i));
            token.approve(address(app), type(uint256).max);
        }
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0xA000 + seed % WORKERS));
    }

    function register(uint256 seed) external {
        uint256 i = seed % WORKERS;
        Worker storage w = workers[i];
        bytes memory error =
            w.bond != 0 ? abi.encodeWithSelector(DaemonSponsorPool.BondAlreadyHeld.selector) : _paymentError(i, BOND);
        (bool ok,) = _call(i, abi.encodeCall(app.register, ()), error);
        if (!ok) return;
        _roll();
        _spend(i, BOND);
        w.bond = BOND;
        w.active = true;
    }

    function deregister(uint256 seed) external {
        uint256 i = seed % WORKERS;
        bytes memory error;
        if (!workers[i].active) error = abi.encodeWithSelector(DaemonSponsorPool.NotRegistered.selector);
        (bool ok,) = _call(i, abi.encodeCall(app.deregister, ()), error);
        if (!ok) return;
        _roll();
        workers[i].active = false;
        workers[i].unlock = _current() + 1;
    }

    function withdrawBond(uint256 seed) external {
        uint256 i = seed % WORKERS;
        Worker storage w = workers[i];
        bytes memory error;
        if (w.bond == 0) error = abi.encodeWithSelector(DaemonSponsorPool.NoBond.selector);
        else if (w.active) error = abi.encodeWithSelector(DaemonSponsorPool.StillRegistered.selector);
        else if (_current() < w.unlock) error = abi.encodeWithSelector(DaemonSponsorPool.BondLocked.selector, w.unlock);
        uint256 beforeBalance = token.balanceOf(actor(i));
        (bool ok,) = _call(i, abi.encodeCall(app.withdrawBond, ()), error);
        if (!ok) return;
        assertEq(token.balanceOf(actor(i)) - beforeBalance, BOND, "bond payout");
        _roll();
        w.balance += BOND;
        w.bond = 0;
        w.unlock = 0;
    }

    function sponsor(uint256 seed, uint256 amount) external {
        uint256 i = seed % WORKERS;
        // Include zero, sub-token rounding values, spending the entire wallet, and overdraws.
        // Values in range retain their meaning for deterministic regression sequences.
        amount = bound(amount, 0, workers[i].balance + 1);
        bytes memory error =
            amount == 0 ? abi.encodeWithSelector(DaemonSponsorPool.ZeroAmount.selector) : _paymentError(i, amount);
        (bool ok,) = _call(i, abi.encodeCall(app.sponsor, (amount)), error);
        if (!ok) return;
        _roll();
        _spend(i, amount);
        available += amount;
        gifts += amount;
    }

    function checkIn(uint256 seed) external {
        uint256 i = seed % WORKERS;
        bytes memory error;
        if (!workers[i].active) {
            error = abi.encodeWithSelector(DaemonSponsorPool.NotRegistered.selector);
        } else if (epochs[_current()].members & (1 << i) != 0) {
            error = abi.encodeWithSelector(DaemonSponsorPool.AlreadyCheckedIn.selector);
        }
        (bool ok,) = _call(i, abi.encodeCall(app.checkIn, ()), error);
        if (!ok) return;
        _roll();
        epochs[_current()].members |= 1 << i;
    }

    function claim(uint256 seed, uint256 epochSeed) external {
        // Bias toward touched epochs: uniform sampling across multi-year gaps mostly finds
        // epochs without check-ins. Still exercise current, future and untouched epochs.
        uint256 epoch;
        uint256 choice = epochSeed % 4;
        if (choice == 0 && touched.length != 0) epoch = touched[(epochSeed / 4) % touched.length];
        else if (choice == 1) epoch = _current();
        else if (choice == 2) epoch = _current() + 1;
        else epoch = (epochSeed / 4) % (_current() + 1);
        _claim(seed % WORKERS, epoch);
    }

    function approve(uint256 seed, uint256 amount) external {
        uint256 i = seed % WORKERS;
        if (amount != type(uint256).max) amount = bound(amount, 0, 2 * BOND);
        vm.prank(actor(i));
        assertTrue(token.approve(address(app), amount));
        workers[i].allowance = amount;
    }

    function elapse(uint256 seed) external {
        uint256 beforeTime = vm.getBlockTimestamp();
        uint256 nextBoundary = genesis + (_current() + 1) * 1 days;
        uint256 mode = seed % 5;
        if (mode == 0) vm.warp(nextBoundary - 1);
        else if (mode == 1) vm.warp(nextBoundary);
        else if (mode == 2) vm.warp(nextBoundary + 1);
        else if (mode == 3) vm.warp(beforeTime + (2 + (seed / 5) % 10_000) * 1 days);
        else vm.warp(beforeTime + (seed / 5) % 1 days);
        if (vm.getBlockTimestamp() - beforeTime >= 2 days) ++multiDayGaps;
    }

    /// @dev Called by the invariant and the fixed/fuzz regression sequences. Expected liabilities
    ///      come from our ledger; actual epoch payments come from observed ERC-20 balance deltas.
    function assertAccounting() public view {
        uint256 bonds;
        uint256 unclaimed;
        uint256 paid;
        uint256 outside = token.totalSupply() - WORKERS * INITIAL_FUNDS;
        uint256 current = _current();
        assertEq(app.currentEpoch(), current, "epoch clock");
        assertEq(app.pool(), available, "available sponsorship");
        for (uint256 i; i < WORKERS; ++i) {
            Worker storage w = workers[i];
            address worker = actor(i);
            bonds += w.bond;
            outside += token.balanceOf(worker);
            assertEq(token.balanceOf(worker), w.balance, "worker balance");
            assertEq(token.allowance(worker, address(app)), w.allowance, "allowance rollback/spend");
            assertEq(app.bondOf(worker), w.bond, "bond ledger");
            assertEq(app.bondUnlockEpoch(worker), w.unlock, "bond unlock");
            assertEq(app.isRegistered(worker), w.active, "registration");
        }
        for (uint256 j; j < touched.length; ++j) {
            uint256 epoch = touched[j];
            Epoch storage e = epochs[epoch];
            uint256 count = _count(e.members);
            (uint256 budget, uint256 checkIns, bool finalised) = app.epochInfo(epoch);
            assertEq(budget, e.budget, "budget snapshot");
            assertEq(checkIns, count, "participant count");
            assertEq(finalised, e.finalised, "lazy finalisation");
            assertLe(e.paid, e.budget, "epoch paid more than its budget");
            uint256 share = count == 0 ? 0 : e.budget / count;
            assertEq(e.paid, share * _count(e.claims), "paid shares");
            paid += e.paid;
            unclaimed += e.finalised ? share * (count - _count(e.claims)) : e.budget;
            for (uint256 i; i < WORKERS; ++i) {
                bool member = e.members & (1 << i) != 0;
                bool claimed = e.claims & (1 << i) != 0;
                assertEq(app.checkedIn(epoch, actor(i)), member, "check-in ledger");
                assertEq(app.claimed(epoch, actor(i)), claimed, "claim ledger");
                assertEq(app.claimable(epoch, actor(i)), epoch < current && member && !claimed ? share : 0, "claimable");
            }
            // Sparse history keeps very long gaps cheap. Probe both ends of every skipped range.
            if (j != 0 && epoch > touched[j - 1] + 1) {
                _assertUntouched(touched[j - 1] + 1);
                _assertUntouched(epoch - 1);
            }
        }
        if (touched.length == 0 || touched[touched.length - 1] != current) _assertUntouched(current);
        assertEq(app.lastBudgetEpoch(), touched.length == 0 ? 0 : touched[touched.length - 1], "last budget");
        assertEq(app.totalBonds(), bonds, "aggregate bonds");
        assertEq(app.reservedRewards(), unclaimed, "unclaimed budgets");
        assertEq(token.balanceOf(address(app)), available + unclaimed + bonds, "SPON conservation");
        assertEq(gifts, available + unclaimed + paid, "sponsorship conservation");
        assertEq(rewardsPaid, paid, "payout ledger");
        assertEq(outside + token.balanceOf(address(app)), token.totalSupply(), "token conservation");
    }

    /// @dev Drain every earned share and return every bond after a random campaign. This detects
    ///      stranded obligations as well as arithmetic conservation with liabilities left pending.
    function settle() external {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        for (uint256 i; i < WORKERS; ++i) {
            if (workers[i].active) this.deregister(i);
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // First successful claim/withdrawal may append the new current epoch.
        for (uint256 j; j < touched.length; ++j) {
            uint256 epoch = touched[j];
            if (epoch >= _current()) continue;
            for (uint256 i; i < WORKERS; ++i) {
                if (epochs[epoch].members & (1 << i) != 0 && epochs[epoch].claims & (1 << i) == 0) {
                    _claim(i, epoch);
                }
            }
        }
        for (uint256 i; i < WORKERS; ++i) {
            if (workers[i].bond != 0) this.withdrawBond(i);
        }
        assertAccounting();
        assertEq(app.totalBonds(), 0, "all bonds returned");
        uint256 latest = touched[touched.length - 1];
        assertEq(app.reservedRewards(), epochs[latest].budget, "all past entitlements paid");
    }

    function _claim(uint256 i, uint256 epoch) private {
        Epoch storage e = epochs[epoch];
        bytes memory error;
        if (epoch >= _current()) error = abi.encodeWithSelector(DaemonSponsorPool.EpochNotPast.selector);
        else if (e.members & (1 << i) == 0) error = abi.encodeWithSelector(DaemonSponsorPool.NotCheckedIn.selector);
        else if (e.claims & (1 << i) != 0) error = abi.encodeWithSelector(DaemonSponsorPool.AlreadyClaimed.selector);
        uint256 beforeWorker = token.balanceOf(actor(i));
        uint256 beforeApp = token.balanceOf(address(app));
        (bool ok, bytes memory result) = _call(i, abi.encodeCall(app.claim, (epoch)), error);
        if (!ok) return;
        _roll();
        uint256 expected = e.budget / _count(e.members);
        uint256 received = token.balanceOf(actor(i)) - beforeWorker;
        assertEq(received, expected, "claim receipt");
        assertEq(beforeApp - token.balanceOf(address(app)), received, "claim outflow");
        assertEq(abi.decode(result, (uint256)), received, "claim return value");
        e.paid += received;
        e.claims |= 1 << i;
        workers[i].balance += expected;
        rewardsPaid += received;
        assertLe(e.paid, e.budget, "epoch payout cap");
    }

    function _call(uint256 i, bytes memory data, bytes memory error) private returns (bool ok, bytes memory result) {
        vm.prank(actor(i));
        (ok, result) = address(app).call(data);
        if (error.length == 0) {
            assertTrue(ok, "unexpected application revert");
            ++acceptedCalls;
        } else {
            assertFalse(ok, "invalid action succeeded");
            assertEq(result, error, "wrong rejection reason");
            ++rejectedCalls;
            // In particular, a failed first action after a gap must undo the tentative roll.
            assertAccounting();
        }
    }

    function _paymentError(uint256 i, uint256 amount) private view returns (bytes memory) {
        Worker storage w = workers[i];
        if (w.allowance < amount) {
            return
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, address(app), w.allowance, amount
                );
        }
        if (w.balance < amount) {
            return abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actor(i), w.balance, amount);
        }
        return "";
    }

    function _spend(uint256 i, uint256 amount) private {
        workers[i].balance -= amount;
        if (workers[i].allowance != type(uint256).max) workers[i].allowance -= amount;
    }

    function _roll() private {
        uint256 current = _current();
        if (touched.length != 0) {
            uint256 last = touched[touched.length - 1];
            if (last == current) return;
            Epoch storage previous = epochs[last];
            uint256 count = _count(previous.members);
            uint256 entitlement = count == 0 ? 0 : (previous.budget / count) * count;
            available += previous.budget - entitlement;
            previous.finalised = true;
        }
        uint256 budget = available / 7;
        available -= budget;
        epochs[current].budget = budget;
        touched.push(current);
    }

    function _assertUntouched(uint256 epoch) private view {
        (uint256 budget, uint256 count, bool finalised) = app.epochInfo(epoch);
        assertEq(budget, 0, "skipped epoch got a budget");
        assertEq(count, 0, "skipped epoch got check-ins");
        assertFalse(finalised, "skipped epoch finalised");
        for (uint256 i; i < WORKERS; ++i) {
            assertFalse(app.checkedIn(epoch, actor(i)), "skipped check-in");
            assertFalse(app.claimed(epoch, actor(i)), "skipped claim");
            assertEq(app.claimable(epoch, actor(i)), 0, "skipped entitlement");
        }
    }

    function _current() private view returns (uint256) {
        return (vm.getBlockTimestamp() - genesis) / 1 days;
    }

    function _count(uint256 mask) private pure returns (uint256 count) {
        for (uint256 i; i < WORKERS; ++i) {
            if (mask & (1 << i) != 0) ++count;
        }
    }
}

abstract contract StatefulAccountingFixture is Test {
    LaunchToken internal token;
    DaemonSponsorPool internal app;
    AccountingModelHandler internal handler;

    function setUp() public virtual {
        vm.warp(1_900_012_345); // Epochs must be relative to deployment, not UTC midnight.
        token = new LaunchToken();
        app = new DaemonSponsorPool(address(token));
        handler = new AccountingModelHandler(token, app);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actor(i), handler.INITIAL_FUNDS());
        }
    }
}

contract StatefulAccountingInvariantTest is StdInvariant, StatefulAccountingFixture {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 3; ++i) {
            handler.register(i);
        }
        handler.sponsor(3, 70_007);
        handler.elapse(1);
        for (uint256 i; i < 3; ++i) {
            handler.checkIn(i);
        }
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.register.selector;
        selectors[1] = handler.deregister.selector;
        selectors[2] = handler.withdrawBond.selector;
        selectors[3] = handler.sponsor.selector;
        selectors[4] = handler.checkIn.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.approve.selector;
        selectors[7] = handler.elapse.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_conservesSPONAndNeverOverpaysAnEpoch() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.settle();
    }
}

contract StatefulAccountingSequencesTest is StatefulAccountingFixture {
    function test_rejectedActionsAfterGapRollBackBudgetsBondsAndAllowances() public {
        handler.register(0);
        handler.sponsor(3, 700);
        handler.elapse(1);
        handler.checkIn(0);
        handler.deregister(0);
        handler.withdrawBond(0); // Locked, with the exact unlock epoch in the error.
        handler.register(0); // Pending bond cannot be reused.
        handler.checkIn(0); // Deregistration stops further participation.
        handler.approve(1, 0);
        handler.elapse(3); // Two full days; epoch 1 is still lazily unfinalised.
        handler.register(0);
        handler.deregister(0);
        handler.withdrawBond(1);
        handler.checkIn(1);
        handler.sponsor(3, 0);
        handler.register(1);
        handler.sponsor(1, 1);
        handler.claim(1, 4); // Touched epoch 1, but wrong worker.
        handler.claim(0, 1); // Current epoch.
        handler.claim(0, 2); // Future epoch.
        handler.approve(1, type(uint256).max);
        handler.sponsor(1, handler.INITIAL_FUNDS() + 1); // Balance failure, with adequate allowance.
        // A finite allowance spent before a failing transferFrom must be restored as well.
        handler.sponsor(2, handler.INITIAL_FUNDS());
        handler.elapse(3);
        handler.approve(2, handler.BOND());
        handler.register(2); // Zero balance.
        handler.sponsor(2, 1);
        handler.assertAccounting();
        assertEq(handler.rejectedCalls(), 16);
        handler.withdrawBond(0);
        handler.claim(0, 4);
        handler.claim(0, 4); // Replay after the bond has left.
        assertEq(handler.rewardsPaid(), 100);
        handler.assertAccounting();
    }

    function test_zeroValueClaimsAreConsumedWithoutSpendingOtherEpochsBudgets() public {
        for (uint256 i; i < 3; ++i) {
            handler.register(i);
        }
        handler.sponsor(3, 7);
        handler.elapse(1);
        for (uint256 i; i < 3; ++i) {
            handler.checkIn(i);
        }
        handler.checkIn(0); // Duplicate at a one-unit budget.
        handler.claim(0, 1); // The current epoch cannot be claimed, even for zero.
        handler.elapse(3);
        for (uint256 i; i < 3; ++i) {
            handler.claim(i, 4);
            handler.claim(i, 4);
            handler.assertAccounting();
        }
        assertEq(handler.rewardsPaid(), 0);
        assertEq(handler.rejectedCalls(), 5);
        assertEq(app.pool(), 6);
        assertEq(app.reservedRewards(), 1);
        handler.settle();
    }

    function testFuzz_outOfOrderClaimsAcrossGapsAndWorkerLifecycles(uint256 gift, uint256 gap, uint256 order) public {
        gift = bound(gift, 7, 1_000_000 ether);
        gap = bound(gap, 2, 10_001);
        for (uint256 i; i < 3; ++i) {
            handler.register(i);
        }
        handler.sponsor(3, gift);
        handler.elapse(1);
        for (uint256 i; i < 3; ++i) {
            handler.checkIn(i);
        }
        handler.checkIn(order % 3);
        handler.claim(0, 1);
        handler.assertAccounting();
        handler.deregister(0);
        handler.withdrawBond(0); // A same-epoch withdrawal must fail.
        handler.elapse((gap - 2) * 5 + 3);
        handler.withdrawBond(0); // Bond withdrawal itself opens the new budget.
        handler.register(0);
        for (uint256 i; i < 3; ++i) {
            handler.checkIn(i);
        }
        handler.assertAccounting();
        handler.elapse(3);
        // Claim the newer epoch before the oldest one, with a fuzzed permutation of claimants.
        for (uint256 j; j < 3; ++j) {
            uint256 i = (order % 3 + j) % 3;
            handler.claim(i, 8); // Third touched epoch.
            handler.claim(i, 4); // Epoch 1.
            handler.claim(i, 8);
            handler.claim(i, 4);
            handler.assertAccounting();
        }
        uint256 firstBudget = gift / 7;
        uint256 firstShare = firstBudget / 3;
        uint256 nextBudget = (gift - firstShare * 3) / 7;
        assertEq(handler.rewardsPaid(), 3 * (firstShare + nextBudget / 3));
        assertEq(handler.rejectedCalls(), 9);
        assertEq(handler.multiDayGaps(), 2);
        handler.settle();
    }
}
