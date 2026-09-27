# Oddsmaker contracts

Oddsmaker (ODMK) powers **Sepolia test markets with no real value**. This repository delivers the launch token, the `ParimutuelMarket` application, Foundry tests, and exported ABIs. Target network: Sepolia, chain ID **11155111**.

**The named resolver decides the outcome. There is no oracle, appeal, or adjudication mechanism. The resolver cannot bet from its resolver address, but could bet through another address.** Market creators choose their resolver; users must assess that resolver and agree on what the question means before betting.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimization with 200 runs, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary vendored files under `lib/`; see [dependency provenance](docs/DEPENDENCIES.md). With Foundry and the pinned compiler installed, builds need no network. FFI and filesystem cheatcode permissions are disabled. Tests read no environment variables and do not broadcast transactions.

The suite includes success/failure cases, fuzzed payouts, malicious token callbacks, failed and false-returning transfers, factory-style CREATE2 deployment, runtime size/opcode checks, and a stateful ledger invariant (128 runs, 64 actions per run). That invariant checks each market's accounting, total payouts versus deposits, and ODMK held against all unclaimed entitlements and unresolved principal. Its finalization hook settles or voids every market and claims all entitlements, leaving only dust and donations. See the [review handoff](docs/REVIEW_HANDOFF.md) for attack cases and review limits.

## Deployment parameters

| Artifact | Constructor arguments | Result |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | Name `Oddsmaker`, symbol `ODMK`, 18 decimals, exactly `1000000000000000000000000000` base units minted once to the constructor caller |
| `src/ParimutuelMarket.sol:ParimutuelMarket` | One `address token_`, manifest reference `"$token"` | Immutable `token()`; no app token balance needed at deployment |

The token is a separate fixed-supply ERC-20. There is no external mint, burn, fee, owner, pause, blocklist, or upgrade function. Ordinary allowance-based transfers and unlimited allowances follow the vendored OpenZeppelin ERC-20 implementation.

The application has a nonpayable constructor and requires a token address containing deployed code. **That check does not authenticate the currency**: the manifest and deployment review must link it to this launch's `LaunchToken`. Only this exact-transfer, non-rebasing ODMK is the supported working currency. Inbound balance-delta checks reject short transfers; they do not make arbitrary malicious currencies safe.

For the separate manifest assignment: use launch token `LaunchToken` and exactly one application identifier, `ParimutuelMarket`, with `constructorArgs: ["$token"]`, under kind `evm_project`. There is no `$owner`, privileged constructor wallet, application dependency, payable constructor value, prefunding, or post-deployment initialization. Deploy the token before the application through the project factory. The factory is the token's constructor caller and retains the whole supply throughout application construction; services then apply the approved LP/reward allocation. Neither contract grants the factory an application role. There is no chain-ID restriction in the bytecode; deployment services and the eventual frontend must select Sepolia only.

This source assignment does not create `launch.json`, deploy, access wallet keys, publish a website, or claim an independent security review. The manifest contributor describes accepted source; an independent reviewer checks source and the concrete manifest together. Policy and signed-artifact linkage belong to services. Services publish source, attest, admit, and deploy after this stage, then start frontend work. Those later outcomes are not prerequisites for using or checking these delivered sources.

## Market behavior

- Anyone creates a market using a `bytes32 question`, `closeTime`, and nonzero `resolver`. Close time is inclusively between creation time plus 1 hour and plus 90 days. IDs start at 0 and increment monotonically; unknown IDs revert in all market views and actions. Creation requires no payment. A question can be a short UTF-8 label of at most 32 bytes (recommended for a standalone listing) or a content hash whose meaning participants establish separately; the contract does not interpret or validate the question.
- Bettors obtain ODMK by swapping Sepolia ETH in the launch pool seeded by the factory. This application does not perform swaps or distribute tokens. Before a bet, the caller approves the market to spend ODMK, then calls `bet(id, yes, amount)`. Every deposit uses `SafeERC20.safeTransferFrom`. Amount must be positive and the call must arrive strictly before `closeTime`. The resolver address cannot bet. Repeat bets and bets on both sides aggregate per account; ledger positions cannot be transferred or withdrawn before settlement.
- At exactly `closeTime`, betting stops and the resolver may call `resolve`. The resolution interval is **[closeTime, closeTime + 7 days)**. Choices are YES, NO, or INVALID. Resolution is final and can happen only once. If the chosen winning side has no stake, the effective outcome is INVALID (including a completely empty market).
- At or after `closeTime + 7 days`, resolution is rejected. Anyone may call `voidMarket` if still unresolved, setting INVALID. This explicit transaction is required before refunds can be claimed. There is no keeper requirement; users can send it themselves. At the boundary, resolution and voiding have non-overlapping eligibility. Already resolved markets cannot be voided, even after the window ends.
- After YES/NO, each winning account claims `floor(winningStake * (yesPool + noPool) / winningPool)` once. Full-precision `mulDiv` prevents intermediate multiplication overflow. A bettor on both sides receives the payout for its winning stake only. Losing accounts and accounts with no stake cannot claim. After INVALID (including void), each bettor claims its combined YES and NO stakes once.
- `claim(id)` pays only `msg.sender`, requires no approval, and has no expiry. Effects are recorded before `SafeERC20.safeTransfer`; a failed transfer rolls back those effects so the claim is retryable. Claims and all other mutating application methods are `nonReentrant`. Settlement itself performs no transfers, and one failed payout does not block other claimants.
- There are no fees. Claims use the original market pools, never the contract's shared token balance. Donations and other markets cannot change a payout. Pools and stakes remain visible as historical totals after claims; `paidOut`, `claimable`, and `hasClaimed` expose collection state.

For N winning accounts, summing the floor payouts cannot exceed the pool. Rounding leaves **at most 1 base unit per winner** in the contract (strictly less than N base units in total). Dust, unsolicited ODMK, and other accidentally transferred assets have no sweep or recovery path. Invalid-market refunds have no rounding loss. These are intentional consequences of having no owner or administrative withdrawal.

`impliedOdds` returns YES and NO pool shares in basis points (10,000 = 100%). YES rounds down; NO is the complement. An empty pool returns (5,000, 5,000). These values describe deposited stakes, not oracle probabilities or guaranteed payouts, and remain available after settlement.

The application has no payable methods and no receive/fallback. Ordinary ETH sends fail; ETH is never part of its accounting. EVM mechanisms can still force ETH into an address, so no implementation can promise that its raw ETH balance is always zero. Forced ETH is unrecoverable here.

## Operational and frontend handoff

- Market creators must choose an intelligible question, deadline, and available resolver. A nonzero resolver can still be unable or unwilling to act; the seven-day timeout is the recovery path. Block inclusion determines deadline eligibility, so callers should not rely on last-second submissions.
- Resolvers submit one human decision during the resolution window. Bettors accept that trust model; another address can hide a resolver's financial interest. No privileged operator can override an outcome, reset a claim, extend a deadline, pause, or recover funds.
- Independent reviewers examine the concrete token link, permissionless creation, resolver authority, settlement and timeout races, conservation across markets, and transfer callbacks before release. The tests are authored implementation checks, not an independent audit.
- Deployment services own factory deployment, policy allocation, publication, attestation, admission, and verification of deployed source/constructor arguments. Do not deploy these artifacts as a proxy or add initialization calls.
- The later one-page frontend (`lab-prediction-market`, static `dist/index.html`) must read `token()` for the currency, show connected-wallet balance and allowance, and provide an explicit Approve step before bets. Show amounts with 18 decimals and distinguish approval from the bet transaction. List markets with views/events only; no backend or indexer. Allow create, bet, resolver-only resolve, permissionless timeout void, and self-claim actions with the documented boundary rules. Label them “Sepolia test markets with no real value,” repeat the resolver warning above, and explain that ODMK comes from swapping Sepolia ETH in the launch pool; no in-page swap. The frontend is built against the subsequent live deployment.

See [ABI documentation](docs/ABI.md), [LaunchToken ABI](docs/abi/LaunchToken.json), and [ParimutuelMarket ABI](docs/abi/ParimutuelMarket.json).
