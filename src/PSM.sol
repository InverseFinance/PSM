// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PSMFed} from "src/PSMFed.sol";

interface IController {
    function isBuyAllowed() external view returns (bool);
    function isSellAllowed() external view returns (bool);
}

contract PSM {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    IERC20 public immutable DOLA;
    address public immutable fed; // PSMFed contract address
    
    address public gov;
    IController public controller; // Controller contract address
    uint256 public depositFeeBps; // e.g., 50 = 0.5%
    uint256 public withdrawFeeBps; // e.g., 50 = 0.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public supply; // Collateral supplied in the PSM (excluding fees and profit)
    IERC4626 public vault;

    event GovChanged(address indexed oldOperator, address indexed newOperator);
    event ControllerChanged(address indexed oldController, address indexed newController);
    event VaultMigrated(address indexed oldVault, address indexed newVault);
    event DepositFeeUpdated(uint256 oldFee, uint256 newFee);
    event WithdrawFeeUpdated(uint256 oldFee, uint256 newFee);
    event SupplyCapUpdated(uint256 newSupplyCap);
    event Buy(address indexed user, uint256 purchased, uint256 spent);
    event Sell(address indexed user, uint256 sold, uint256 received);

    constructor(
        address _collateral,
        address _vault,
        address _DOLA,
        address _gov,
        uint256 _depositFeeBps,
        uint256 _withdrawFeeBps,
        address _controller,
        address _chair
    ) {
        require(_depositFeeBps <= BPS_DENOMINATOR && _withdrawFeeBps <= BPS_DENOMINATOR, "Fees too high");
        collateral = IERC20(_collateral);
        vault = IERC4626(_vault);
        DOLA = IERC20(_DOLA);
        gov = _gov;
        depositFeeBps = _depositFeeBps;
        withdrawFeeBps = _withdrawFeeBps;
        controller = IController(_controller);
        fed = address(new PSMFed(address(this), _gov, _chair, _DOLA));
        DOLA.approve(fed, type(uint256).max); 
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Not gov");
        _;
    }

    function buy(uint256 amount) external {
        buy(msg.sender, amount);
    }

    function buy(address to, uint256 amount) public {
        require(amount > 0, "Amount must be > 0");
        require(controller.isBuyAllowed(), "Denied by controller");
        supply += amount;
        uint256 amountIn = amount;
        if (depositFeeBps > 0) {
            uint256 fee = (amount * depositFeeBps) / BPS_DENOMINATOR;
            amountIn += fee;
        }

        collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        collateral.approve(address(vault), amountIn);
        vault.deposit(amountIn, address(this));
        DOLA.safeTransfer(to, amount);
        emit Buy(msg.sender, amount, amountIn);
    }

    function sell(uint256 amount) external {
        sell(msg.sender, amount);
    }
    function sell(address to, uint256 amount) public {
        require(amount > 0, "Amount must be > 0");
        require(controller.isSellAllowed(), "Denied by controller");
        supply -= amount;
        DOLA.safeTransferFrom(msg.sender, address(this), amount);

        uint256 amountOut = amount;

        if (withdrawFeeBps > 0) {
            uint256 fee = (amount * withdrawFeeBps) / BPS_DENOMINATOR;
            amountOut -= fee;
        }

        vault.withdraw(amountOut, to, address(this));
        emit Sell(msg.sender, amount, amountOut);
    }

    function takeProfit() public {
        uint256 vaultBal = vault.balanceOf(address(this));
        uint256 amountOut = vault.previewRedeem(vaultBal);
        uint256 profit = amountOut - supply;
        if (profit > 0) {
            vault.withdraw(profit, gov, address(this));
        }
    }

    // Include profit and fees in total reserves
    function getTotalReserves() public view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this)));
    }

    function getProfit() external view returns (uint256) {
        return getTotalReserves() - supply; 
    }

    function getCollateralIn(uint256 dolaBuyAmount) external view returns (uint256) {
        uint256 fee = (dolaBuyAmount * depositFeeBps) / BPS_DENOMINATOR;
        return dolaBuyAmount + fee;
    }

    function getCollateralOut(uint256 dolaSellAmount) external view returns (uint256) {
        uint256 fee = (dolaSellAmount * withdrawFeeBps) / BPS_DENOMINATOR;
        return dolaSellAmount - fee;
    }

    function migrate(address newVault) external onlyGov {
        require(newVault != address(0), "Zero address");
        require(IERC4626(newVault).asset() == address(collateral), "New vault must accept collateral");
        
        takeProfit();

        if(vault.balanceOf(address(this)) != 0) {
            vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        }
        
        address oldVault = address(vault);
        vault = IERC4626(newVault);
        uint256 collateralBalance = collateral.balanceOf(address(this));
        collateral.approve(address(vault),collateralBalance);
        vault.deposit(collateralBalance, address(this));
        emit VaultMigrated(oldVault, newVault);
    }
    
    function sweep(IERC20 token) external onlyGov {
        token.safeTransfer(gov, token.balanceOf(address(this)));
    }

    function setDepositFeeBps(uint256 newFee) external onlyGov {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit DepositFeeUpdated(depositFeeBps, newFee);
        depositFeeBps = newFee;
    }

    function setWithdrawFeeBps(uint256 newFee) external onlyGov {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit WithdrawFeeUpdated(withdrawFeeBps, newFee);
        withdrawFeeBps = newFee;
    }

    function setGov(address newGov) external onlyGov {
        require(newGov != address(0), "Zero address");
        emit GovChanged(gov, newGov);
        gov = newGov;
    }

    function setController(address newController) external onlyGov {
        require(newController != address(0), "Zero address");
        emit ControllerChanged(address(controller), newController);
        controller = IController(newController);
    }
}
