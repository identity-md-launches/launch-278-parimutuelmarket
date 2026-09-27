// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fee-free yes/no Sepolia test markets settled by each market's named human resolver.
/// @dev The immutable token must be the fixed-supply ODMK launch token. No ETH entry points or admin powers.
contract ParimutuelMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Outcome {
        UNRESOLVED,
        YES,
        NO,
        INVALID
    }

    struct Market {
        bytes32 question;
        uint256 closeTime;
        address resolver;
        uint256 yesPool;
        uint256 noPool;
        Outcome outcome;
        uint256 paidOut;
    }

    struct Position {
        uint256 yes;
        uint256 no;
        bool claimed;
    }

    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 90 days;
    uint256 public constant RESOLUTION_WINDOW = 7 days;
    uint256 public constant ODDS_SCALE = 10_000;

    IERC20 public immutable token;
    uint256 public marketCount;

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(address => Position)) private _positions;

    error InvalidToken();
    error InvalidResolver();
    error InvalidCloseTime();
    error UnknownMarket();
    error MarketClosed();
    error ResolverCannotBet();
    error ZeroAmount();
    error UnexpectedTransferAmount();
    error NotResolver();
    error AlreadySettled();
    error ResolutionNotOpen();
    error InvalidOutcome();
    error VoidNotOpen();
    error NotSettled();
    error AlreadyClaimed();
    error NothingToClaim();

    event Created(
        uint256 indexed id, address indexed creator, bytes32 question, uint256 closeTime, address indexed resolver
    );
    event Bet(uint256 indexed id, address indexed bettor, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, Outcome outcome);
    event Voided(uint256 indexed id);
    event Claimed(uint256 indexed id, address indexed bettor, uint256 amount);

    /// @param token_ The deployed ODMK address (manifest constructorArgs: ["$token"]).
    constructor(address token_) {
        if (token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @notice Create a market with inclusive duration bounds. IDs start at zero.
    /// @dev The question is a bytes32 label or content hash; resolver interpretation is a trust assumption.
    function createMarket(bytes32 question, uint256 closeTime, address resolver)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (resolver == address(0)) revert InvalidResolver();
        if (closeTime < block.timestamp + MIN_DURATION || closeTime > block.timestamp + MAX_DURATION) {
            revert InvalidCloseTime();
        }
        id = marketCount++;
        Market storage m = _markets[id];
        m.question = question;
        m.closeTime = closeTime;
        m.resolver = resolver;
        emit Created(id, msg.sender, question, closeTime, resolver);
    }

    /// @notice Add an approved ODMK stake. Repeat bets and betting on both sides are allowed.
    function bet(uint256 id, bool yes, uint256 amount) external nonReentrant {
        Market storage m = _getMarket(id);
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (msg.sender == m.resolver) revert ResolverCannotBet();
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBalance = token.balanceOf(address(this));
        Position storage p = _positions[id][msg.sender];
        if (yes) {
            p.yes += amount;
            m.yesPool += amount;
        } else {
            p.no += amount;
            m.noPool += amount;
        }
        token.safeTransferFrom(msg.sender, address(this), amount);
        // ODMK transfers exact amounts. Reject a misconfigured fee-on-transfer currency atomically.
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedTransferAmount();
        emit Bet(id, msg.sender, yes, amount);
    }

    /// @notice Resolve once in [closeTime, closeTime + 7 days). An empty winning side becomes INVALID.
    function resolve(uint256 id, Outcome outcome) external nonReentrant {
        Market storage m = _getMarket(id);
        if (msg.sender != m.resolver) revert NotResolver();
        if (m.outcome != Outcome.UNRESOLVED) revert AlreadySettled();
        if (block.timestamp < m.closeTime || block.timestamp >= m.closeTime + RESOLUTION_WINDOW) {
            revert ResolutionNotOpen();
        }
        if (outcome == Outcome.UNRESOLVED) revert InvalidOutcome();
        if ((outcome == Outcome.YES && m.yesPool == 0) || (outcome == Outcome.NO && m.noPool == 0)) {
            outcome = Outcome.INVALID;
        }
        m.outcome = outcome;
        emit Resolved(id, outcome);
    }

    /// @notice Anyone may unlock refunds for an unresolved market at or after closeTime + 7 days.
    function voidMarket(uint256 id) external nonReentrant {
        Market storage m = _getMarket(id);
        if (m.outcome != Outcome.UNRESOLVED) revert AlreadySettled();
        if (block.timestamp < m.closeTime + RESOLUTION_WINDOW) revert VoidNotOpen();
        m.outcome = Outcome.INVALID;
        emit Voided(id);
    }

    /// @notice Collect only the caller's payout or refund, once. Failed transfers leave the claim retryable.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        Market storage m = _getMarket(id);
        if (m.outcome == Outcome.UNRESOLVED) revert NotSettled();
        Position storage p = _positions[id][msg.sender];
        if (p.claimed) revert AlreadyClaimed();
        amount = _entitlement(m, p);
        if (amount == 0) revert NothingToClaim();

        p.claimed = true;
        m.paidOut += amount;
        emit Claimed(id, msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    function market(uint256 id) external view returns (Market memory) {
        return _getMarket(id);
    }

    /// @notice Historical deposited stake; claiming does not clear it.
    function stakeOf(uint256 id, address account, bool yes) external view returns (uint256) {
        _getMarket(id);
        Position storage p = _positions[id][account];
        return yes ? p.yes : p.no;
    }

    /// @notice Pool shares in basis points, summing to 10,000; an empty market returns (5,000, 5,000).
    /// @dev YES rounds down, NO is the complement. These are indicative pool shares, not an oracle or price.
    function impliedOdds(uint256 id) external view returns (uint256 yesBps, uint256 noBps) {
        Market storage m = _getMarket(id);
        uint256 pool = m.yesPool + m.noPool;
        if (pool == 0) return (ODDS_SCALE / 2, ODDS_SCALE / 2);
        yesBps = Math.mulDiv(m.yesPool, ODDS_SCALE, pool);
        noBps = ODDS_SCALE - yesBps;
    }

    /// @notice Amount collectable now; zero before settlement, after claim, or for a losing/non-bettor account.
    function claimable(uint256 id, address account) external view returns (uint256) {
        Market storage m = _getMarket(id);
        Position storage p = _positions[id][account];
        return p.claimed ? 0 : _entitlement(m, p);
    }

    function hasClaimed(uint256 id, address account) external view returns (bool) {
        _getMarket(id);
        return _positions[id][account].claimed;
    }

    function _getMarket(uint256 id) private view returns (Market storage m) {
        if (id >= marketCount) revert UnknownMarket();
        m = _markets[id];
    }

    function _entitlement(Market storage m, Position storage p) private view returns (uint256) {
        if (m.outcome == Outcome.INVALID) return p.yes + p.no;
        if (m.outcome == Outcome.YES) return Math.mulDiv(p.yes, m.yesPool + m.noPool, m.yesPool);
        if (m.outcome == Outcome.NO) return Math.mulDiv(p.no, m.yesPool + m.noPool, m.noPool);
        return 0;
    }
}
