// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ParimutuelMarket} from "../src/ParimutuelMarket.sol";

interface TokenCallback {
    function onTokenTransfer() external;
}

/// @dev Only a test dependency: ODMK has none of these malicious behaviors.
contract AdversarialToken is ERC20 {
    enum Mode {
        NORMAL,
        FALSE_RETURN,
        REVERT,
        NO_RETURN,
        SHORT_TRANSFER
    }

    Mode public incoming;
    Mode public outgoing;
    address public blockedRecipient;
    address public hook;
    bool public hookIncoming;
    bool public hookOutgoing;

    error TransferRefused();

    constructor() ERC20("Test", "TEST") {
        _mint(msg.sender, 1e27);
    }

    function configure(Mode inMode, Mode outMode, address blocked) external {
        incoming = inMode;
        outgoing = outMode;
        blockedRecipient = blocked;
    }

    function configureHook(address target, bool onIncoming, bool onOutgoing) external {
        hook = target;
        hookIncoming = onIncoming;
        hookOutgoing = onOutgoing;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (outgoing == Mode.REVERT || to == blockedRecipient) revert TransferRefused();
        if (hookOutgoing) TokenCallback(hook).onTokenTransfer();
        super.transfer(to, value);
        if (outgoing == Mode.FALSE_RETURN) return false;
        if (outgoing == Mode.NO_RETURN) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (incoming == Mode.REVERT) revert TransferRefused();
        if (hookIncoming) TokenCallback(hook).onTokenTransfer();
        super.transferFrom(from, to, incoming == Mode.SHORT_TRANSFER ? value - 1 : value);
        if (incoming == Mode.FALSE_RETURN) return false;
        if (incoming == Mode.NO_RETURN) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

contract ReentrantBettor is TokenCallback {
    ParimutuelMarket public immutable app;
    AdversarialToken public immutable token;
    bytes private attack;
    bool public attempted;
    bool public succeeded;
    bool public observedClaimed;
    uint256 public observedClaimable;
    uint256 public observedPaidOut;
    bytes public returnData;

    constructor(ParimutuelMarket app_, AdversarialToken token_) {
        app = app_;
        token = token_;
        token.approve(address(app), type(uint256).max);
    }

    function setAttack(bytes memory data) external {
        attack = data;
    }

    function bet(uint256 id, bool yes, uint256 amount) external {
        app.bet(id, yes, amount);
    }

    function collect(uint256 id) external {
        app.claim(id);
    }

    function onTokenTransfer() external {
        require(msg.sender == address(token));
        attempted = true;
        observedClaimed = app.hasClaimed(0, address(this));
        observedClaimable = app.claimable(0, address(this));
        observedPaidOut = app.market(0).paidOut;
        (succeeded, returnData) = address(app).call(attack);
    }
}

contract AdversarialTokenTest is Test {
    AdversarialToken private token;
    ParimutuelMarket private app;
    ReentrantBettor private attacker;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant RESOLVER = address(0x1234);
    uint256 private close;

    function setUp() public {
        vm.warp(1_000_000);
        token = new AdversarialToken();
        app = new ParimutuelMarket(address(token));
        attacker = new ReentrantBettor(app, token);
        token.transfer(ALICE, 100);
        token.transfer(BOB, 100);
        token.transfer(address(attacker), 100);
        vm.prank(ALICE);
        token.approve(address(app), 100);
        vm.prank(BOB);
        token.approve(address(app), 100);
        close = block.timestamp + 1 hours;
        app.createMarket(bytes32("callbacks"), close, RESOLVER);
    }

    function _settle() private {
        vm.warp(close);
        vm.prank(RESOLVER);
        app.resolve(0, ParimutuelMarket.Outcome.YES);
    }

    function _assertBlockedHook() private view {
        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        assertEq(attacker.returnData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_reentrantSameClaimBlockedAndEffectsPrecedeTransfer() public {
        attacker.bet(0, true, 20);
        vm.prank(BOB);
        app.bet(0, false, 10);
        _settle();
        attacker.setAttack(abi.encodeCall(app.claim, (0)));
        token.configureHook(address(attacker), false, true);
        attacker.collect(0);
        _assertBlockedHook();
        assertTrue(attacker.observedClaimed());
        assertEq(attacker.observedClaimable(), 0);
        assertEq(attacker.observedPaidOut(), 30);
        assertEq(token.balanceOf(address(attacker)), 110);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_reentrantCrossMarketClaimBlockedAndStillCollectableLater() public {
        app.createMarket(bytes32("second"), close, RESOLVER);
        attacker.bet(0, true, 20);
        attacker.bet(1, true, 30);
        _settle();
        vm.prank(RESOLVER);
        app.resolve(1, ParimutuelMarket.Outcome.YES);
        attacker.setAttack(abi.encodeCall(app.claim, (1)));
        token.configureHook(address(attacker), false, true);
        attacker.collect(0);
        _assertBlockedHook();
        assertFalse(app.hasClaimed(1, address(attacker)));
        assertEq(app.claimable(1, address(attacker)), 30);
        assertEq(token.balanceOf(address(app)), 30);
        token.configureHook(address(0), false, false);
        attacker.collect(1);
        assertEq(token.balanceOf(address(attacker)), 100);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_reentrantBetDuringTransferFromBlocked() public {
        attacker.setAttack(abi.encodeCall(app.bet, (0, true, 1)));
        token.configureHook(address(attacker), true, false);
        attacker.bet(0, true, 20);
        _assertBlockedHook();
        assertEq(app.stakeOf(0, address(attacker), true), 20);
        assertEq(app.market(0).yesPool, 20);
        assertEq(token.balanceOf(address(app)), 20);
    }

    function test_falseReturningIncomingTransferIsAtomic() public {
        token.configure(AdversarialToken.Mode.FALSE_RETURN, AdversarialToken.Mode.NORMAL, address(0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        app.bet(0, true, 20);
        assertEq(app.market(0).yesPool, 0);
        assertEq(app.stakeOf(0, ALICE, true), 0);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.allowance(ALICE, address(app)), 100);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_shortIncomingTransferIsAtomic() public {
        token.configure(AdversarialToken.Mode.SHORT_TRANSFER, AdversarialToken.Mode.NORMAL, address(0));
        vm.prank(ALICE);
        vm.expectRevert(ParimutuelMarket.UnexpectedTransferAmount.selector);
        app.bet(0, true, 20);
        assertEq(app.market(0).yesPool, 0);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_falseReturningPayoutIsRetryable() public {
        vm.prank(ALICE);
        app.bet(0, true, 20);
        _settle();
        token.configure(AdversarialToken.Mode.NORMAL, AdversarialToken.Mode.FALSE_RETURN, address(0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        app.claim(0);
        assertFalse(app.hasClaimed(0, ALICE));
        assertEq(app.market(0).paidOut, 0);
        assertEq(app.claimable(0, ALICE), 20);
        assertEq(token.balanceOf(ALICE), 80);
        assertEq(token.balanceOf(address(app)), 20);
        token.configure(AdversarialToken.Mode.NORMAL, AdversarialToken.Mode.NORMAL, address(0));
        vm.prank(ALICE);
        assertEq(app.claim(0), 20);
    }

    function test_blockedRecipientDoesNotBlockOtherBettors() public {
        vm.prank(ALICE);
        app.bet(0, true, 20);
        vm.prank(BOB);
        app.bet(0, true, 30);
        _settle();
        token.configure(AdversarialToken.Mode.NORMAL, AdversarialToken.Mode.NORMAL, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(AdversarialToken.TransferRefused.selector);
        app.claim(0);
        vm.prank(BOB);
        assertEq(app.claim(0), 30);
        assertEq(app.claimable(0, ALICE), 20);
        assertEq(token.balanceOf(address(app)), 20);
        token.configure(AdversarialToken.Mode.NORMAL, AdversarialToken.Mode.NORMAL, address(0));
        vm.prank(ALICE);
        assertEq(app.claim(0), 20);
    }

    function test_optionalReturnTokenSupportedBothDirections() public {
        token.configure(AdversarialToken.Mode.NO_RETURN, AdversarialToken.Mode.NO_RETURN, address(0));
        vm.prank(ALICE);
        app.bet(0, true, 20);
        _settle();
        vm.prank(ALICE);
        assertEq(app.claim(0), 20);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(address(app)), 0);
    }
}
