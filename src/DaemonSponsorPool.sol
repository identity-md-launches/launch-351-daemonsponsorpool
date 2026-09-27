// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless SPON sponsorship toy. Each bonded worker can check in once per 24-hour epoch.
/// @dev Deploy only with the fixed-supply, non-rebasing, fee-free LaunchToken. All amounts are minor units.
///      Every successful mutation rolls before its own effects, including before incoming sponsorships.
contract DaemonSponsorPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BOND = 100_000 ether;
    uint256 public constant EPOCH_DURATION = 1 days;

    IERC20 public immutable token;
    uint256 public immutable genesis;

    /// @notice Sponsorship available for future budgets, excluding bonds and reserved rewards.
    uint256 public pool;
    uint256 public totalBonds;
    /// @notice Unclaimed finalised shares plus the entire budget of the latest unfinalised epoch.
    uint256 public reservedRewards;
    uint256 public lastBudgetEpoch;

    struct Epoch {
        uint256 budget;
        uint256 checkIns;
        bool finalised;
    }

    bool private _hasBudget;
    mapping(uint256 epoch => Epoch) private _epochs;
    mapping(address worker => bool) public isRegistered;
    mapping(address worker => uint256) public bondOf;
    /// @notice First epoch when a deregistered worker can withdraw; zero when no withdrawal is pending.
    mapping(address worker => uint256) public bondUnlockEpoch;
    mapping(uint256 epoch => mapping(address worker => bool)) public checkedIn;
    mapping(uint256 epoch => mapping(address worker => bool)) public claimed;

    error InvalidToken();
    error ZeroAmount();
    error BondAlreadyHeld();
    error NotRegistered();
    error StillRegistered();
    error NoBond();
    error BondLocked(uint256 unlockEpoch);
    error AlreadyCheckedIn();
    error EpochNotPast();
    error NotCheckedIn();
    error AlreadyClaimed();

    event Registered(address indexed worker);
    event Deregistered(address indexed worker, uint256 unlockEpoch);
    event BondWithdrawn(address indexed worker, uint256 amount);
    event Sponsored(address indexed sponsor, uint256 amount);
    event CheckedIn(uint256 indexed epoch, address indexed worker);
    event EpochRolled(uint256 indexed epoch, uint256 budget);
    event Claimed(uint256 indexed epoch, address indexed worker, uint256 amount);

    /// @param token_ The already deployed SPON LaunchToken, supplied as $token by the manifest.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
        genesis = block.timestamp;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / EPOCH_DURATION;
    }

    /// @notice Stored snapshot. Untouched epochs return (0, 0, false); views never roll epochs.
    function epochInfo(uint256 epoch) external view returns (uint256 budget, uint256 checkIns, bool finalised) {
        Epoch storage info = _epochs[epoch];
        return (info.budget, info.checkIns, info.finalised);
    }

    /// @notice Past-epoch entitlement, including an ended epoch awaiting lazy finalisation.
    /// @dev Zero also represents an eligible zero-value share; use checkedIn/claimed to distinguish it.
    function claimable(uint256 epoch, address worker) external view returns (uint256) {
        if (epoch >= currentEpoch() || !checkedIn[epoch][worker] || claimed[epoch][worker]) return 0;
        Epoch storage info = _epochs[epoch];
        return info.budget / info.checkIns;
    }

    function register() external nonReentrant {
        _rollEpoch();
        if (bondOf[msg.sender] != 0) revert BondAlreadyHeld();
        isRegistered[msg.sender] = true;
        bondOf[msg.sender] = BOND;
        totalBonds += BOND;
        token.safeTransferFrom(msg.sender, address(this), BOND);
        emit Registered(msg.sender);
    }

    function deregister() external nonReentrant {
        uint256 epoch = _rollEpoch();
        if (!isRegistered[msg.sender]) revert NotRegistered();
        isRegistered[msg.sender] = false;
        bondUnlockEpoch[msg.sender] = epoch + 1;
        emit Deregistered(msg.sender, epoch + 1);
    }

    function withdrawBond() external nonReentrant {
        uint256 epoch = _rollEpoch();
        uint256 amount = bondOf[msg.sender];
        if (amount == 0) revert NoBond();
        if (isRegistered[msg.sender]) revert StillRegistered();
        if (epoch < bondUnlockEpoch[msg.sender]) revert BondLocked(bondUnlockEpoch[msg.sender]);
        delete bondOf[msg.sender];
        delete bondUnlockEpoch[msg.sender];
        totalBonds -= amount;
        token.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    /// @notice Irrevocable gift. The current budget is snapshotted before this amount is added.
    function sponsor(uint256 amount) external nonReentrant {
        _rollEpoch();
        if (amount == 0) revert ZeroAmount();
        pool += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Sponsored(msg.sender, amount);
    }

    function checkIn() external nonReentrant {
        uint256 epoch = _rollEpoch();
        if (!isRegistered[msg.sender]) revert NotRegistered();
        if (checkedIn[epoch][msg.sender]) revert AlreadyCheckedIn();
        checkedIn[epoch][msg.sender] = true;
        _epochs[epoch].checkIns += 1;
        emit CheckedIn(epoch, msg.sender);
    }

    /// @notice Pull one past epoch's share to the caller. Registration need not still be active.
    function claim(uint256 epoch) external nonReentrant returns (uint256 amount) {
        uint256 current = _rollEpoch();
        if (epoch >= current) revert EpochNotPast();
        if (!checkedIn[epoch][msg.sender]) revert NotCheckedIn();
        if (claimed[epoch][msg.sender]) revert AlreadyClaimed();
        Epoch storage info = _epochs[epoch];
        amount = info.budget / info.checkIns;
        claimed[epoch][msg.sender] = true;
        reservedRewards -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(epoch, msg.sender, amount);
    }

    /// @dev O(1) even after a long idle gap. Finalisation never sends funds to workers.
    function _rollEpoch() private returns (uint256 epoch) {
        epoch = currentEpoch();
        if (_hasBudget && epoch == lastBudgetEpoch) return epoch;

        if (_hasBudget) {
            Epoch storage previous = _epochs[lastBudgetEpoch];
            uint256 returned = previous.checkIns == 0 ? previous.budget : previous.budget % previous.checkIns;
            previous.finalised = true;
            pool += returned;
            reservedRewards -= returned;
        }

        uint256 budget = pool / 7;
        pool -= budget;
        reservedRewards += budget;
        _epochs[epoch].budget = budget;
        lastBudgetEpoch = epoch;
        _hasBudget = true;
        emit EpochRolled(epoch, budget);
    }
}
