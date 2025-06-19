// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Controller {
    
    /**
     * @notice Checks if a buy operation is allowed.
     * @dev This function can be modified to include specific conditions for allowing buys.
     * @param amount The amount of collateral to be sold.
     * @return bool Returns true if the buy operation is allowed, false otherwise.
     * For now, it returns true to allow all buy operations.
     */
    function isBuyAllowed(uint256 amount) external pure returns (bool) {
        amount; // To avoid unused variable warning
        return true; 
    }

    /**
     * @notice Checks if a sell operation is allowed.
     * @dev This function can be modified to include specific conditions for allowing sells.
     * @param amount The amount of DOLA to be sold.
     * @return bool Returns true if the sell operation is allowed, false otherwise.
     * For now, it returns true to allow all sell operations.
     */
    function isSellAllowed(uint256 amount) external pure returns (bool) {
        amount; // To avoid unused variable warning
        return true; // For now, we allow all calls
    }
}
