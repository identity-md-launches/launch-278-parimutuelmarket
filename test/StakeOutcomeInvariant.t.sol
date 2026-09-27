// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ParimutuelMarket} from "../src/ParimutuelMarket.sol";

/// @dev Stateful handler that stakes on both sides from the same accounts, drives every outcome (YES, NO,
/// INVALID, empty-winner-forced INVALID, timeout void) and predicts the exact revert of every refused call.
/// Each market has its own resolver so resolver authority is checked across markets. No donations are made,
/// so the contract's ODMK balance must equal staked minus claimed exactly.
contract StakeOutcomeHandler is Test {
    struct Position {
        uint256 yes;
        uint256 no;
        bool claimed;
    }

    LaunchToken public immutable token;
    ParimutuelMarket public immutable app;

    uint256 public constant BETTORS = 6;
    /// @dev Index BETTORS is an account that holds ODMK and approval but never bets.
    uint256 public constant ACCOUNTS = BETTORS + 1;
    uint256 public constant RESOLVERS = 3;
    uint256 public constant MAX_MARKETS = 8;

    uint256 public count;
    uint256 public totalStaked;
    uint256 public totalClaimed;
    mapping(uint256 => uint256) public closeOf;
    mapping(uint256 => address) public resolverOf;
    mapping(uint256 => uint256) public yesPool;
    mapping(uint256 => uint256) public noPool;
    mapping(uint256 => uint256) public claimedOf;
    mapping(uint256 => ParimutuelMarket.Outcome) public outcomeOf;
    mapping(uint256 => mapping(uint256 => Position)) private _positions;

    constructor(LaunchToken token_, ParimutuelMarket app_) {
        token = token_;
        app = app_;
        for (uint256 i; i < ACCOUNTS; ++i) {
            vm.prank(account(i));
            token.approve(address(app), type(uint256).max);
        }
        for (uint256 i; i < RESOLVERS; ++i) {
            vm.prank(resolverAt(i));
            token.approve(address(app), type(uint256).max);
        }
        create(0, 0);
        create(3 days, 1);
        create(60 days, 2);
    }

    function account(uint256 i) public pure returns (address) {
        return address(uint160(0xB000 + i));
    }

    function resolverAt(uint256 i) public pure returns (address) {
        return address(uint160(0xE000 + i));
    }

    function position(uint256 id, uint256 i) external view returns (Position memory) {
        return _positions[id][i];
    }

    function staked(uint256 id) public view returns (uint256) {
        return yesPool[id] + noPool[id];
    }

    // ---------------------------------------------------------------- creation

    function create(uint256 durationSeed, uint256 resolverSeed) public {
        if (count == MAX_MARKETS) return;
        uint256 closeTime = vm.getBlockTimestamp() + bound(durationSeed, 1 hours, 90 days);
        address resolver = resolverAt(resolverSeed % RESOLVERS);
        uint256 id = app.createMarket(bytes32(count + 100), closeTime, resolver);
        assertEq(id, count, "market ids must be sequential");
        closeOf[id] = closeTime;
        resolverOf[id] = resolver;
        ++count;
    }

    function createRefused(uint256 seed) external {
        uint256 kind = seed % 3;
        uint256 now_ = vm.getBlockTimestamp();
        if (kind == 0) {
            vm.expectRevert(ParimutuelMarket.InvalidCloseTime.selector);
            app.createMarket(bytes32("short"), now_ + bound(seed >> 2, 0, 1 hours - 1), resolverAt(0));
        } else if (kind == 1) {
            vm.expectRevert(ParimutuelMarket.InvalidCloseTime.selector);
            app.createMarket(bytes32("long"), now_ + bound(seed >> 2, 90 days + 1, 3650 days), resolverAt(0));
        } else {
            vm.expectRevert(ParimutuelMarket.InvalidResolver.selector);
            app.createMarket(bytes32("nobody"), now_ + 1 days, address(0));
        }
    }

    // ---------------------------------------------------------------- staking

    /// @dev Mixes dust-sized, ordinary and very large stakes so floor division has something to bite on.
    function _amount(uint256 seed, uint256 available) internal view returns (uint256) {
        uint256 mode = seed % 4;
        uint256 cap = mode == 0 ? 3 : mode == 1 ? 1 ether : mode == 2 ? 1_000_000 ether : available / 4 + 1;
        if (cap > available) cap = available;
        return bound(seed >> 2, 1, cap);
    }

    function placeBet(uint256 marketSeed, uint256 bettorSeed, bool yes, uint256 amountSeed) public {
        uint256 id = marketSeed % count;
        uint256 i = bettorSeed % BETTORS;
        address a = account(i);
        uint256 available = token.balanceOf(a);
        if (available == 0) return;
        uint256 amount = _amount(amountSeed, available);

        if (vm.getBlockTimestamp() >= closeOf[id]) {
            vm.prank(a);
            vm.expectRevert(ParimutuelMarket.MarketClosed.selector);
            app.bet(id, yes, amount);
            return;
        }

        vm.expectEmit(true, true, false, true, address(app));
        emit ParimutuelMarket.Bet(id, a, yes, amount);
        vm.prank(a);
        app.bet(id, yes, amount);

        if (yes) {
            _positions[id][i].yes += amount;
            yesPool[id] += amount;
        } else {
            _positions[id][i].no += amount;
            noPool[id] += amount;
        }
        totalStaked += amount;
    }

    /// @dev The same account hedges on both sides of one market.
    function betBothSides(uint256 marketSeed, uint256 bettorSeed, uint256 yesSeed, uint256 noSeed) external {
        placeBet(marketSeed, bettorSeed, true, yesSeed);
        placeBet(marketSeed, bettorSeed, false, noSeed);
    }

    function betRefused(uint256 marketSeed, uint256 kind, bool yes) external {
        uint256 id = marketSeed % count;
        bool closed = vm.getBlockTimestamp() >= closeOf[id];
        kind %= 3;
        if (kind == 0) {
            // The market's own resolver, funded and approved, must never be able to stake.
            vm.prank(resolverOf[id]);
            vm.expectRevert(
                closed ? ParimutuelMarket.MarketClosed.selector : ParimutuelMarket.ResolverCannotBet.selector
            );
            app.bet(id, yes, 1);
        } else if (kind == 1) {
            vm.prank(account(marketSeed % BETTORS));
            vm.expectRevert(closed ? ParimutuelMarket.MarketClosed.selector : ParimutuelMarket.ZeroAmount.selector);
            app.bet(id, yes, 0);
        } else {
            vm.prank(account(marketSeed % BETTORS));
            vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
            app.bet(count + marketSeed % 3, yes, 1);
        }
    }

    // ---------------------------------------------------------------- time

    function advanceTime(uint256 secondsForward) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 3 days));
    }

    /// @dev Jump (forward only) to one of the four boundary instants of a market.
    function warpToBoundary(uint256 marketSeed, uint256 which) external {
        uint256 id = marketSeed % count;
        uint256 c = closeOf[id];
        uint256[4] memory targets = [c - 1, c, c + 7 days - 1, c + 7 days];
        uint256 target = targets[which % 4];
        if (target > vm.getBlockTimestamp()) vm.warp(target);
    }

    // ---------------------------------------------------------------- settlement

    function resolve(uint256 marketSeed, uint256 outcomeSeed, uint256 callerSeed, bool jumpToClose) external {
        uint256 id = marketSeed % count;
        if (jumpToClose && vm.getBlockTimestamp() < closeOf[id]) vm.warp(closeOf[id]);

        address caller;
        uint256 callerKind = callerSeed % 4;
        if (callerKind == 0) caller = account(callerSeed % ACCOUNTS);
        else if (callerKind == 1) caller = resolverAt(callerSeed % RESOLVERS); // maybe another market's resolver
        else caller = resolverOf[id];

        ParimutuelMarket.Outcome requested =
            outcomeSeed % 8 == 0 ? ParimutuelMarket.Outcome.UNRESOLVED : ParimutuelMarket.Outcome(1 + outcomeSeed % 3);

        uint256 now_ = vm.getBlockTimestamp();
        bytes4 expected;
        if (caller != resolverOf[id]) {
            expected = ParimutuelMarket.NotResolver.selector;
        } else if (outcomeOf[id] != ParimutuelMarket.Outcome.UNRESOLVED) {
            expected = ParimutuelMarket.AlreadySettled.selector;
        } else if (now_ < closeOf[id] || now_ >= closeOf[id] + 7 days) {
            expected = ParimutuelMarket.ResolutionNotOpen.selector;
        } else if (requested == ParimutuelMarket.Outcome.UNRESOLVED) {
            expected = ParimutuelMarket.InvalidOutcome.selector;
        }

        if (expected != bytes4(0)) {
            vm.prank(caller);
            vm.expectRevert(expected);
            app.resolve(id, requested);
            return;
        }

        ParimutuelMarket.Outcome effective = requested;
        if (
            (requested == ParimutuelMarket.Outcome.YES && yesPool[id] == 0)
                || (requested == ParimutuelMarket.Outcome.NO && noPool[id] == 0)
        ) effective = ParimutuelMarket.Outcome.INVALID;

        vm.expectEmit(true, false, false, true, address(app));
        emit ParimutuelMarket.Resolved(id, effective);
        vm.prank(caller);
        app.resolve(id, requested);
        outcomeOf[id] = effective;
    }

    function voidMarket(uint256 marketSeed, uint256 callerSeed, bool jumpToTimeout) public {
        uint256 id = marketSeed % count;
        uint256 deadline = closeOf[id] + 7 days;
        if (jumpToTimeout && vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        // Anyone may void, including the resolver and non-bettors.
        address caller = callerSeed % 2 == 0 ? account(callerSeed % ACCOUNTS) : resolverOf[id];

        bytes4 expected;
        if (outcomeOf[id] != ParimutuelMarket.Outcome.UNRESOLVED) expected = ParimutuelMarket.AlreadySettled.selector;
        else if (vm.getBlockTimestamp() < deadline) expected = ParimutuelMarket.VoidNotOpen.selector;

        if (expected != bytes4(0)) {
            vm.prank(caller);
            vm.expectRevert(expected);
            app.voidMarket(id);
            return;
        }

        vm.expectEmit(true, false, false, true, address(app));
        emit ParimutuelMarket.Voided(id);
        vm.prank(caller);
        app.voidMarket(id);
        outcomeOf[id] = ParimutuelMarket.Outcome.INVALID;
    }

    // ---------------------------------------------------------------- claims

    function entitlement(uint256 id, uint256 i) public view returns (uint256) {
        Position memory p = _positions[id][i];
        ParimutuelMarket.Outcome o = outcomeOf[id];
        if (p.claimed || o == ParimutuelMarket.Outcome.UNRESOLVED) return 0;
        if (o == ParimutuelMarket.Outcome.INVALID) return p.yes + p.no;
        // Stakes are bounded by the 1e27 supply, so the product cannot overflow uint256.
        if (o == ParimutuelMarket.Outcome.YES) return p.yes * staked(id) / yesPool[id];
        return p.no * staked(id) / noPool[id];
    }

    function claim(uint256 marketSeed, uint256 accountSeed) public {
        uint256 id = marketSeed % count;
        uint256 i = accountSeed % ACCOUNTS;
        address a = account(i);
        uint256 owed = entitlement(id, i);

        bytes4 expected;
        if (outcomeOf[id] == ParimutuelMarket.Outcome.UNRESOLVED) expected = ParimutuelMarket.NotSettled.selector;
        else if (_positions[id][i].claimed) expected = ParimutuelMarket.AlreadyClaimed.selector;
        else if (owed == 0) expected = ParimutuelMarket.NothingToClaim.selector;

        if (expected != bytes4(0)) {
            vm.prank(a);
            vm.expectRevert(expected);
            app.claim(id);
            return;
        }

        uint256 beforeAccount = token.balanceOf(a);
        uint256 beforeApp = token.balanceOf(address(app));
        vm.expectEmit(true, true, false, true, address(app));
        emit ParimutuelMarket.Claimed(id, a, owed);
        vm.prank(a);
        assertEq(app.claim(id), owed, "claim returned a different amount");
        assertEq(token.balanceOf(a) - beforeAccount, owed, "claimant received a different amount");
        assertEq(beforeApp - token.balanceOf(address(app)), owed, "contract released a different amount");

        _positions[id][i].claimed = true;
        claimedOf[id] += owed;
        totalClaimed += owed;
    }

    function resolverClaims(uint256 marketSeed) external {
        uint256 id = marketSeed % count;
        vm.prank(resolverOf[id]);
        vm.expectRevert(
            outcomeOf[id] == ParimutuelMarket.Outcome.UNRESOLVED
                ? ParimutuelMarket.NotSettled.selector
                : ParimutuelMarket.NothingToClaim.selector
        );
        app.claim(id);
    }

    /// @dev Settles every market by timeout where needed and collects everything that is owed.
    function drain() external {
        for (uint256 id; id < count; ++id) {
            voidMarket(id, id, true);
            for (uint256 i; i < ACCOUNTS; ++i) {
                claim(id, i);
                assertEq(entitlement(id, i), 0);
                claim(id, i); // second attempt must be refused
            }
        }
    }
}

contract StakeOutcomeInvariantTest is Test {
    LaunchToken private token;
    ParimutuelMarket private app;
    StakeOutcomeHandler private handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        app = new ParimutuelMarket(address(token));
        handler = new StakeOutcomeHandler(token, app);
        for (uint256 i; i < handler.ACCOUNTS(); ++i) {
            token.transfer(handler.account(i), 100_000_000 ether);
        }
        for (uint256 i; i < handler.RESOLVERS(); ++i) {
            token.transfer(handler.resolverAt(i), 1_000 ether);
        }

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.createRefused.selector;
        selectors[2] = handler.placeBet.selector;
        selectors[3] = handler.betBothSides.selector;
        selectors[4] = handler.betRefused.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.warpToBoundary.selector;
        selectors[7] = handler.resolve.selector;
        selectors[8] = handler.voidMarket.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.resolverClaims.selector;
        selectors[11] = handler.placeBet.selector; // weight staking more heavily
        selectors[12] = handler.claim.selector; // and claiming
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_totalClaimedNeverExceedsTotalStakedPerMarket() public view {
        for (uint256 id; id < handler.count(); ++id) {
            ParimutuelMarket.Market memory m = app.market(id);
            assertEq(m.paidOut, handler.claimedOf(id), "paidOut diverged from observed claims");
            assertLe(m.paidOut, m.yesPool + m.noPool, "market paid out more than was staked in it");
            assertLe(handler.claimedOf(id), handler.staked(id), "claims exceeded stakes");
        }
        assertLe(handler.totalClaimed(), handler.totalStaked());
    }

    function invariant_claimedPlusOutstandingNeverExceedsStakePerMarket() public view {
        for (uint256 id; id < handler.count(); ++id) {
            uint256 outstanding;
            for (uint256 i; i < handler.ACCOUNTS(); ++i) {
                outstanding += handler.entitlement(id, i);
            }
            assertLe(handler.claimedOf(id) + outstanding, handler.staked(id), "entitlements exceed the pool");
        }
    }

    function invariant_odmkHeldCoversEveryUnclaimedEntitlement() public view {
        uint256 unclaimedEntitlements;
        uint256 unresolvedPrincipal;
        for (uint256 id; id < handler.count(); ++id) {
            if (handler.outcomeOf(id) == ParimutuelMarket.Outcome.UNRESOLVED) {
                // Before settlement the whole pool may still be owed (INVALID refunds everything).
                unresolvedPrincipal += handler.staked(id);
            } else {
                for (uint256 i; i < handler.ACCOUNTS(); ++i) {
                    unclaimedEntitlements += handler.entitlement(id, i);
                }
            }
        }
        uint256 held = token.balanceOf(address(app));
        assertGe(held, unclaimedEntitlements, "ODMK held is below unclaimed entitlements");
        assertGe(held, unclaimedEntitlements + unresolvedPrincipal, "ODMK held is below all outstanding obligations");
        assertEq(held, handler.totalStaked() - handler.totalClaimed(), "ODMK held != staked - claimed");
        assertEq(address(app).balance, 0);
    }

    function invariant_contractViewsMatchLedger() public view {
        assertEq(app.marketCount(), handler.count());
        for (uint256 id; id < handler.count(); ++id) {
            ParimutuelMarket.Market memory m = app.market(id);
            assertEq(m.yesPool, handler.yesPool(id));
            assertEq(m.noPool, handler.noPool(id));
            assertEq(m.closeTime, handler.closeOf(id));
            assertEq(m.resolver, handler.resolverOf(id));
            assertEq(uint256(m.outcome), uint256(handler.outcomeOf(id)));
            for (uint256 i; i < handler.ACCOUNTS(); ++i) {
                address a = handler.account(i);
                StakeOutcomeHandler.Position memory p = handler.position(id, i);
                assertEq(app.stakeOf(id, a, true), p.yes);
                assertEq(app.stakeOf(id, a, false), p.no);
                assertEq(app.hasClaimed(id, a), p.claimed);
                assertEq(app.claimable(id, a), handler.entitlement(id, i));
            }
            assertEq(app.claimable(id, m.resolver), 0, "resolver must never hold a position");
        }
    }

    /// @dev After any sequence, every market can be settled and fully collected, leaving only rounding dust:
    /// none for INVALID, strictly less than one base unit per winning account for YES/NO.
    function afterInvariant() public {
        handler.drain();
        uint256 dust;
        for (uint256 id; id < handler.count(); ++id) {
            ParimutuelMarket.Outcome o = handler.outcomeOf(id);
            assertTrue(o != ParimutuelMarket.Outcome.UNRESOLVED);
            uint256 residue = handler.staked(id) - handler.claimedOf(id);
            if (o == ParimutuelMarket.Outcome.INVALID) {
                assertEq(residue, 0, "refunds lost principal");
            } else {
                uint256 winners;
                for (uint256 i; i < handler.BETTORS(); ++i) {
                    StakeOutcomeHandler.Position memory p = handler.position(id, i);
                    if ((o == ParimutuelMarket.Outcome.YES ? p.yes : p.no) > 0) ++winners;
                }
                assertGt(winners, 0, "YES/NO with an empty winning side must have become INVALID");
                assertLt(residue, winners, "more than one base unit of dust per winner");
            }
            dust += residue;
        }
        invariant_totalClaimedNeverExceedsTotalStakedPerMarket();
        invariant_odmkHeldCoversEveryUnclaimedEntitlement();
        assertEq(token.balanceOf(address(app)), dust);
    }
}

/// @dev Stateless fuzzing of one market: six accounts with independent stakes on both sides, every outcome.
contract StakeOutcomeFuzzTest is Test {
    LaunchToken private token;
    ParimutuelMarket private app;
    address private constant RESOLVER = address(0xE0E0);
    address private constant OUTSIDER = address(0x0DD);
    uint256 private constant N = 6;
    uint256 private close;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        app = new ParimutuelMarket(address(token));
        for (uint256 i; i < N; ++i) {
            token.transfer(_bettor(i), 100_000_000 ether);
            vm.prank(_bettor(i));
            token.approve(address(app), type(uint256).max);
        }
        close = block.timestamp + 1 days;
        app.createMarket(bytes32("fuzz"), close, RESOLVER);
    }

    function _bettor(uint256 i) private pure returns (address) {
        return address(uint160(0xF000 + i));
    }

    /// @dev Zero a quarter of the time so one-sided and empty markets occur; otherwise dust, ordinary or huge.
    function _stake(uint256 seed) private pure returns (uint256) {
        uint256 mode = seed % 4;
        if (mode == 0) return 0;
        uint256 cap = mode == 1 ? 5 : mode == 2 ? 10 ether : 50_000_000 ether;
        return 1 + (seed >> 2) % cap;
    }

    function _settle(uint8 mode) private returns (ParimutuelMarket.Outcome requested, bool voided) {
        mode %= 6;
        if (mode == 0) requested = ParimutuelMarket.Outcome.YES;
        else if (mode == 1) requested = ParimutuelMarket.Outcome.NO;
        else if (mode == 2) requested = ParimutuelMarket.Outcome.INVALID;
        else if (mode == 3) requested = ParimutuelMarket.Outcome.YES; // at the last valid second
        else if (mode == 4) requested = ParimutuelMarket.Outcome.NO; // at the last valid second
        else (requested, voided) = (ParimutuelMarket.Outcome.INVALID, true);

        if (voided) {
            vm.warp(close + 7 days);
            vm.prank(RESOLVER);
            vm.expectRevert(ParimutuelMarket.ResolutionNotOpen.selector);
            app.resolve(0, ParimutuelMarket.Outcome.YES);
            vm.prank(OUTSIDER);
            app.voidMarket(0);
        } else {
            vm.warp(mode >= 3 ? close + 7 days - 1 : close);
            vm.prank(RESOLVER);
            app.resolve(0, requested);
            vm.prank(RESOLVER);
            vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
            app.resolve(0, ParimutuelMarket.Outcome.INVALID);
            vm.warp(close + 30 days);
            vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
            app.voidMarket(0);
        }
    }

    function testFuzz_bothSidesEveryOutcomeConservesStake(
        uint256[6] calldata yesSeeds,
        uint256[6] calldata noSeeds,
        uint8 mode,
        bool reverseClaimOrder
    ) public {
        uint256[N] memory yes;
        uint256[N] memory no;
        uint256 yesPool;
        uint256 noPool;
        for (uint256 i; i < N; ++i) {
            yes[i] = _stake(yesSeeds[i]);
            no[i] = _stake(noSeeds[i]);
            if (yes[i] > 0) {
                vm.prank(_bettor(i));
                app.bet(0, true, yes[i]);
            }
            if (no[i] > 0) {
                vm.prank(_bettor(i));
                app.bet(0, false, no[i]);
            }
            yesPool += yes[i];
            noPool += no[i];
        }
        uint256 pool = yesPool + noPool;
        assertEq(token.balanceOf(address(app)), pool);

        // Nothing is claimable before settlement.
        vm.prank(_bettor(0));
        vm.expectRevert(ParimutuelMarket.NotSettled.selector);
        app.claim(0);

        (ParimutuelMarket.Outcome requested,) = _settle(mode);
        ParimutuelMarket.Outcome effective = requested;
        if (
            (requested == ParimutuelMarket.Outcome.YES && yesPool == 0)
                || (requested == ParimutuelMarket.Outcome.NO && noPool == 0)
        ) effective = ParimutuelMarket.Outcome.INVALID;
        assertEq(uint256(app.market(0).outcome), uint256(effective));

        uint256 paid;
        uint256 winners;
        for (uint256 k; k < N; ++k) {
            uint256 i = reverseClaimOrder ? N - 1 - k : k;
            uint256 owed;
            if (effective == ParimutuelMarket.Outcome.INVALID) {
                owed = yes[i] + no[i];
            } else if (effective == ParimutuelMarket.Outcome.YES) {
                owed = yes[i] * pool / yesPool;
                if (yes[i] > 0) ++winners;
            } else {
                owed = no[i] * pool / noPool;
                if (no[i] > 0) ++winners;
            }
            assertEq(app.claimable(0, _bettor(i)), owed);
            if (owed == 0) {
                // A losing bettor (or one with no stake) cannot claim, now or later.
                vm.prank(_bettor(i));
                vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
                app.claim(0);
                assertFalse(app.hasClaimed(0, _bettor(i)));
            } else {
                assertGe(token.balanceOf(address(app)), owed, "contract cannot cover a valid claim");
                uint256 before = token.balanceOf(_bettor(i));
                vm.prank(_bettor(i));
                assertEq(app.claim(0), owed);
                assertEq(token.balanceOf(_bettor(i)) - before, owed);
                paid += owed;
                vm.prank(_bettor(i));
                vm.expectRevert(ParimutuelMarket.AlreadyClaimed.selector);
                app.claim(0);
            }
            assertLe(paid, pool, "claims exceeded stakes");
            assertEq(app.market(0).paidOut, paid);
        }

        vm.prank(OUTSIDER);
        vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
        app.claim(0);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
        app.claim(0);

        uint256 residue = pool - paid;
        assertEq(token.balanceOf(address(app)), residue);
        if (effective == ParimutuelMarket.Outcome.INVALID) assertEq(residue, 0);
        else assertLt(residue, winners);
    }

    /// @dev Around closeTime + 7 days exactly one of resolve/void can succeed, whichever is attempted first.
    function testFuzz_voidAndResolveNeverBothSucceedAtWindowEdge(uint256 offset, bool voidFirst, uint96 stake) public {
        uint256 amount = bound(uint256(stake), 1, 1_000_000 ether);
        vm.prank(_bettor(0));
        app.bet(0, true, amount);
        vm.prank(_bettor(1));
        app.bet(0, false, amount);

        uint256 t = close + 7 days - 3 + bound(offset, 0, 6);
        vm.warp(t);
        bool windowOpen = t < close + 7 days;

        if (voidFirst) {
            if (!windowOpen) {
                app.voidMarket(0);
                vm.prank(RESOLVER);
                vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
                app.resolve(0, ParimutuelMarket.Outcome.YES);
            } else {
                vm.expectRevert(ParimutuelMarket.VoidNotOpen.selector);
                app.voidMarket(0);
                vm.prank(RESOLVER);
                app.resolve(0, ParimutuelMarket.Outcome.YES);
            }
        } else {
            vm.prank(RESOLVER);
            if (windowOpen) {
                app.resolve(0, ParimutuelMarket.Outcome.YES);
                vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
                app.voidMarket(0);
            } else {
                vm.expectRevert(ParimutuelMarket.ResolutionNotOpen.selector);
                app.resolve(0, ParimutuelMarket.Outcome.YES);
                app.voidMarket(0);
            }
        }

        // Whichever path won, total claims equal the total staked (2 * amount) and nothing more.
        vm.prank(_bettor(0));
        uint256 first = app.claim(0);
        uint256 second;
        if (windowOpen) {
            assertEq(first, 2 * amount);
            vm.prank(_bettor(1));
            vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
            app.claim(0);
        } else {
            assertEq(first, amount);
            vm.prank(_bettor(1));
            second = app.claim(0);
            assertEq(second, amount);
        }
        assertEq(first + second, 2 * amount);
        assertEq(token.balanceOf(address(app)), 0);
    }
}
