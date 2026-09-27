# Contract ABI

The JSON files under `docs/abi/` are plain ABI arrays generated from Solidity 0.8.26 artifacts:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/ParimutuelMarket.sol:ParimutuelMarket abi --json > docs/abi/ParimutuelMarket.json
```

All amounts are ODMK base units (18 decimals). All times are Unix seconds. Every application state-changing function and both constructors are nonpayable. No application action accepts an arbitrary payout recipient.

## LaunchToken

Constructor: no arguments. Standard ERC-20 functions: `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`, `transfer(address,uint256)`, `transferFrom(address,address,uint256)`. Events: `Transfer` and `Approval`. The ABI includes standard ERC-6093 errors. There are no administrative or mint functions.

## ParimutuelMarket

Constructor: `constructor(address token_)`. The JSON ABI represents the immutable `IERC20` getter as an `address` and `Outcome` as `uint8`.

| Outcome encoding | Meaning |
| --- | --- |
| 0 | UNRESOLVED (not a valid argument to `resolve`) |
| 1 | YES |
| 2 | NO |
| 3 | INVALID, including timeout voids |

| Method | Return or behavior |
| --- | --- |
| `createMarket(bytes32 question,uint256 closeTime,address resolver)` | Returns the zero-based `uint256 id` |
| `bet(uint256 id,bool yes,uint256 amount)` | `yes=true` is YES; pulls approved ODMK from caller |
| `resolve(uint256 id,uint8 outcome)` | Resolver sets a final outcome; an empty winner is normalized to INVALID |
| `voidMarket(uint256 id)` | Anyone sets an unresolved expired market to INVALID |
| `claim(uint256 id)` | Returns `uint256 amount` paid to the caller |
| `market(uint256 id)` | Returns the tuple described below |
| `marketCount()` | Number of created markets; enumerate IDs in `[0, count)` |
| `stakeOf(uint256 id,address account,bool yes)` | Historical deposited stake on that side |
| `impliedOdds(uint256 id)` | `(uint256 yesBps,uint256 noBps)`; scale 10,000; empty market = 5,000 / 5,000 |
| `token()` | Immutable ODMK address |
| `claimable(uint256 id,address account)` | Currently collectable amount; zero before settlement, after a claim, or for losers/non-bettors |
| `hasClaimed(uint256 id,address account)` | Whether the account already successfully collected |
| `MIN_DURATION()`, `MAX_DURATION()`, `RESOLUTION_WINDOW()`, `ODDS_SCALE()` | Constants: 3,600; 7,776,000; 604,800; 10,000 |

`market(id)` returns one tuple, in this exact component order:

1. `bytes32 question`
2. `uint256 closeTime`
3. `address resolver`
4. `uint256 yesPool`
5. `uint256 noPool`
6. `uint8 outcome`
7. `uint256 paidOut`

Pools do not shrink after payouts. A frontend distinguishes open, awaiting resolver, and timeout-eligible states using outcome 0 plus block time and `closeTime`; a timeout-eligible market remains unresolved until `voidMarket` succeeds. Outcome 3 covers both resolver invalidation and timeout voiding; the event identifies which occurred. Submitted transactions can fail if their eligibility changes before inclusion.

| Event | Indexed fields | Other fields |
| --- | --- | --- |
| `Created` | `uint256 id`, `address creator`, `address resolver` | `bytes32 question`, `uint256 closeTime` (argument order: id, creator, question, closeTime, resolver) |
| `Bet` | `uint256 id`, `address bettor` | `bool yes`, `uint256 amount` |
| `Resolved` | `uint256 id` | `uint8 outcome` (effective, normalized outcome) |
| `Voided` | `uint256 id` | None |
| `Claimed` | `uint256 id`, `address bettor` | `uint256 amount` |

No `Resolved` event accompanies `Voided`; clients handle both. There is no pagination dependency: query `marketCount`, then individual `market` views, optionally supplemented by bounded RPC log queries and refreshed views after confirmations. Frontends must account for reorganizations and RPC log limits.

Custom errors distinguish bad configuration (`InvalidToken`, `InvalidResolver`, `InvalidCloseTime`), bad market IDs (`UnknownMarket`), bet failures (`MarketClosed`, `ResolverCannotBet`, `ZeroAmount`, `UnexpectedTransferAmount`), settlement failures (`NotResolver`, `AlreadySettled`, `ResolutionNotOpen`, `InvalidOutcome`, `VoidNotOpen`), and claim failures (`NotSettled`, `AlreadyClaimed`, `NothingToClaim`). `ReentrancyGuardReentrantCall` and `SafeERC20FailedOperation(address)` are included. Underlying token errors can bubble through even when absent from the application ABI. A value outside the enum range fails Solidity ABI decoding before the function body.
