// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Controller {
    function isBuyAllowed() external pure returns (bool) {
        return true; // For now, we allow all calls
    }

    function isSellAllowed() external pure returns (bool) {
        return true; // For now, we allow all calls
    }
}
