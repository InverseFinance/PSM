// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDOLA is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract PSMFed {
    address public immutable psm;
    IDOLA public immutable DOLA;

    address public gov;
    address public pendingGov;
    address public chair;
    uint256 public supply; // Current DOLA amount supplied to the PSM
    uint256 public supplyCap; // Maximum DOLA supply allowed in the PSM

    event GovChanged(address indexed oldGov, address indexed newGov);
    event PendingGovUpdated(address indexed pendingGov);
    event ChairChanged(address indexed oldChair, address indexed newChair);
    event SupplyCapUpdated(uint256 oldSupplyCap, uint256 newSupplyCap);

    constructor(address _psm, address _gov, address _chair, address _dola) {
        psm = _psm;
        gov = _gov;
        chair = _chair;
        DOLA = IDOLA(_dola);
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Not governance");
        _;
    }

    modifier onlyChair() {
        require(msg.sender == chair, "Not chair");
        _;
    }

    /**
     * @notice Allows the chair to expand the supply of DOLA in the PSM.
     * @dev This function increases the supply of DOLA in the PSM and mints
     * the specified amount of DOLA.
     * @dev The amount must be greater than zero and cannot exceed the supply cap.
     * @param amount The amount of DOLA to expand.
     */
    function expansion(uint256 amount) external onlyChair {
        require(amount > 0, "Amount must be > 0");
        require(amount + supply <= supplyCap, "Supply cap exceeded");
        supply += amount;
        DOLA.mint(psm, amount);
    }

    /**
     * @notice Allows the chair to contract the supply of DOLA in the PSM.
     * @dev This function reduces the supply of DOLA in the PSM and burns the
     * specified amount of DOLA.
     * @dev The amount must be greater than zero and cannot exceed the current supply.
     * @param amount The amount of DOLA to contract.
     */
    function contraction(uint256 amount) external onlyChair {
        require(amount > 0, "Amount must be > 0");
        supply -= amount;
        DOLA.transferFrom(psm, address(this), amount);
        DOLA.burn(amount);
    }

    /**
     * @notice Allows governance to set a new supply cap.
     * @param newSupplyCap The new supply cap for DOLA in the PSM.
     */
    function setSupplyCap(uint256 newSupplyCap) external onlyGov {
        uint256 oldSupplyCap = supplyCap;
        supplyCap = newSupplyCap;
        emit SupplyCapUpdated(oldSupplyCap, newSupplyCap);
    }

    /**
     * @notice Allows governance to set a new chair.
     * @dev The new chair must not be the zero address.
     * @param newChair Address of the new chair.
     */
    function setChair(address newChair) external onlyGov {
        address oldChair = chair;
        chair = newChair;
        emit ChairChanged(oldChair, newChair);
    }

    /**
     * @notice Allows the current chair to resign.
     * @dev The chair can resign, leaving the chair address as zero.
     */
    function resign() external onlyChair {
        address oldChair = chair;
        chair = address(0);
        emit ChairChanged(oldChair, address(0));
    }

    /**
     * @notice Allows governance to set a new pending governance.
     * @dev The pending governance must accept the role.
     * @param _pendingGov Address of the new pending governance.
     */
    function setPendingGov(address _pendingGov) external onlyGov {
        pendingGov = _pendingGov;
        emit PendingGovUpdated(_pendingGov);
    }

    /**
     * @notice Allows the pending governance to claim the governance role.
     * @dev Can only be called by the pending governance.
     */
    function claimPendingGov() external {
        require(msg.sender == pendingGov, "Not pending gov");
        emit GovChanged(gov, pendingGov);
        gov = pendingGov;
        pendingGov = address(0);
    }
}
