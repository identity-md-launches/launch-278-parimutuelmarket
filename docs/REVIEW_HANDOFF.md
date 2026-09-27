# Adversarial review handoff

This is an implementation author's test map, **not an independent review or audit**. The separate reviewer must inspect the accepted sources and concrete `launch.json`. The source assignment does not create that manifest or assert later deployment/service outcomes.

| Attack or failure | Delivered coverage |
| --- | --- |
| Round multiple winning claims upward or change denominators after a claim | Floor-payout fuzzing, explicit one-unit dust case, claims in either order, independent stateful ledger and final drain |
| Spend another market's deposits or donations | Two simultaneous markets with donations/dust; randomized creation, betting, settlement, refunds, donations and claims; per-market `paidOut <= pool` and global balance checks |
| Resolver resolves early, twice, or late | Non-resolver rejection, before-close rejection, last eligible second, exact deadline, after-deadline rejection, repeated resolution rejection |
| Void races resolution at close plus seven days | Void rejected at deadline minus one; successful resolution cannot later be voided; resolution rejected at deadline; void then resolution rejected |
| Winning side is empty | Both YES and NO empty-winner cases, completely empty market, one-sided winner and one-sided refund |
| Reenter `claim` before/after transfer or claim another market | Token callback with claimant identity; same-market and cross-market attempts hit the guard; hook observes claimed flag, zero claimable, and updated paidOut before payment |
| Reenter a deposit from token code | TransferFrom callback attempts nested bet and is rejected; only the outer stake is recorded |
| Token lies, returns nothing, or refuses payment | False-returning deposit/payout rollback; short deposit rollback; optional-return transfers; failed payout retry and another claimant's unaffected payout |
| Claim for a loser, non-bettor, twice, or before settlement | Explicit failure tests; combined-side INVALID/void refunds; caller-only claim API |
| Factory deploys without a prefunded application or assigns itself control | CREATE2 harness, sole token constructor argument, no initialization calls, full supply stays at factory, permissionless application creation |
| Runtime proxy/escape instructions or excess size | PUSH-aware runtime opcode scan and EIP-170 bounds for both contracts |

The stateful handler maintains its own stake, outcome, and payout records and recomputes expected entitlements without calling the application's payout helper. Pending markets reserve all principal. Settled markets reserve the sum of remaining floor payouts or exact refunds. At the end of every invariant sequence, the handler voids any pending market and collects every entitlement, checking only bounded dust plus direct donations remain. Test-only token minting/configuration helpers are not in the production source artifacts.

Assumptions the independent review should preserve: an immutable genuine ODMK token, deliberate human resolution with possible alternate-address betting, immutable close times, no administrator or recovery powers, no claims on unsolicited donations or rounding dust, and Sepolia-only operational deployment. A token code-presence check is not token authentication. No test proves a resolver honest, secures a later manifest or frontend, validates factory/pool policy, or simulates a deployed network's timing and reorganizations. Policy and signed-artifact linkage are service responsibilities; concrete source, constructor, policy, or authorization conflicts remain reviewer findings.
