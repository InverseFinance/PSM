// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/PSM.sol";
import {Controller} from "src/Controller.sol";
import {PSMFed} from "src/PSMFed.sol";
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
    PSMFed fed;
    Controller controller;
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
        controller = new Controller();
        psm = new PSM(
            address(collateral),
            address(vault),
            address(DOLA),
            gov,
            50, // 0.5% deposit fee
            100, // 1% withdraw fee
            address(controller),
            address(this)
        );
        fed = PSMFed(psm.fed());

        collateral.mint(user, 10_050_000 ether);
        vm.startPrank(user);
        collateral.approve(address(psm), type(uint256).max);
        vm.stopPrank();
        vm.prank(gov);
        fed.setSupplyCap(20_000_000 ether); // Set supply cap for DOLA
        fed.expansion(10_000_000 ether); // Mint some DOLA to PSMFed
    }

    function test_BuyDOLAWithFee(uint256 amount) public returns (uint256) {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        vm.startPrank(user);
        psm.buy(user, amount);
        vm.stopPrank();
     
        uint256 buyFee = amount * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        assertEq(collateral.balanceOf(address(vault)), amount + buyFee); // 1000 + 5 = 1005
        // User should have DOLA bought
        assertEq(DOLA.balanceOf(user), amount);
        return buyFee;
    }

    function test_Buy_DOLA(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        vm.startPrank(user);
        psm.buy(amount);
        assertEq(DOLA.balanceOf(user), amount);
    }

    function test_Sell_DOLA(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        vm.startPrank(user);
        psm.buy(amount);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(amount);
        vm.stopPrank();
        assertEq(DOLA.balanceOf(user), 0); // User should have no DOLA left
    }

    function test_SellDOLAWithFee(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
      
        uint256 initialCollateralBal = collateral.balanceOf(user);
        vm.startPrank(user);
        psm.buy(user, amount);
       
        console2.log(DOLA.balanceOf(user));
        // Now burn All DOLA
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, amount);
        vm.stopPrank();

        uint256 buyFee = amount * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        uint256 sellFee = amount * psm.withdrawFeeBps() / 10000; // 1% withdraw fee
        assertEq(collateral.balanceOf(gov), 0);
        assertEq(collateral.balanceOf(user), initialCollateralBal - (buyFee + sellFee)); // User gets back collateral minus fees
        // Vault should have only fees left
        assertEq(collateral.balanceOf(address(vault)), buyFee + sellFee); // deposit and withdraw fees
    }

    function test_SellDolaExceedSupply(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
    
        vm.prank(user);
        psm.buy(user, amount);
   
        vm.stopPrank();

        // Now try to sell more than bought
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, amount);
        uint256 buyFee = amount * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        uint256 sellFee = amount * psm.withdrawFeeBps() / 10000; // 1% withdraw fee
        assertEq(collateral.balanceOf(address(vault)), buyFee + sellFee); // deposit and withdraw fees

        DOLA.mint(user, 15 ether); // Mint some DOLA to user
        vm.expectRevert();
        psm.sell(user, 15 ether);
        vm.stopPrank();
    }

    function test_TakeProfit(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);

        uint256 initialCollateralBal = collateral.balanceOf(user);
        // Buy some DOLA
        vm.prank(user);
        psm.buy(user, amount);

        // Simulate profit in vault
        uint256 profit = 200 ether; // Assume profit of 200 ether
        collateral.mint(address(vault), profit); // Add profit to vault

        // Take profit
        vm.prank(operator);
        psm.takeProfit();

        uint256 buyFee = amount * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        // Check that profit was taken
        assertEq(collateral.balanceOf(gov), profit + buyFee); 

        uint256 sellFee = amount * psm.withdrawFeeBps() / 10000; // 1% withdraw fee
        // User sells all DOLA
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, amount); // User sells DOLA
        vm.stopPrank();
        assertEq(psm.supply(), 0); // Supply should be zero after selling all DOLA
        assertEq(collateral.balanceOf(user), initialCollateralBal - (buyFee + sellFee)); // User gets back collateral minus fees
        assertEq(DOLA.balanceOf(user), 0); // User should have no DOLA left

        // Gov balance has profit + buyFee
        uint256 govBalanceAfter = collateral.balanceOf(gov);

        vm.prank(operator);
        psm.takeProfit(); // Operator tries to take profit again (fees from previous sell)
        assertEq(collateral.balanceOf(gov), govBalanceAfter + sellFee);
    }

    function test_Migrate_Vault(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        uint256 fee = test_BuyDOLAWithFee(amount);
         // Simulate profit in vault
        uint256 profit = 200 ether; // Assume profit of 200 ether
        collateral.mint(address(vault), profit); // Add profit to vault
        
        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        vm.prank(gov);
        psm.migrate(address(newVault)); 
        assertEq(address(psm.vault()), address(newVault));
        // Profit was taken and transferred to governance plus the deposit fee
        assertEq(collateral.balanceOf(gov), profit + fee);
        // Check new vault has the correct balance
        assertEq(newVault.balanceOf(address(psm)), amount); 
    }

    function test_2_users_buy_then_migrate_with_profit_then_contract_and_sell() public {
        address user2 = address(0x456);
        collateral.mint(user2, 5000 ether); // Give user2 some collateral
        
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 2000 ether;
        uint256 user1CollateralBal = collateral.balanceOf(user);
        uint256 user2CollateralBal = collateral.balanceOf(user2);
        // User1 buys DOLA
        vm.startPrank(user);
        psm.buy(user, amount1);
        vm.stopPrank();

        // User2 buys DOLA
        vm.startPrank(user2);
        collateral.approve(address(psm), type(uint256).max);
        psm.buy(user2, amount2);
        vm.stopPrank();

        // Check balances after both users bought DOLA
        assertEq(DOLA.balanceOf(user), amount1);
        assertEq(DOLA.balanceOf(user2), amount2);

        assertEq(collateral.balanceOf(address(gov)),0) ; // Gov should have no collateral yet
        // Simulate profit in vault
        uint256 profit = 100 ether; // Assume profit of 100 ether
        collateral.mint(address(vault), 100 ether);
        // Migrate to new vault
        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        vm.prank(gov);
        psm.migrate(address(newVault));
        // After migration, profit and fees should be taken and transferred to governance
        uint256 fee = (amount1 + amount2) * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        assertEq(collateral.balanceOf(gov), profit + fee); // Gov should have profit + deposit fee
       
        // Check new vault has the correct balance
        assertEq(newVault.balanceOf(address(psm)), amount1 + amount2);

        // Full contraction but can still sell DOLA 
        vm.prank(gov);
        fed.contraction(DOLA.balanceOf(address(psm))); 

        // User 1 sells DOLA
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, amount1);
        vm.stopPrank();
        // User 2 sells DOLA
        vm.startPrank(user2);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user2, amount2);
        vm.stopPrank();

        // Check both users got their collateral back minus fees
        uint256 buyFee1 = amount1 * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        uint256 buyFee2 = amount2 * psm.depositFeeBps() / 10000; // 0.5% deposit fee
        uint256 sellFee1 = amount1 * psm.withdrawFeeBps() / 10000; // 1% withdraw fee
        uint256 sellFee2 = amount2 * psm.withdrawFeeBps() / 10000; // 1% withdraw fee
        assertEq(collateral.balanceOf(user), user1CollateralBal - (buyFee1 + sellFee1));
        assertEq(collateral.balanceOf(user2), user2CollateralBal - (buyFee2 + sellFee2));
    }
    function test_Fail_if_no_DOLA_available() public {
        uint256 dolaBalance = DOLA.balanceOf(address(psm));
        fed.contraction(dolaBalance);
        assertEq(DOLA.balanceOf(address(psm)), 0);
        vm.startPrank(user);
        vm.expectRevert();
        psm.buy(user, dolaBalance);
        vm.stopPrank();
    }

    function test_GovCanUpdateFees() public {
        vm.startPrank(gov);
        psm.setDepositFeeBps(100);
        assertEq(psm.depositFeeBps(), 100);
        psm.setWithdrawFeeBps(200);
        assertEq(psm.withdrawFeeBps(), 200);
    }

    function test_GovCanUpdateController() public {
        Controller newController = new Controller();
        vm.startPrank(gov);
        psm.setController(address(newController));
        assertEq(address(psm.controller()), address(newController));
    }

    function test_GovChange() public {
        address newOp = address(0x456);
        vm.prank(gov);
        psm.setGov(newOp);
        assertEq(psm.gov(), newOp);
    }
    function test_NonGovCannotUpdateFees() public {
        vm.startPrank(user);
        vm.expectRevert("Not gov");
        psm.setDepositFeeBps(100);
        vm.expectRevert("Not gov");
        psm.setWithdrawFeeBps(200);
    }

    function test_Fail_DepositFee_TooHigh() public {
        vm.startPrank(gov);
        vm.expectRevert("Fee too high");
        psm.setDepositFeeBps(10001); // 100.1%
        vm.stopPrank();
    }
    function test_Fail_WithdrawFee_TooHigh() public {
        vm.startPrank(gov);
        vm.expectRevert("Fee too high");
        psm.setWithdrawFeeBps(10001); // 100.1%
        vm.stopPrank();
    }


    function test_Fail_Zero_Amount() public {
        vm.startPrank(user);
        vm.expectRevert("Amount must be > 0");
        psm.buy(user, 0);
        vm.expectRevert("Amount must be > 0");
        psm.sell(user, 0);
        vm.stopPrank();
    }

    function test_Fail_buy_and_sell_if_denied_by_Controller() public {
        vm.mockCall(
            address(psm.controller()),
            abi.encodeWithSelector(Controller.isBuyAllowed.selector),
            abi.encode(false)
        );
        vm.mockCall(
            address(psm.controller()),
            abi.encodeWithSelector(Controller.isSellAllowed.selector),
            abi.encode(false)
        );
        vm.startPrank(user);
        vm.expectRevert("Denied by controller");
        psm.buy(user, 1000 ether);
        vm.expectRevert("Denied by controller");
        psm.sell(user, 1000 ether);
        vm.stopPrank();
    }
    function test_getCollateralOut() public {
        uint256 dolaAmount = 1000 ether;
        uint256 expectedCollateralOut = dolaAmount - (dolaAmount * psm.withdrawFeeBps() / 10000); // 1% fee
        assertEq(psm.getCollateralOut(dolaAmount), expectedCollateralOut);
    }

    function test_getCollateralIn() public {
        uint256 dolaAmount = 1000 ether;
        uint256 expectedCollateralIn = dolaAmount + (dolaAmount * psm.depositFeeBps() / 10000); // 0.5% fee
        assertEq(psm.getCollateralIn(dolaAmount), expectedCollateralIn);
    }

    function test_getTotalReserves() public {
        uint256 dolaAmount = 1000 ether;
        vm.startPrank(user);
        psm.buy(user, dolaAmount);
        vm.stopPrank();
        
        uint256 totalReserves = psm.getTotalReserves();
        assertEq(totalReserves, dolaAmount + (dolaAmount * psm.depositFeeBps() / 10000)); // Total reserves should include DOLA supply + deposit fee
    }

    function test_getProfit() public {
        uint256 dolaAmount = 1000 ether;
        vm.startPrank(user);
        psm.buy(user, dolaAmount);
        vm.stopPrank();
        
        uint256 profit = psm.getProfit();
        assertEq(profit, (dolaAmount * psm.depositFeeBps() / 10000)); // Profit should equal to fees collected
    }

    function test_PSMFed_expansion(uint256 expansionAmount) public {
        uint256 initialSupply = fed.supply();
        vm.assume(expansionAmount > 0 && expansionAmount <= fed.supplyCap() - initialSupply);
        
        vm.prank(fed.chair());
        fed.expansion(expansionAmount);
        
        assertEq(fed.supply(), initialSupply + expansionAmount);
        assertEq(DOLA.balanceOf(address(psm)), initialSupply + expansionAmount);
    }
    function test_PSMFed_contraction(uint256 contractionAmount) public {
        uint256 initialSupply = fed.supply();
        vm.assume(contractionAmount > 0 && contractionAmount <= initialSupply);
        
        vm.prank(fed.chair());
        fed.contraction(contractionAmount);
        
        assertEq(fed.supply(), initialSupply - contractionAmount);
        assertEq(DOLA.balanceOf(address(psm)), initialSupply - contractionAmount);
    }

    function test_PSMFed_setSupplyCap(uint256 newSupplyCap) public {
        vm.assume(newSupplyCap > 0 && newSupplyCap < 100000000 ether);
        
        vm.prank(gov);
        fed.setSupplyCap(newSupplyCap);
        
        assertEq(fed.supplyCap(), newSupplyCap);
    }
    function test_PSMFed_setChair(address newChair) public {
        vm.assume(newChair != address(0));
        
        vm.prank(gov);
        fed.setChair(newChair);
        
        assertEq(fed.chair(), newChair);
    }
    function test_PSMFed_resign() public {
        address initialChair = fed.chair();
        
        vm.prank(initialChair);
        fed.resign();
        
        assertEq(fed.chair(), address(0));
    }
}
