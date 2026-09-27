// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndWholeSupplyToDeployer() public view {
        assertEq(token.name(), "Oddsmaker");
        assertEq(token.symbol(), "ODMK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_approvalTransferFromAndAllowanceConsumption() public {
        token.approve(ALICE, 123);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 100));
        assertEq(token.allowance(address(this), ALICE), 23);
        assertEq(token.balanceOf(BOB), 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 23, 24));
        token.transferFrom(address(this), BOB, 24);
    }

    function test_unlimitedAllowanceAndZeroTransfer() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
    }

    function test_rejectsInvalidRecipientsAndInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_noAdministrativeOrMintSelectorsEvenForDeployer() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, 1e27);
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool attackerSuccess,) = address(token).call(data);
            assertFalse(attackerSuccess);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
