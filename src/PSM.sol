// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PSMFed} from "src/PSMFed.sol";

interface IController {
    function onBuy(address user, address to, uint256 amount) external returns (bool);
    function onSell(address user, address to, uint256 amount) external returns (bool);
}

contract PSM {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    IERC20 public immutable DOLA;
    address public immutable fed; // PSMFed contract address

    address public gov;
    address public pendingGov;
    IController public controller; // Controller contract address
    uint256 public buyFeeBps; // e.g., 50 = 0.5%
    uint256 public sellFeeBps; // e.g., 50 = 0.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public supply; // Collateral supplied in the PSM (excluding fees and profit)
    IERC4626 public vault;
    uint256 public minTotalSupply;

    event GovChanged(address indexed oldGov, address indexed newGov);
    event PendingGovUpdated(address indexed pendingGov);
    event ControllerChanged(address indexed oldController, address indexed newController);
    event VaultMigrated(address indexed oldVault, address indexed newVault);
    event BuyFeeUpdated(uint256 oldFee, uint256 newFee);
    event SellFeeUpdated(uint256 oldFee, uint256 newFee);
    event SupplyCapUpdated(uint256 newSupplyCap);
    event Buy(address indexed user, uint256 purchased, uint256 spent);
    event Sell(address indexed user, uint256 sold, uint256 received);
    event ProfitTaken(uint256 profit);
    event MinTotalSupplyUpdated(uint256 oldMinTotalSupply, uint256 newMinTotalSupply);

    constructor(address _collateral, address _vault, address _DOLA, address _gov, address _controller, address _chair) {
        collateral = IERC20(_collateral);
        vault = IERC4626(_vault);
        DOLA = IERC20(_DOLA);
        gov = _gov;
        controller = IController(_controller);
        fed = address(new PSMFed(address(this), _gov, _chair, _DOLA));
        DOLA.approve(fed, type(uint256).max);
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Not gov");
        _;
    }

    /**
     * @notice Allows to buy DOLA minus fee using collateral.
     * @param collateralAmountIn Amount of collateral to sell for DOLA.
     */
    function buy(uint256 collateralAmountIn) external {
        buy(msg.sender, collateralAmountIn);
    }

    /**
     * @notice Allows to buy DOLA minus fee using collateral.
     * @param to DOLA receiver.
     * @param collateralAmountIn Amount of collateral to sell for DOLA.
     */
    function buy(address to, uint256 collateralAmountIn) public {
        require(collateralAmountIn > 0, "Amount must be > 0");
        require(vault.totalSupply() >= minTotalSupply, "Min total supply not met");
        require(controller.onBuy(msg.sender, to, collateralAmountIn), "Denied by controller");
        uint256 amountOut = collateralAmountIn;

        if (buyFeeBps > 0) {
            uint256 fee = (collateralAmountIn * buyFeeBps) / BPS_DENOMINATOR;
            amountOut -= fee;
        }
        supply += amountOut;

        collateral.safeTransferFrom(msg.sender, address(this), collateralAmountIn);
        collateral.approve(address(vault), collateralAmountIn);
        uint256 shares = vault.deposit(collateralAmountIn, address(this));
        require(shares > 0, "Deposit failed");
        DOLA.safeTransfer(to, amountOut);
        emit Buy(msg.sender, amountOut, collateralAmountIn);
    }

    /**
     * @notice Allows to sell DOLA for collateral minus fee.
     * @param dolaAmountIn Amount of DOLA to sell.
     */
    function sell(uint256 dolaAmountIn) external {
        sell(msg.sender, dolaAmountIn);
    }

    /**
     * @notice Allows to sell DOLA for collateral minus fee.
     * @param to Address to receive the collateral.
     * @param dolaAmountIn Amount of DOLA to sell.
     */
    function sell(address to, uint256 dolaAmountIn) public {
        require(dolaAmountIn > 0, "Amount must be > 0");
        require(controller.onSell(msg.sender, to, dolaAmountIn), "Denied by controller");
        supply -= dolaAmountIn;
        DOLA.safeTransferFrom(msg.sender, address(this), dolaAmountIn);

        uint256 amountOut = dolaAmountIn;

        if (sellFeeBps > 0) {
            uint256 fee = (dolaAmountIn * sellFeeBps) / BPS_DENOMINATOR;
            amountOut -= fee;
        }

        vault.withdraw(amountOut, to, address(this));
        emit Sell(msg.sender, dolaAmountIn, amountOut);
    }

    /**
     * @notice Takes profit from the vault and transfers it to the governance address.
     * @dev Can be called by anyone to transfer profits and fees to governance.
     */
    function takeProfit() public {
        uint256 profit = getProfit();
        if (profit > 0) {
            vault.withdraw(profit, gov, address(this));
        }
        emit ProfitTaken(profit);
    }

    /**
     * @notice Returns the total collateral reserves in the vault, including profit and fees.
     * @return Total reserves in the vault.
     */
    function getTotalReserves() public view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this)));
    }

    /**
     * @notice Returns the total profit made by the PSM.
     * @return Total profit in the PSM.
     */
    function getProfit() public view returns (uint256) {
        uint256 totalReserves = getTotalReserves();
        return totalReserves > supply ? totalReserves - supply : 0;
    }

    /**
     * @notice Returns the amount of DOLA that can be obtained for a given amount of collateral.
     * @param collateralIn Amount of collateral to convert to DOLA.
     * @return Amount of DOLA that will be received after fees.
     */
    function getDolaOut(uint256 collateralIn) external view returns (uint256) {
        uint256 fee = (collateralIn * buyFeeBps) / BPS_DENOMINATOR;
        return collateralIn - fee;
    }

    /**
     * @notice Returns the amount of collateral that can be obtained for a given amount of DOLA.
     * @param dolaIn Amount of DOLA to convert to collateral.
     * @return Amount of collateral that will be received after fees.
     */
    function getCollateralOut(uint256 dolaIn) external view returns (uint256) {
        uint256 fee = (dolaIn * sellFeeBps) / BPS_DENOMINATOR;
        return dolaIn - fee;
    }

    /**
     * @notice Migrate the vault to a new IERC4626 vault.
     * @dev Can only be called by governance and will take profit before migration.
     * @param newVault Address of the new vault to migrate to.
     * @param minCollateralAmount Minimum amount of collateral to be deposited in the new vault.
     * @param minSharesOut Minimum amount of shares to receive from the new vault.
     */
    function migrate(address newVault, uint256 minCollateralAmount, uint256 minSharesOut) external onlyGov {
        require(newVault != address(0), "Zero address");
        require(IERC4626(newVault).asset() == address(collateral), "New vault must accept collateral");

        takeProfit();

        if (vault.balanceOf(address(this)) != 0) {
            vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        }

        address oldVault = address(vault);
        vault = IERC4626(newVault);
        require(vault.totalSupply() >= minTotalSupply, "New vault does not meet min total supply");

        uint256 collateralBalance = collateral.balanceOf(address(this));
        require(collateralBalance >= minCollateralAmount, "Insufficient collateral balance for migration");
        if (collateralBalance > 0) {
            collateral.approve(address(vault), collateralBalance);
            uint256 sharesOut = vault.deposit(collateralBalance, address(this));
            require(sharesOut >= minSharesOut, "Insufficient shares received from new vault");
        }
        emit VaultMigrated(oldVault, newVault);
    }

    /**
     * @notice Allows governance to sweep any ERC20 tokens from the contract.
     * @dev Can only be called by governance.
     * @param token The ERC20 token to sweep.
     */
    function sweep(IERC20 token) external onlyGov {
        token.safeTransfer(gov, token.balanceOf(address(this)));
    }

    /**
     * @notice Allows governance to set the buy fee.
     * @dev The fee is specified in basis points (bps), where 100 bps = 1%.
     */
    function setBuyFeeBps(uint256 newFee) external onlyGov {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit BuyFeeUpdated(buyFeeBps, newFee);
        buyFeeBps = newFee;
    }

    /**
     * @notice Allows governance to set the sell fee.
     * @dev The fee is specified in basis points (bps), where 100 bps = 1%.
     */
    function setSellFeeBps(uint256 newFee) external onlyGov {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit SellFeeUpdated(sellFeeBps, newFee);
        sellFeeBps = newFee;
    }

    /**
     * @notice Allows governance to set the minimum vault total supply.
     * @dev This is used to ensure that the vault has enough shares before allowing buy operations.
     * @param _minTotalSupply Minimum total supply that must have been already minted in the vault.
     */
    function setMinTotalSupply(uint256 _minTotalSupply) external onlyGov {
        require(_minTotalSupply > 0, "Min total supply must be > 0");
        emit MinTotalSupplyUpdated(minTotalSupply, _minTotalSupply);
        minTotalSupply = _minTotalSupply;
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

    /**
     * @notice Allows governance to set a new controller.
     * @dev The new controller must not be the zero address.
     * @param newController Address of the new controller.
     */
    function setController(address newController) external onlyGov {
        require(newController != address(0), "Zero address");
        emit ControllerChanged(address(controller), newController);
        controller = IController(newController);
    }
}
