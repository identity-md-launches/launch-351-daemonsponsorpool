# Sponsor (SPON)

A Sepolia-only sponsorship toy modelled on worker daemons. It does not verify work or connect to real IdentityMD payments. This contribution supplies the contracts, tests, vendored dependencies and ABI exports. The separate manifest, independent review, service deployment and live website stages follow this source contribution.

## Build and test

Foundry and Solidity **0.8.26** are required. `foundry.toml` pins the compiler, Cancun EVM, optimizer (200 runs) and `bytecode_hash = "none"`. Dependencies are ordinary files under `lib/`; no package install, submodule, network, environment variables, RPC, FFI or filesystem cheatcode permissions are needed by the delivered tests. The offline verifier supplies the pinned compiler.

```sh
forge build
forge test
forge fmt --check
```

The tests cover epoch boundaries, snapshot ordering, empty budgets, division dust, idle gaps, claim replay, registration and bond locks, failed transfers, reentrant callbacks, deployment and runtime restrictions. The stateful invariant mixes all six mutations with time advances and independently reconstructs unclaimed rewards and bonds across four workers. It also checks lifetime gift/payout conservation and total token supply. Hostile token mocks test defensive behavior; only SPON is a supported deployment currency.

Regenerate the checked-in ABI arrays after any ABI change:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/DaemonSponsorPool.sol:DaemonSponsorPool abi --json > docs/abi/DaemonSponsorPool.json
```

## Contracts and factory parameters

| Item | Value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Token | `src/LaunchToken.sol:LaunchToken` |
| Name / symbol / decimals | Sponsor / SPON / 18 |
| Fixed supply | `1000000000000000000000000000` minor units = 1,000,000,000 SPON |
| Token constructor | No arguments; nonpayable; entire supply minted to `msg.sender` (the factory) |
| Application | `src/DaemonSponsorPool.sol:DaemonSponsorPool` |
| Application identifier | `DaemonSponsorPool` |
| Application constructor | One `address token_`, nonpayable; manifest arguments `["$token"]` |
| Required deployment balance | Zero ETH and zero SPON for the application |
| Bond | `100000000000000000000000` minor units = 100,000 SPON |
| Epoch duration | 86,400 seconds, starting at the application's deployment timestamp |
| Administrators / initialization | None; constructor fully configures the application |
| Site label for subsequent frontend | `lab-daemon-sponsor` |

Deploy the token before the application through ProjectFactory. Its constructor accepts a deployed contract address and rejects zero/EOA addresses; it does **not** authenticate arbitrary token bytecode. The manifest reviewer and deployment service must resolve `$token` to this exact LaunchToken. There is no hard-coded privileged wallet or use of the application's deployer as an owner. The contracts do not enforce a chain ID themselves; the launch service and frontend must enforce Sepolia.

The token has no mint entry point, owner, fee, pause, blocklist, upgrade or burn function. A holder wishing to discard SPON can transfer it to `0x000000000000000000000000000000000000dEaD`; this is an ordinary transfer and leaves `totalSupply` unchanged. The application does not burn or slash any funds.

## Worker and sponsor lifecycle

1. Obtain SPON by swapping Sepolia ETH in the factory-seeded ETH/SPON launch pool. The application needs no initial allocation from the factory, rewards or developer wallet.
2. Approve the application for 100,000 SPON and call `register()`. The address cannot register while it already has a bond, including a bond awaiting withdrawal. A bond is locked collateral, never sponsorship or a reward budget.
3. Call `checkIn()` once per epoch while registered. Registration alone earns nothing. All checked-in addresses in an epoch receive equal shares; there is no verification of daemon activity.
4. Anyone may approve a positive amount and call `sponsor(amount)`. This is an irrevocable gift to future budgets; it cannot be withdrawn by the sponsor.
5. After an epoch ends, call `claim(epoch)` from the address that checked in. Claims never expire, cannot be delegated and do not require ongoing registration. Each epoch can be claimed once, including a zero-valued share.
6. `deregister()` immediately stops check-ins. It preserves existing claims and locks the bond until the end of the epoch in which deregistration occurred. At that next boundary, call `withdrawBond()` from the same address. The address can register again after withdrawal.

For example, deregistration one second before a boundary permits withdrawal one second later; deregistration exactly on that boundary requires waiting until the following boundary. The bond requirement makes Sybil payouts bond-weighted at best. It is not one-person-one-worker, and does not impose a minimum 24-hour registration period.

## Epoch accounting and ordering

`currentEpoch() = (block.timestamp - genesis) / 1 days`. Every successful state-changing application call first rolls to that epoch. Failed calls revert the roll along with all other effects. Views never roll.

When opening a new epoch, the application finalises only the last epoch that actually received a budget. If that old epoch had no check-ins, its entire budget returns to `pool`. Otherwise, each participant's entitlement is `budget / checkIns`, rounded down in minor units; only `budget % checkIns` returns to `pool`. Unclaimed shares remain reserved forever. The new epoch then reserves `floor(pool / 7)`. There is no loop over skipped epochs or participants.

The snapshot occurs **before** the action's own effects. A sponsorship that is the first action of an epoch does not enlarge that epoch's budget. The first ever action normally creates a zero budget because the application starts empty. Sponsoring first or checking in first gives the same budget when the prior state and timestamp are equal. A gift before the boundary can affect the following epoch; the same gift after the boundary affects a later touched epoch. Users can choose transaction timing, and check-ins can dilute shares until the boundary. These are explicit economic rules, not a guaranteed daily return.

Example in minor units: gift 70 in epoch 0, then three workers check in during epoch 1. Its budget is 10 and each earns 3. On the next roll, 1 dust returns to the available 60; the new budget is `61 / 7 = 8`, leaving `pool = 53`. The old 9 remains reserved until claimed. If no one had checked in, all 10 would have returned instead. An idle gap creates no intermediate budgets and destroys no balances.

After each supported transaction:

```text
SPON.balanceOf(application) = pool + reservedRewards + totalBonds
reservedRewards = all unpaid finalised shares + the latest unfinalised budget
```

Pending withdrawal bonds are included in `totalBonds`. The latest budget remains unfinalised until a subsequent successful mutation, even if wall-clock time has advanced. This is why `epochInfo(e).finalised` may be false for a past epoch while `claimable(e, worker)` already reports its share.

All incoming payments use approval plus `SafeERC20.safeTransferFrom`. All outgoing payments are caller-initiated `safeTransfer` withdrawals with effects before interaction and `nonReentrant`. Transfer failure reverts credits, claims, bond releases and any attempted epoch roll atomically. One worker never has to receive payment for another worker's claim to proceed.

**Transfer assumptions:** SPON has no fee, rebasing or token callbacks, so the nominal amount received equals the credited amount. Only `register` and `sponsor` are supported payment entrances. A raw ERC-20 transfer to the application bypasses accounting and becomes stranded surplus; there is no rescue authority. In that case the balance is the accounted liabilities **plus** that unsolicited surplus. Do not transfer SPON directly. Other tokens are likewise unsupported and unrecoverable. Ordinary ETH sends and payable calls revert because there is no payable function, receive or fallback; EVM-forced ETH remains possible and has no withdrawal path.

## Stage handoff and responsibilities

The generated-manifest assignment owns `launch.json`; this contribution intentionally does not create one. It must identify LaunchToken and the one application above, with the exact constructor reference. Policy IDs, owner policy, source publication, signed artifact linkage, admission, factory execution and transaction recording belong to the services. No contributor deployment transaction, wallet key, or broadcast script is needed here.

The subsequent independent contributor must review the accepted source **and** the finished manifest. Passing tests and the local deployment probe do not substitute for that review. [Review notes](docs/review-handoff.md) identify concrete adversarial cases and limitations; they are the implementer's handoff, not an independent approval.

After service deployment, record both addresses and the application deployment block. The frontend stage builds the small static page with `dist/index.html`, reads SPON from `token()`, enforces Sepolia, displays balance/allowance, offers approval before register/sponsor, and supports check-in, claims, deregistration and bond withdrawal. It derives history from views and events with chunked logs starting at the recorded deployment block, and explains that SPON is acquired by an external ETH/SPON swap. The epoch countdown uses `genesis + (currentEpoch + 1) * EPOCH_DURATION`; see the [ABI guide](docs/abi/README.md) for lazy-view semantics. No backend, indexer, keeper, oracle or randomness is required. GitHub/IPFS publication and frontend operations are later service responsibilities.

Dependency provenance and licenses are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).
