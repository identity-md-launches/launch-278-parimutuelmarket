// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ParimutuelMarket} from "../src/ParimutuelMarket.sol";

/// @dev Maintains a separate ledger, with ordinary uint256 arithmetic on deliberately bounded test amounts.
contract AccountingHandler is Test {
    struct Position {
        uint256 yes;
        uint256 no;
        bool claimed;
    }

    LaunchToken public immutable token;
    ParimutuelMarket public immutable app;
    address public constant RESOLVER = address(0x1234);
    uint256 public constant ACTORS = 5;
    uint256 public count;
    uint256 public totalDeposited;
    uint256 public totalPaid;
    uint256 public donations;
    mapping(uint256 => uint256) public closes;
    mapping(uint256 => uint256) public yesPools;
    mapping(uint256 => uint256) public noPools;
    mapping(uint256 => uint256) public paid;
    mapping(uint256 => ParimutuelMarket.Outcome) public outcomes;
    mapping(uint256 => mapping(uint256 => Position)) private _positions;

    constructor(LaunchToken token_, ParimutuelMarket app_) {
        token = token_;
        app = app_;
        for (uint256 i; i < ACTORS; ++i) {
            vm.prank(actor(i));
            token.approve(address(app), type(uint256).max);
        }
        create(1 hours);
        create(2 days);
        create(30 days);
    }

    function actor(uint256 index) public pure returns (address) {
        return address(uint160(0xA000 + index));
    }

    function position(uint256 id, uint256 index) external view returns (Position memory) {
        return _positions[id][index];
    }

    function create(uint256 duration) public {
        if (count == 8) return;
        uint256 deadline = block.timestamp + bound(duration, 1 hours, 90 days);
        uint256 id = app.createMarket(bytes32(count + 1), deadline, RESOLVER);
        assertEq(id, count);
        closes[count++] = deadline;
    }

    function placeBet(uint256 seed, uint256 actorSeed, bool yes, uint256 amount) public {
        uint256 id = seed % count;
        uint256 index = actorSeed % ACTORS;
        if (block.timestamp >= closes[id]) return;
        uint256 available = token.balanceOf(actor(index));
        if (available == 0) return;
        amount = bound(amount, 1, available < 100 ether ? available : 100 ether);
        vm.prank(actor(index));
        app.bet(id, yes, amount);
        if (yes) {
            _positions[id][index].yes += amount;
            yesPools[id] += amount;
        } else {
            _positions[id][index].no += amount;
            noPools[id] += amount;
        }
        totalDeposited += amount;
    }

    function advanceTime(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 0, 2 days));
    }

    function settle(uint256 seed, uint256 outcomeSeed) external {
        uint256 id = seed % count;
        if (outcomes[id] != ParimutuelMarket.Outcome.UNRESOLVED) return;
        if (vm.getBlockTimestamp() < closes[id]) vm.warp(closes[id]);
        if (vm.getBlockTimestamp() >= closes[id] + 7 days) return;
        ParimutuelMarket.Outcome outcome = ParimutuelMarket.Outcome(1 + outcomeSeed % 3);
        vm.prank(RESOLVER);
        app.resolve(id, outcome);
        if (
            (outcome == ParimutuelMarket.Outcome.YES && yesPools[id] == 0)
                || (outcome == ParimutuelMarket.Outcome.NO && noPools[id] == 0)
        ) outcome = ParimutuelMarket.Outcome.INVALID;
        outcomes[id] = outcome;
    }

    function expireMarket(uint256 seed) public {
        uint256 id = seed % count;
        if (outcomes[id] != ParimutuelMarket.Outcome.UNRESOLVED) return;
        if (block.timestamp < closes[id] + 7 days) vm.warp(closes[id] + 7 days);
        vm.prank(actor(seed % ACTORS));
        app.voidMarket(id);
        outcomes[id] = ParimutuelMarket.Outcome.INVALID;
    }

    function collect(uint256 seed, uint256 actorSeed) public {
        uint256 id = seed % count;
        uint256 index = actorSeed % ACTORS;
        uint256 expected = entitlement(id, index);
        if (expected == 0) return;
        uint256 beforeBalance = token.balanceOf(actor(index));
        vm.prank(actor(index));
        assertEq(app.claim(id), expected);
        assertEq(token.balanceOf(actor(index)) - beforeBalance, expected);
        _positions[id][index].claimed = true;
        paid[id] += expected;
        totalPaid += expected;
    }

    function donate(uint256 amount) external {
        uint256 available = token.balanceOf(actor(0));
        if (available == 0) return;
        amount = bound(amount, 1, available < 1 ether ? available : 1 ether);
        vm.prank(actor(0));
        token.transfer(address(app), amount);
        donations += amount;
    }

    function entitlement(uint256 id, uint256 index) public view returns (uint256) {
        Position memory p = _positions[id][index];
        ParimutuelMarket.Outcome outcome = outcomes[id];
        if (p.claimed || outcome == ParimutuelMarket.Outcome.UNRESOLVED) return 0;
        if (outcome == ParimutuelMarket.Outcome.INVALID) return p.yes + p.no;
        uint256 pool = yesPools[id] + noPools[id];
        if (outcome == ParimutuelMarket.Outcome.YES) return p.yes * pool / yesPools[id];
        return p.no * pool / noPools[id];
    }
}

contract AccountingInvariantTest is Test {
    LaunchToken private token;
    ParimutuelMarket private app;
    AccountingHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        app = new ParimutuelMarket(address(token));
        handler = new AccountingHandler(token, app);
        for (uint256 i; i < handler.ACTORS(); ++i) {
            token.transfer(handler.actor(i), 1_000_000 ether);
        }
        handler.placeBet(0, 0, true, 2);
        handler.placeBet(0, 1, true, 1);
        handler.placeBet(0, 2, false, 1);
        handler.placeBet(1, 0, false, 7);
        handler.placeBet(1, 1, true, 5);
        handler.placeBet(2, 3, true, 9);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.placeBet.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.expireMarket.selector;
        selectors[5] = handler.collect.selector;
        selectors[6] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_payoutConservationAndCoverageOfAllUnclaimedEntitlements() public view {
        uint256 requiredBalance;
        assertEq(app.marketCount(), handler.count());
        for (uint256 id; id < handler.count(); ++id) {
            ParimutuelMarket.Market memory m = app.market(id);
            uint256 pool = handler.yesPools(id) + handler.noPools(id);
            assertEq(m.yesPool, handler.yesPools(id));
            assertEq(m.noPool, handler.noPools(id));
            assertEq(m.paidOut, handler.paid(id));
            assertEq(uint256(m.outcome), uint256(handler.outcomes(id)));
            assertLe(handler.paid(id), pool, "a market paid out another market's funds");
            uint256 remaining;
            for (uint256 index; index < handler.ACTORS(); ++index) {
                AccountingHandler.Position memory p = handler.position(id, index);
                address account = handler.actor(index);
                assertEq(app.stakeOf(id, account, true), p.yes);
                assertEq(app.stakeOf(id, account, false), p.no);
                assertEq(app.hasClaimed(id, account), p.claimed);
                assertEq(app.claimable(id, account), handler.entitlement(id, index));
                remaining += handler.entitlement(id, index);
            }
            assertLe(handler.paid(id) + remaining, pool);
            requiredBalance += m.outcome == ParimutuelMarket.Outcome.UNRESOLVED ? pool : remaining;
        }
        assertLe(handler.totalPaid(), handler.totalDeposited());
        assertGe(token.balanceOf(address(app)), requiredBalance);
        assertEq(token.balanceOf(address(app)), handler.totalDeposited() + handler.donations() - handler.totalPaid());
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev Every generated sequence must be drainable by ordinary timeout/refund/claim calls, leaving only dust/donations.
    function afterInvariant() public {
        uint256 dust;
        for (uint256 id; id < handler.count(); ++id) {
            handler.expireMarket(id);
            for (uint256 index; index < handler.ACTORS(); ++index) {
                handler.collect(id, index);
                assertEq(handler.entitlement(id, index), 0);
            }
            uint256 residue = handler.yesPools(id) + handler.noPools(id) - handler.paid(id);
            if (handler.outcomes(id) == ParimutuelMarket.Outcome.INVALID) {
                assertEq(residue, 0);
            } else {
                assertLt(residue, handler.ACTORS());
            }
            dust += residue;
        }
        invariant_payoutConservationAndCoverageOfAllUnclaimedEntitlements();
        assertEq(token.balanceOf(address(app)), dust + handler.donations());
    }
}
