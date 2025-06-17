// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDOLA is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
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

    function expansion(uint256 amount) external onlyChair {
        require(amount > 0, "Amount must be > 0");
        require(amount + supply <= supplyCap, "Supply cap exceeded");
        supply += amount;
        DOLA.mint(psm, amount);
    }

    function contraction(uint256 amount) external onlyChair {
        require(amount > 0, "Amount must be > 0");
        supply -= amount;
        DOLA.transferFrom(psm, address(this), amount);
        DOLA.burn(address(this), amount);
    }

    function setSupplyCap(uint256 newSupplyCap) external onlyGov {
        uint256 oldSupplyCap = supplyCap;
        supplyCap = newSupplyCap;
        emit SupplyCapUpdated(oldSupplyCap, newSupplyCap);
    }

    function setChair(address newChair) external onlyGov {
        require(newChair != address(0), "Invalid address");
        address oldChair = chair;
        chair = newChair;
        emit ChairChanged(oldChair, newChair);
    }

    function resign() external onlyChair {
        address oldChair = chair;
        chair = address(0);
        emit ChairChanged(oldChair, address(0));
    }

    function setPendingGov(address _pendingGov) external onlyGov {
        pendingGov = _pendingGov;
        emit PendingGovUpdated(_pendingGov);
    }

    function claimPendingGov() external {
        require(msg.sender == pendingGov, "Not pending gov");
        emit GovChanged(gov, pendingGov);
        gov = pendingGov;
        pendingGov = address(0);
    }
}
