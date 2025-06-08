// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IDOLA is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

contract PSM {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    IERC4626 public immutable vault;
    IDOLA public immutable DOLA;
    address public immutable gov;

    address public operator;
    uint256 public depositFeeBps;   // e.g., 50 = 0.5%
    uint256 public withdrawFeeBps;  // e.g., 50 = 0.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public supply;
    uint256 public supplyCap; 
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
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
        address _operator
    ) {
        collateral = IERC20(_collateral);
        vault = IERC4626(_vault);
        DOLA = IDOLA(_DOLA);
        gov = _gov;
        depositFeeBps = _depositFeeBps;
        withdrawFeeBps = _withdrawFeeBps;
        operator = _operator;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    function buy(address to, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        require(supply + amount <= supplyCap, "Supply cap exceeded");
        supply += amount;
        uint256 amountIn = amount;
        if(depositFeeBps > 0) {
            uint256 fee = (amount * depositFeeBps) / BPS_DENOMINATOR;
            amountIn += fee;
        }

        collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        collateral.approve(address(vault), amountIn);
        vault.deposit(amountIn, address(this));
        DOLA.mint(to, amount);
        emit Buy(msg.sender, amount, amountIn);
    }


    function sell(address to, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        supply -= amount;
        DOLA.transferFrom(msg.sender, address(this), amount);
        DOLA.burn(address(this), amount);

        uint256 amountOut = amount;

        if(withdrawFeeBps > 0) {
            uint256 fee = (amount * withdrawFeeBps) / BPS_DENOMINATOR;
            amountOut -= fee;
        }

        vault.withdraw(amountOut, to, address(this));
        emit Sell(msg.sender, amount, amountOut);
    }

    function takeProfit() external {
        uint256 vaultBal = vault.balanceOf(address(this));
        uint256 amountOut = vault.previewRedeem(vaultBal); 
        uint256 profit = amountOut - supply;
        if (profit > 0) {
            vault.withdraw(profit, gov, address(this)); 
        }
    }

    function getTotalReserves() external view returns (uint256) {
        return vault.previewRedeem(vault.balanceOf(address(this)));
    }

    function getCollateralIn(uint256 dolaBuyAmount) external view returns (uint256) {
        uint256 fee = (dolaBuyAmount * depositFeeBps) / BPS_DENOMINATOR;
        return dolaBuyAmount + fee;
    }

    function getCollateralOut(uint256 dolaSellAmount) external view returns (uint256) {
        uint256 fee = (dolaSellAmount * withdrawFeeBps) / BPS_DENOMINATOR;
        return dolaSellAmount - fee;
    }

    function sweep(IERC20 token) public onlyOperator {
        require(token != IERC20(address(vault)), "Vault token cannot be swept");
        token.safeTransfer(gov, token.balanceOf(address(this)));
    }


    function setDepositFeeBps(uint256 newFee) external onlyOperator {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit DepositFeeUpdated(depositFeeBps, newFee);
        depositFeeBps = newFee;
    }

    function setWithdrawFeeBps(uint256 newFee) external onlyOperator {
        require(newFee <= BPS_DENOMINATOR, "Fee too high");
        emit WithdrawFeeUpdated(withdrawFeeBps, newFee);
        withdrawFeeBps = newFee;
    }

    function setSupplyCap(uint256 newSupplyCap) external onlyOperator {
        supplyCap = newSupplyCap;
        emit SupplyCapUpdated(supplyCap);
    }

    function setOperator(address newOperator) external onlyOperator {
        require(newOperator != address(0), "Zero address");
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }
}