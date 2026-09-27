// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ParimutuelMarket} from "../src/ParimutuelMarket.sol";

/// @dev Local factory simulation with no environment variables, initialization calls, or token funding for the app.
contract FactoryHarness {
    function deploy() external returns (LaunchToken token, ParimutuelMarket app) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        app = new ParimutuelMarket{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentSupplySizeAndOpcodes() public {
        vm.chainId(11155111);
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken token, ParimutuelMarket app) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(address(app.token()), address(token));
        _checkRuntime(address(token).code);
        _checkRuntime(address(app).code);
        // Any caller can create markets; deployment does not assign the factory a privileged role.
        vm.prank(address(0x1234));
        assertEq(app.createMarket(bytes32("public"), block.timestamp + 1 hours, address(0x5678)), 0);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
