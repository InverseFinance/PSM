// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Controller {
    function isBuyAllowed(uint256 amount) external pure returns (bool) {
        return true; // For now, we allow all calls
    }

    function isSellAllowed(uint256 amount) external pure returns (bool) {
        return true; // For now, we allow all calls
    }
}
