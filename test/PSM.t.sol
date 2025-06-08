// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/PSM.sol";
import {MockERC4626, ERC20} from "lib/solmate/src/test/utils/mocks/MockERC4626.sol";
// Simple mocks for ERC20
contract MockERC20 is IERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}


contract PSMTest is Test {
    PSM psm;
    MockERC20 collateral;
    MockERC4626 vault;
    MockERC20 DOLA;
    address gov = address(0xfee);
    address operator = address(this);
    address user = address(0x123);

    function setUp() public {
        collateral = new MockERC20();
        vault = new MockERC4626(ERC20(address(collateral)), "MOCK", "MOCK");
        DOLA = new MockERC20();
        psm = new PSM(
            address(collateral),
            address(vault),
            address(DOLA),
            gov,
            50, // 0.5% deposit fee
            100, // 1% withdraw fee
            operator
        );
        collateral.mint(user, 1_000_000 ether);
        vm.startPrank(user);
        collateral.approve(address(psm), type(uint256).max);
        vm.stopPrank();
        psm.setSupplyCap(1_000_000 ether); // Set supply cap for DOLA
    }

    function testMintDOLAWithFee() public {
        uint256 buyAmount = 1000 ether;
        vm.startPrank(user);
        psm.buy(user, buyAmount);
        vm.stopPrank();

        // Check fee: 0.5% of 1000 = 5
        // Vault should have 1005 collateral
        assertEq(collateral.balanceOf(address(vault)), 1005 ether);
        // User should have 1000 DOLA (buyAmount)
        assertEq(DOLA.balanceOf(user), 1000 ether);
    }

    function testBurnDOLAWithFee() public {
        uint256 buyAmount = 1000 ether;
        uint256 initialCollateralBal = collateral.balanceOf(user);
        vm.startPrank(user);
        psm.buy(user, buyAmount);
        DOLA.approve(address(psm), type(uint256).max);
        console2.log(DOLA.balanceOf(user));
        // Now burn 1000 DOLA
        psm.sell(user,1000 ether);
        vm.stopPrank();

        assertEq(collateral.balanceOf(gov), 0);
        assertEq(collateral.balanceOf(user), initialCollateralBal - 1005 ether + 990 ether);
        // Vault should have only fees left
        assertEq(collateral.balanceOf(address(vault)), 15 ether); // deposit and withdraw fees
    }

    function testBurnDolaExceedSupply() public {
        // Mint some DOLA 
        uint256 buyAmount = 1000 ether;
        vm.startPrank(user);
        psm.buy(user, buyAmount);
        DOLA.approve(address(psm), type(uint256).max);
        vm.stopPrank();

        // Now try to burn more than minted
        vm.startPrank(user);
        psm.sell(user, 1000 ether);

        assertEq(collateral.balanceOf(address(vault)), 15 ether); // deposit and withdraw fees
        DOLA.mint(user, 15 ether); // Mint some DOLA to user
        vm.expectRevert();
        psm.sell(user, 15 ether);
        vm.stopPrank();
    }


    function testTakeProfit() public {
        // Mint some DOLA 
        uint256 buyAmount = 1000 ether;
        uint256 initialCollateralBal = collateral.balanceOf(user);
        vm.startPrank(user);
        psm.buy(user, buyAmount);
        DOLA.approve(address(psm), type(uint256).max);
        vm.stopPrank();

        // Simulate profit in vault
        uint256 profit = 200 ether; // Assume profit of 200 ether
        collateral.mint(address(vault), profit); // Add profit to vault

        vm.prank(operator);
        psm.takeProfit();

        // Check that profit was taken
        assertEq(collateral.balanceOf(gov), profit + 5 ether); // 5 ether from deposit fee

        vm.prank(user);
        psm.sell(user, 1000 ether); // User sells DOLA
        assertEq(psm.supply(), 0); // Supply should be zero after selling all DOLA
        assertEq(collateral.balanceOf(user), initialCollateralBal - 1005 ether + 990 ether); // User gets back collateral minus fees

        uint256 govBalanceAfter = collateral.balanceOf(gov);

        vm.prank(operator);
        psm.takeProfit(); // Operator tries to take profit again (fees from previous sell)
        assertEq(collateral.balanceOf(gov), govBalanceAfter + 10 ether);
    }

    function test_fail_if_exceed_supply_cap() public {
        uint256 supplyCap = psm.supplyCap();
        uint256 buyAmount = supplyCap + 1 ether; // Exceeding supply cap
        vm.startPrank(user);
        vm.expectRevert("Supply cap exceeded");
        psm.buy(user, buyAmount);
        vm.stopPrank();
    }

    function testOperatorCanUpdateFees() public {
        psm.setDepositFeeBps(100);
        assertEq(psm.depositFeeBps(), 100);
        psm.setWithdrawFeeBps(200);
        assertEq(psm.withdrawFeeBps(), 200);
    }

    function testNonOperatorCannotUpdateFees() public {
        vm.startPrank(user);
        vm.expectRevert("Not operator");
        psm.setDepositFeeBps(100);
        vm.expectRevert("Not operator");
        psm.setWithdrawFeeBps(200);
    }

    function testNonOperatorCannotUpdateSupplyCap() public {
        vm.startPrank(user);
        vm.expectRevert("Not operator");
        psm.setSupplyCap(2_000_000 ether);
    }
    function testOperatorChange() public {
        address newOp = address(0x456);
        psm.setOperator(newOp);
        assertEq(psm.operator(), newOp);
    }
}