// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply currency for Oddsmaker's Sepolia test markets.
contract LaunchToken is ERC20 {
    /// @dev The project factory receives the entire supply; there are no later mint or admin paths.
    constructor() ERC20("Oddsmaker", "ODMK") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
