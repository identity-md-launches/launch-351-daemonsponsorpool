# Implementer handoff for the independent adversarial review

This is a description of implementation choices and local evidence, **not** an independent review or launch approval. The separate reviewer must inspect the final source and `launch.json` together. No live deployment or signed service artifact exists as part of this contribution.

Local validation on 2026-09-27 used Foundry 1.8.3 and Solidity 0.8.26: `forge build`, `forge test` and `forge fmt --check` passed. The 36 delivered tests include 128 invariant runs of 100 calls each (12,800 calls, no reverts). All eight supplied protected checks also passed, run unchanged in temporary scratch files with process-local constructor bytecode, CREATE2 predictions, supply and network parameters. This emulates the deployment baseline locally; it does not attest a service deployment or approve a future manifest. Both ABI exports match compiler artifacts. Runtime sizes are 1,722 bytes for LaunchToken and 3,960 bytes for DaemonSponsorPool. Forge's build lint emits an event warning for the deregistration assignment even though `Deregistered` is emitted by that path and verified by the event test.

| Attack or edge | Expected result / local evidence |
| --- | --- |
| Sponsor before versus after the first check-in at the same epoch boundary | New gifts are excluded from that epoch in both orders; `test_sponsoringFirstAndCheckingInFirstUseSameSnapshot` compares separate instances |
| Gift just before versus just after the boundary | The earlier gift can be budgeted sooner. Transaction timing and late check-in dilution are accepted economic properties; no fair ordering or verified work is claimed |
| Roll using a reverted action | Failed allowance/transfer/claim reverts the whole roll; `test_failedIncomingPaymentRollsBackCreditAndEpochRoll` and token-interaction tests verify this |
| Return old empty budget or division dust twice | Only the most recently opened epoch finalises, once; empty/dust/idle-gap tests and the independently reconstructed accounting invariant cover the liability movement |
| Spend worker bonds as rewards | Bond balances are excluded from `pool`; `test_bondsAreNeverSponsorshipEvenOnWithdrawalRoll` and the stateful invariant cover this |
| Claim current/future epoch, another worker's share, or the same share twice | Reverts. Historical flags remain after withdrawal and re-registration; zero shares can be consumed only once |
| Release collateral before deregistration's epoch ends | Reverts until `currentEpoch >= bondUnlockEpoch`; tests exercise both sides of the exact boundary |
| One worker blocks other payouts | There is no payout loop. Failure rolls back only that transaction; a second worker can still claim in `test_failedClaimRollsBackAndDoesNotBlockAnotherWorker` |
| Reentrant incoming transfer or double payout | All six mutations are guarded; malicious callbacks attempt all entry points and repeat claims/bond withdrawals as the original worker |
| Leave dust or an empty epoch reserved forever | Recycled before the next snapshot. Skipped epochs allocate nothing, and claims remain accessible even after a million-epoch gap |
| Arbitrary direct token transfer | Not credited: it creates stranded surplus outside the supported approval/payment flows. No rescue function exists; this explicit limitation is in the README. The accounting equality assumes supported flows only |
| Change currency or privileged beneficiary via manifest | Constructor must be exactly this SPON `$token`, with no privileged beneficiary. A code-bearing but hostile token passes the address check, so source/manifest linkage must be reviewed |
| Factory accidentally gains ownership or application consumes initial supply | There is no owner/initializer. The constructor probe checks the full `10^27` remains with the factory and the app starts empty |

Residual assumptions include EVM timestamp ordering, users retaining control of their own worker addresses, plain fixed-supply SPON behavior and accurate service/frontend deployment metadata. Claims have no expiry or sweeping authority, so lost keys leave those liabilities reserved; this preserves other workers' entitlement. SPON amounts below seven minor units can remain in the sponsorship pool until additional gifts arrive. Per-epoch storage grows with activity, but every mutation has constant work independent of participant count and idle duration.

The services own publication, policy selection, attestation, admission and deployment. Missing future service signatures or a future website are not constructor or authorization defects. A concrete mismatch between final manifest arguments and the accepted source is a review finding. No claims about source admission, actual launch policy enforcement or production security follow from the local tests.
