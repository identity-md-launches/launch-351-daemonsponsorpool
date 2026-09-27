// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DaemonSponsorPool} from "../src/DaemonSponsorPool.sol";

/// @dev Hostile test double, never a supported production currency.
contract InteractionToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Revert,
        NoReturn
    }

    error TransferRejected();

    Mode public incomingMode;
    Mode public outgoingMode;
    address public failedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackIncoming;
    bool public callbackOutgoing;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Hostile test double", "TEST") {
        _mint(msg.sender, 1e27);
    }

    function configureModes(Mode incoming, Mode outgoing, address recipient) external {
        incomingMode = incoming;
        outgoingMode = outgoing;
        failedRecipient = recipient;
    }

    function configureCallback(address target, bytes memory data, bool incoming, bool outgoing) external {
        callbackTarget = target;
        callbackData = data;
        callbackIncoming = incoming;
        callbackOutgoing = outgoing;
    }

    function act(address target, bytes memory data) external returns (bytes memory result) {
        bool success;
        (success, result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (callbackIncoming) _callback();
        return _respond(incomingMode);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (callbackOutgoing) _callback();
        return _respond(failedRecipient == address(0) || failedRecipient == to ? outgoingMode : Mode.Normal);
    }

    function _callback() private {
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }

    function _respond(Mode mode) private pure returns (bool) {
        if (mode == Mode.Revert) revert TransferRejected();
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

contract TokenInteractionsTest is Test {
    InteractionToken private token;
    DaemonSponsorPool private app;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant BOND = 100_000 ether;

    function setUp() public {
        vm.warp(1_800_012_345);
        token = new InteractionToken();
        app = new DaemonSponsorPool(address(token));
        token.approve(address(app), type(uint256).max);
        token.transfer(ALICE, 2 * BOND);
        token.transfer(BOB, 2 * BOND);
        vm.prank(ALICE);
        token.approve(address(app), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(app), type(uint256).max);
    }

    function test_falseReturnRollsBackIncomingTransferAndRegistration() public {
        app.sponsor(700);
        vm.warp(app.genesis() + 1 days);
        token.configureModes(InteractionToken.Mode.ReturnFalse, InteractionToken.Mode.Normal, address(0));
        _expectSafeFailure();
        vm.prank(ALICE);
        app.register();
        assertEq(token.balanceOf(ALICE), 2 * BOND);
        assertEq(app.totalBonds(), 0);
        assertFalse(app.isRegistered(ALICE));
        _expectSafeFailure();
        app.sponsor(100);
        assertEq(app.lastBudgetEpoch(), 0);
        assertEq(app.pool(), 700);
        assertEq(app.reservedRewards(), 0);
        assertEq(token.balanceOf(address(app)), 700);
    }

    function test_failedClaimRollsBackAndDoesNotBlockAnotherWorker() public {
        _prepareRewards();
        token.configureModes(InteractionToken.Mode.Normal, InteractionToken.Mode.ReturnFalse, ALICE);
        _expectSafeFailure();
        vm.prank(ALICE);
        app.claim(1);
        assertFalse(app.claimed(1, ALICE));
        assertEq(app.claimable(1, ALICE), 50);
        assertEq(app.lastBudgetEpoch(), 1);
        assertEq(app.reservedRewards(), 100);
        assertEq(token.balanceOf(ALICE), BOND);
        vm.prank(BOB);
        app.claim(1);
        assertEq(token.balanceOf(BOB), BOND + 50);
        token.configureModes(InteractionToken.Mode.Normal, InteractionToken.Mode.Normal, address(0));
        vm.prank(ALICE);
        app.claim(1);
        assertEq(token.balanceOf(ALICE), BOND + 50);
        _assertAccounting();
    }

    function test_revertingBondWithdrawalPreservesBondForRetry() public {
        vm.prank(ALICE);
        app.register();
        vm.prank(ALICE);
        app.deregister();
        vm.warp(app.genesis() + 1 days);
        token.configureModes(InteractionToken.Mode.Normal, InteractionToken.Mode.Revert, ALICE);
        vm.expectRevert(InteractionToken.TransferRejected.selector);
        vm.prank(ALICE);
        app.withdrawBond();
        assertEq(app.bondOf(ALICE), BOND);
        assertEq(app.bondUnlockEpoch(ALICE), 1);
        assertEq(app.totalBonds(), BOND);
        assertEq(app.lastBudgetEpoch(), 0);
        token.configureModes(InteractionToken.Mode.Normal, InteractionToken.Mode.Normal, address(0));
        vm.prank(ALICE);
        app.withdrawBond();
        assertEq(app.totalBonds(), 0);
        assertEq(token.balanceOf(ALICE), 2 * BOND);
        _assertAccounting();
    }

    function test_safeTransfersAcceptNoReturnData() public {
        token.configureModes(InteractionToken.Mode.NoReturn, InteractionToken.Mode.NoReturn, address(0));
        _prepareRewards();
        vm.prank(ALICE);
        app.claim(1);
        vm.prank(ALICE);
        app.deregister();
        vm.warp(app.genesis() + 3 days);
        vm.prank(ALICE);
        app.withdrawBond();
        assertEq(token.balanceOf(ALICE), 2 * BOND + 50);
        _assertAccounting();
    }

    function test_incomingCallbackCannotEnterAnyMutation() public {
        bytes[6] memory calls = [
            abi.encodeCall(app.register, ()),
            abi.encodeCall(app.deregister, ()),
            abi.encodeCall(app.withdrawBond, ()),
            abi.encodeCall(app.sponsor, (1)),
            abi.encodeCall(app.checkIn, ()),
            abi.encodeCall(app.claim, (0))
        ];
        for (uint256 i; i < calls.length; ++i) {
            token.configureCallback(address(app), calls[i], true, false);
            app.sponsor(1);
            _assertGuardRejectedCallback();
        }
        assertEq(app.pool(), 6);
        _assertAccounting();
    }

    function test_outgoingCallbackCannotDoubleClaimOrWithdrawBond() public {
        // The hostile token itself is the worker: nested attempts have the same caller as the original action.
        token.transfer(address(token), BOND);
        token.act(address(token), abi.encodeCall(token.approve, (address(app), type(uint256).max)));
        token.act(address(app), abi.encodeCall(app.register, ()));
        app.sponsor(700);
        vm.warp(app.genesis() + 1 days);
        token.act(address(app), abi.encodeCall(app.checkIn, ()));
        token.act(address(app), abi.encodeCall(app.deregister, ()));
        vm.warp(app.genesis() + 2 days);
        token.configureCallback(address(app), abi.encodeCall(app.claim, (1)), false, true);
        token.act(address(app), abi.encodeCall(app.claim, (1)));
        _assertGuardRejectedCallback();
        assertEq(token.balanceOf(address(token)), 100);
        assertTrue(app.claimed(1, address(token)));
        token.configureCallback(address(app), abi.encodeCall(app.withdrawBond, ()), false, true);
        token.act(address(app), abi.encodeCall(app.withdrawBond, ()));
        _assertGuardRejectedCallback();
        assertEq(token.balanceOf(address(token)), BOND + 100);
        assertEq(app.totalBonds(), 0);
        _assertAccounting();
    }

    function _prepareRewards() private {
        vm.prank(ALICE);
        app.register();
        vm.prank(BOB);
        app.register();
        app.sponsor(700);
        vm.warp(app.genesis() + 1 days);
        vm.prank(ALICE);
        app.checkIn();
        vm.prank(BOB);
        app.checkIn();
        vm.warp(app.genesis() + 2 days);
    }

    function _expectSafeFailure() private {
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
    }

    function _assertGuardRejectedCallback() private view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertAccounting() private view {
        assertEq(token.balanceOf(address(app)), app.pool() + app.reservedRewards() + app.totalBonds());
    }
}
