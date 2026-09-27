// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ParimutuelMarket} from "../src/ParimutuelMarket.sol";

contract ParimutuelMarketTest is Test {
    LaunchToken internal token;
    ParimutuelMarket internal app;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant RESOLVER = address(0x1234);
    uint256 internal close;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        app = new ParimutuelMarket(address(token));
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _fund(RESOLVER);
        close = block.timestamp + 1 days;
        app.createMarket(bytes32("Will it rain?"), close, RESOLVER);
    }

    function _fund(address actor) internal {
        token.transfer(actor, 1_000_000 ether);
        vm.prank(actor);
        token.approve(address(app), type(uint256).max);
    }

    function _bet(uint256 id, address actor, bool yes, uint256 amount) internal {
        vm.prank(actor);
        app.bet(id, yes, amount);
    }

    function _resolve(uint256 id, ParimutuelMarket.Outcome outcome) internal {
        vm.prank(RESOLVER);
        app.resolve(id, outcome);
    }

    function _claim(uint256 id, address actor, uint256 expected) internal {
        uint256 beforeBalance = token.balanceOf(actor);
        assertEq(app.claimable(id, actor), expected);
        vm.prank(actor);
        assertEq(app.claim(id), expected);
        assertEq(token.balanceOf(actor) - beforeBalance, expected);
        assertTrue(app.hasClaimed(id, actor));
        assertEq(app.claimable(id, actor), 0);
    }

    function test_deployEmptyAndImmutableCurrency() public view {
        assertEq(address(app.token()), address(token));
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(address(app).balance, 0);
        assertEq(app.marketCount(), 1);
        ParimutuelMarket.Market memory m = app.market(0);
        assertEq(m.question, bytes32("Will it rain?"));
        assertEq(m.closeTime, close);
        assertEq(m.resolver, RESOLVER);
        assertEq(uint256(m.outcome), 0);
    }

    function test_rejectsMissingTokenCode() public {
        vm.expectRevert(ParimutuelMarket.InvalidToken.selector);
        new ParimutuelMarket(address(0));
        vm.expectRevert(ParimutuelMarket.InvalidToken.selector);
        new ParimutuelMarket(ALICE);
    }

    function test_creationBoundsInclusiveAndNoResolverZero() public {
        vm.expectEmit(true, true, true, true);
        emit ParimutuelMarket.Created(1, address(this), bytes32("short"), block.timestamp + 1 hours, RESOLVER);
        assertEq(app.createMarket(bytes32("short"), block.timestamp + 1 hours, RESOLVER), 1);
        assertEq(app.createMarket(bytes32("long"), block.timestamp + 90 days, RESOLVER), 2);
        vm.expectRevert(ParimutuelMarket.InvalidCloseTime.selector);
        app.createMarket(bytes32(0), block.timestamp + 1 hours - 1, RESOLVER);
        vm.expectRevert(ParimutuelMarket.InvalidCloseTime.selector);
        app.createMarket(bytes32(0), block.timestamp + 90 days + 1, RESOLVER);
        vm.expectRevert(ParimutuelMarket.InvalidResolver.selector);
        app.createMarket(bytes32(0), close, address(0));
        assertEq(app.marketCount(), 3);
    }

    function test_repeatAndBothSideBetsAndImpliedOdds() public {
        (uint256 yes, uint256 no) = app.impliedOdds(0);
        assertEq(yes, 5000);
        assertEq(no, 5000);
        vm.expectEmit(true, true, false, true);
        emit ParimutuelMarket.Bet(0, ALICE, true, 1);
        _bet(0, ALICE, true, 1);
        _bet(0, ALICE, true, 2);
        _bet(0, ALICE, false, 3);
        _bet(0, BOB, false, 3);
        assertEq(app.stakeOf(0, ALICE, true), 3);
        assertEq(app.stakeOf(0, ALICE, false), 3);
        assertEq(app.market(0).yesPool, 3);
        assertEq(app.market(0).noPool, 6);
        (yes, no) = app.impliedOdds(0);
        assertEq(yes, 3333);
        assertEq(no, 6667);
        assertEq(token.balanceOf(address(app)), 9);
        assertEq(app.claimable(0, ALICE), 0);
    }

    function test_betAtCloseBoundaryRefused() public {
        vm.warp(close - 1);
        _bet(0, ALICE, true, 10);
        vm.warp(close);
        vm.prank(BOB);
        vm.expectRevert(ParimutuelMarket.MarketClosed.selector);
        app.bet(0, false, 10);
        vm.warp(close + 1);
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.MarketClosed.selector);
        app.bet(0, true, 1);
        assertEq(token.balanceOf(address(app)), 10);
    }

    function test_zeroBetAndResolverBetRefused() public {
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.ZeroAmount.selector);
        app.bet(0, true, 0);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.ResolverCannotBet.selector);
        app.bet(0, false, 1);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_missingAllowanceAndBalanceRollBackBet() public {
        vm.prank(ALICE);
        token.approve(address(app), 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 0, 10));
        app.bet(0, true, 10);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, BOB, 1_000_000 ether, 1_000_000 ether + 1
            )
        );
        app.bet(0, false, 1_000_000 ether + 1);
        assertEq(app.market(0).yesPool, 0);
        assertEq(app.market(0).noPool, 0);
        assertEq(app.stakeOf(0, ALICE, true), 0);
        assertEq(app.stakeOf(0, BOB, false), 0);
    }

    function test_resolutionAuthorityEarlyAndInvalidOutcome() public {
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.NotResolver.selector);
        app.resolve(0, ParimutuelMarket.Outcome.YES);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.ResolutionNotOpen.selector);
        app.resolve(0, ParimutuelMarket.Outcome.YES);
        vm.warp(close);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.InvalidOutcome.selector);
        app.resolve(0, ParimutuelMarket.Outcome.UNRESOLVED);
        vm.prank(RESOLVER);
        (bool ok,) = address(app).call(abi.encodeWithSignature("resolve(uint256,uint8)", 0, 4));
        assertFalse(ok);
        assertEq(uint256(app.market(0).outcome), 0);
    }

    function test_yesPayoutBothSidesAndLoserCannotClaim() public {
        _bet(0, ALICE, true, 2);
        _bet(0, ALICE, false, 1);
        _bet(0, BOB, true, 1);
        _bet(0, CAROL, false, 2);
        vm.warp(close);
        vm.expectEmit(true, false, false, true);
        emit ParimutuelMarket.Resolved(0, ParimutuelMarket.Outcome.YES);
        _resolve(0, ParimutuelMarket.Outcome.YES);
        vm.expectEmit(true, true, false, true);
        emit ParimutuelMarket.Claimed(0, ALICE, 4);
        _claim(0, ALICE, 4);
        _claim(0, BOB, 2);
        vm.prank(CAROL);
        vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
        app.claim(0);
        vm.prank(address(0x999));
        vm.expectRevert(ParimutuelMarket.NothingToClaim.selector);
        app.claim(0);
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.AlreadyClaimed.selector);
        app.claim(0);
        assertEq(app.market(0).paidOut, 6);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(app.stakeOf(0, ALICE, true), 2);
    }

    function test_noPayoutRoundsDownAndRetainsDust() public {
        _bet(0, ALICE, false, 1);
        _bet(0, BOB, false, 2);
        _bet(0, CAROL, true, 1);
        vm.warp(close);
        _resolve(0, ParimutuelMarket.Outcome.NO);
        _claim(0, BOB, 2);
        _claim(0, ALICE, 1);
        assertEq(app.market(0).paidOut, 3);
        assertEq(token.balanceOf(address(app)), 1);
        assertEq(app.claimable(0, CAROL), 0);
    }

    function test_oneSidedMarketWinningSideGetsOwnStakeBack() public {
        _bet(0, ALICE, true, 2);
        _bet(0, BOB, true, 3);
        vm.warp(close);
        _resolve(0, ParimutuelMarket.Outcome.YES);
        assertEq(uint256(app.market(0).outcome), uint256(ParimutuelMarket.Outcome.YES));
        _claim(0, ALICE, 2);
        _claim(0, BOB, 3);
    }

    function test_oneSidedMarketEmptyWinnerBecomesInvalid() public {
        _bet(0, ALICE, true, 7);
        vm.warp(close);
        vm.expectEmit(true, false, false, true);
        emit ParimutuelMarket.Resolved(0, ParimutuelMarket.Outcome.INVALID);
        _resolve(0, ParimutuelMarket.Outcome.NO);
        _claim(0, ALICE, 7);
    }

    function test_emptyYesWinnerAndCompletelyEmptyMarketBecomeInvalid() public {
        uint256 empty = app.createMarket(bytes32("empty"), close, RESOLVER);
        _bet(0, ALICE, false, 3);
        vm.warp(close);
        _resolve(0, ParimutuelMarket.Outcome.YES);
        _resolve(empty, ParimutuelMarket.Outcome.NO);
        assertEq(uint256(app.market(empty).outcome), uint256(ParimutuelMarket.Outcome.INVALID));
        _claim(0, ALICE, 3);
    }

    function test_invalidRefundsBothSidesOnce() public {
        _bet(0, ALICE, true, 3);
        _bet(0, ALICE, false, 4);
        _bet(0, BOB, false, 9);
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.NotSettled.selector);
        app.claim(0);
        vm.warp(close);
        _resolve(0, ParimutuelMarket.Outcome.INVALID);
        _claim(0, ALICE, 7);
        _claim(0, BOB, 9);
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.AlreadyClaimed.selector);
        app.claim(0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_lastResolutionSecondAndResolveTwiceRefused() public {
        _bet(0, ALICE, true, 10);
        vm.warp(close + 7 days - 1);
        vm.expectRevert(ParimutuelMarket.VoidNotOpen.selector);
        app.voidMarket(0);
        _resolve(0, ParimutuelMarket.Outcome.YES);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
        app.resolve(0, ParimutuelMarket.Outcome.INVALID);
        vm.warp(close + 7 days);
        vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
        app.voidMarket(0);
        _claim(0, ALICE, 10);
    }

    function test_timeoutBoundaryLateResolveRefusedAndAnyoneCanVoid() public {
        _bet(0, ALICE, true, 3);
        _bet(0, ALICE, false, 4);
        _bet(0, BOB, false, 9);
        vm.warp(close + 7 days);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.ResolutionNotOpen.selector);
        app.resolve(0, ParimutuelMarket.Outcome.YES);
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.NotSettled.selector);
        app.claim(0);
        vm.expectEmit(true, false, false, true);
        emit ParimutuelMarket.Voided(0);
        vm.prank(CAROL);
        app.voidMarket(0);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
        app.resolve(0, ParimutuelMarket.Outcome.YES);
        vm.expectRevert(ParimutuelMarket.AlreadySettled.selector);
        app.voidMarket(0);
        _claim(0, ALICE, 7);
        _claim(0, BOB, 9);
    }

    function test_resolutionAfterTimeoutAndMuchLaterVoid() public {
        _bet(0, ALICE, false, 2);
        vm.warp(close + 7 days + 1);
        vm.prank(RESOLVER);
        vm.expectRevert(ParimutuelMarket.ResolutionNotOpen.selector);
        app.resolve(0, ParimutuelMarket.Outcome.NO);
        vm.warp(close + 365 days);
        app.voidMarket(0);
        _claim(0, ALICE, 2);
    }

    function test_crossMarketAccountingAndDonationsDoNotChangePayout() public {
        uint256 other = app.createMarket(bytes32("other"), close + 1 days, RESOLVER);
        _bet(0, ALICE, true, 1);
        _bet(0, BOB, true, 2);
        _bet(0, CAROL, false, 1);
        _bet(other, ALICE, false, 1000);
        _bet(other, BOB, true, 500);
        token.transfer(address(app), 77);
        vm.warp(close);
        _resolve(0, ParimutuelMarket.Outcome.YES);
        _claim(0, BOB, 2);
        _claim(0, ALICE, 1);
        assertEq(token.balanceOf(address(app)), 1500 + 77 + 1);
        vm.warp(close + 1 days);
        _resolve(other, ParimutuelMarket.Outcome.NO);
        _claim(other, ALICE, 1500);
        assertEq(token.balanceOf(address(app)), 78);
        assertEq(app.market(0).paidOut, 3);
        assertEq(app.market(other).paidOut, 1500);
    }

    function test_unknownMarketRejectedEverywhere() public {
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.market(1);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.stakeOf(1, ALICE, true);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.impliedOdds(1);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.claimable(1, ALICE);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.hasClaimed(1, ALICE);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.bet(1, true, 1);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.resolve(1, ParimutuelMarket.Outcome.YES);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.voidMarket(1);
        vm.expectRevert(ParimutuelMarket.UnknownMarket.selector);
        app.claim(1);
    }

    function test_noEthEntryPointsOrFallback() public {
        vm.deal(address(this), 1 ether);
        (bool plain,) = address(app).call{value: 1}("");
        (bool unknown,) = address(app).call(hex"ffffffff");
        (bool payableCreate,) =
            address(app).call{value: 1}(abi.encodeCall(app.createMarket, (bytes32("ETH"), close, RESOLVER)));
        assertFalse(plain);
        assertFalse(unknown);
        assertFalse(payableCreate);
        assertEq(address(app).balance, 0);
    }

    function testFuzz_floorPayoutsNeverExceedPool(uint96 a, uint96 b, uint96 c, bool yes, bool reverse) public {
        uint256 x = bound(uint256(a), 1, 100_000 ether);
        uint256 y = bound(uint256(b), 1, 100_000 ether);
        uint256 z = bound(uint256(c), 1, 100_000 ether);
        _bet(0, ALICE, yes, x);
        _bet(0, BOB, yes, y);
        _bet(0, CAROL, !yes, z);
        vm.warp(close);
        _resolve(0, yes ? ParimutuelMarket.Outcome.YES : ParimutuelMarket.Outcome.NO);
        uint256 pool = x + y + z;
        uint256 paidA = x * pool / (x + y);
        uint256 paidB = y * pool / (x + y);
        assertLe(paidA + paidB, pool);
        if (reverse) {
            _claim(0, BOB, paidB);
            assertGe(token.balanceOf(address(app)), paidA);
            _claim(0, ALICE, paidA);
        } else {
            _claim(0, ALICE, paidA);
            assertGe(token.balanceOf(address(app)), paidB);
            _claim(0, BOB, paidB);
        }
        assertLt(token.balanceOf(address(app)), 2);
        assertEq(app.market(0).paidOut + token.balanceOf(address(app)), pool);
    }
}
