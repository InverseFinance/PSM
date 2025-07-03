// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Warning: Contracts using this template must include require(msg.sender == PSM) for any state-mutating functions.
// Omitting this check can introduce vulnerabilities if future controllers forget to enforce it.
contract Controller {
    /**
     * @notice Checks if a buy operation is allowed.
     * @dev This function can be modified to include specific conditions for allowing buys.
     * @param amount The amount of collateral to be sold.
     * @return bool Returns true if the buy operation is allowed, false otherwise.
     * For now, it returns true to allow all buy operations.
     */
    function onBuy(address user, uint256 amount) external returns (bool) {
        user;
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
    function onSell(address user, uint256 amount) external returns (bool) {
        user;
        amount; // To avoid unused variable warning
        return true; // For now, we allow all calls
    }
}
