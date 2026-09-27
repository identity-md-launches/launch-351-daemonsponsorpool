# ABI integration guide

[LaunchToken.json](LaunchToken.json) and [DaemonSponsorPool.json](DaemonSponsorPool.json) are Solidity ABI arrays exported by Forge from the pinned compiler. All monetary values are `uint256` SPON minor units (18 decimals), and epochs are zero-based `uint256` values.

## Read calls

| Call | Meaning |
| --- | --- |
| `token()` | Immutable ERC-20 address; use this to select the token ABI |
| `genesis()`, `EPOCH_DURATION()`, `currentEpoch()` | Deployment-time epoch origin, duration in seconds, current epoch |
| `BOND()` | Required bond in SPON minor units |
| `pool()` | Accounted gift balance not yet reserved as rewards |
| `epochInfo(e)` | `(budget, checkIns, finalised)`; untouched epochs return `(0, 0, false)` |
| `isRegistered(worker)` | Whether a worker can check in now |
| `bondOf(worker)` | Bond held, including pending withdrawal |
| `bondUnlockEpoch(worker)` | First epoch allowing withdrawal after deregistration; zero if no withdrawal is pending |
| `checkedIn(e, worker)`, `claimed(e, worker)` | Persistent historical participation and consumption flags |
| `claimable(e, worker)` | Floor share for an eligible unclaimed past epoch; zero otherwise |
| `totalBonds()`, `reservedRewards()` | Aggregate accounting liabilities |
| `lastBudgetEpoch()` | Most recent allocated epoch; also zero before the first allocation |

`epochInfo` exposes stored values, not a projected roll. A past epoch can await lazy finalisation. `claimable` still correctly projects the entitlement in this situation. A zero return is ambiguous between no claim and an eligible zero-value claim: check the participation/claimed flags and epoch age if the UI needs to distinguish them. A zero budget's existence is distinguishable from an untouched epoch by its `EpochRolled` event. To preview an unopened epoch's budget, add the last budget's empty-epoch refund or division dust to `pool`, then divide by seven; label the result as an estimate pending the next transaction.

The token's standard `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer` and `transferFrom` are present. Display balances without converting raw units through floating-point numbers.

## Transactions

| Function | Caller requirement / effect |
| --- | --- |
| `register()` | No bond already held; pulls `BOND` after sufficient ERC-20 approval |
| `sponsor(amount)` | Positive amount; pulls an irrevocable gift after sufficient ERC-20 approval |
| `checkIn()` | Registered and not already checked in this epoch |
| `deregister()` | Registered; disables check-in and records next-epoch bond unlock |
| `withdrawBond()` | Deregistered, bond still held, current epoch at least the unlock epoch; pays caller |
| `claim(e)` | Caller checked in to a past epoch and has not claimed; pays caller and returns amount |

All calls send zero ETH and roll the epoch before their own effects. No call accepts a beneficiary or an owner. A failed transaction leaves the stored epoch and all balances unchanged. The frontend should re-read balances, allowance and epoch state after confirmation; simulation and displayed shares can change as other workers check in or time advances.

## Events and errors

`Registered(worker)`, `Deregistered(worker, unlockEpoch)`, `BondWithdrawn(worker, amount)`, `Sponsored(sponsor, amount)`, `CheckedIn(epoch, worker)`, `EpochRolled(epoch, budget)`, and `Claimed(epoch, worker, amount)` are in the application ABI. Worker/sponsor and epoch identity fields are indexed. `EpochRolled` is emitted once per touched epoch, including zero budgets, but never for skipped epochs. Later rolls imply finalisation of the prior touched epoch; there is no separate finalisation event. Token `Transfer` and `Approval` events are standard ERC-20 events.

Discover touched epochs from `EpochRolled` and wallet participation from `CheckedIn`; verify claimability using views. Query logs in bounded block chunks from the deployment block and handle RPC errors/reorgs by refetching. Neither on-chain enumeration nor a backend is required.

Application custom errors distinguish invalid token, zero sponsorship, existing bond, registration requirements, missing/locked bonds, duplicate check-in, non-past claims, absent check-in and duplicate claim. `BondLocked` includes the unlock epoch. Reentrancy and token-transfer errors can also propagate and are included in the exported ABIs where compiler-visible. Failed approvals/balances should be shown as payment failures rather than successful registration or sponsorship.
