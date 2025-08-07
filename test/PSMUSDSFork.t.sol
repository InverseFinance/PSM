// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/PSM.sol";
import {Controller} from "src/Controller.sol";
import {PSMFed} from "src/PSMFed.sol";
import {MockERC4626, ERC20} from "lib/solmate/src/test/utils/mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin/contracts/interfaces/IERC4626.sol";
// Simple mocks for ERC20

interface IDOLA is IERC20 {
    function addMinter(address minter) external;
}

contract PSMUSDSTest is Test {
    PSM psm;
    PSMFed fed;
    Controller controller;
    IERC20 collateral = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F); // USDS
    IERC4626 vault = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD); // sUSDS Vault
    IDOLA DOLA = IDOLA(0x865377367054516e17014CcdED1e7d814EDC9ce4);
    address gov = address(0x926dF14a23BE491164dCF93f4c468A50ef659D5B);
    address user = address(0x123);
    address firstDepositor = address(0x789);

    function setUp() public {
        string memory url = vm.rpcUrl("mainnet");
        vm.createSelectFork(url, 22768961);
        controller = new Controller();
        psm = new PSM(
            address(collateral),
            address(vault),
            address(DOLA),
            gov,
            address(controller),
            address(this) // chair
        );
        fed = PSMFed(psm.fed());

        deal(address(collateral), user, 10_000_000 ether); // Give user some collateral
        vm.startPrank(user);
        collateral.approve(address(psm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(gov);
        DOLA.addMinter(address(fed)); // Allow PSMFed to mint DOLA
        fed.setSupplyCap(20_000_000 ether); // Set supply cap for DOLA
        psm.setBuyFeeBps(50); // 0.5% buy fee
        psm.setSellFeeBps(100); // 1% sell fee
        psm.setMinTotalSupply(100000 ether); // Set minimum total supply for vault
        vm.stopPrank();
        fed.expansion(10_000_000 ether); // Mint some DOLA to PSMFed
    }

    function test_BuyDOLAWithFee(uint256 amount) public returns (uint256) {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        vm.startPrank(user);
        psm.buy(user, amount);
        vm.stopPrank();

        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(psm))), amount, 2);
        // User should have DOLA bought
        assertEq(DOLA.balanceOf(user), amount - buyFee);
        return buyFee;
    }

    function test_Buy_DOLA(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        vm.startPrank(user);
        psm.buy(amount);
        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee
        assertEq(DOLA.balanceOf(user), amount - buyFee); // User should have DOLA bought minus fee
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(psm))), amount, 2); // Vault should have the collateral
    }

    function test_Sell_DOLA(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        uint256 initialCollateralBal = collateral.balanceOf(user);
        vm.startPrank(user);
        psm.buy(amount);
        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee
        uint256 dolaToSell = DOLA.balanceOf(user);
        assertEq(dolaToSell, amount - buyFee); // User should have D
        DOLA.approve(address(psm), dolaToSell);
        psm.sell(dolaToSell);
        vm.stopPrank();

        uint256 sellFee = dolaToSell * psm.sellFeeBps() / 10000; // 1% sell fee
        assertEq(DOLA.balanceOf(user), 0); // User should have no DOLA left
        assertEq(collateral.balanceOf(user), initialCollateralBal - (buyFee + sellFee)); // User gets back collateral minus fees
    }

    function test_SellDOLAWithFee(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);

        uint256 initialCollateralBal = collateral.balanceOf(user);
        vm.startPrank(user);
        psm.buy(user, amount);

        // Now burn All DOLA
        uint256 dolaToSell = DOLA.balanceOf(user);
        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee
        assertEq(dolaToSell, amount - buyFee); // User should have bought DOLA
        DOLA.approve(address(psm), dolaToSell);
        psm.sell(user, dolaToSell);
        vm.stopPrank();

        uint256 sellFee = dolaToSell * psm.sellFeeBps() / 10000; // 1% sell fee
        assertEq(collateral.balanceOf(gov), 0);
        assertEq(collateral.balanceOf(user), initialCollateralBal - (buyFee + sellFee)); // User gets back collateral minus fees
        // Vault should have only fees left
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(psm))), buyFee + sellFee, 3); // buy and sell fees
    }

    function test_SellDolaExceedSupply(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);

        vm.startPrank(user);
        psm.buy(user, amount);
        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee

        uint256 dolaToSell = DOLA.balanceOf(user);
        assertEq(dolaToSell, amount - buyFee); // User should have bought DOLA
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, dolaToSell);

        uint256 sellFee = dolaToSell * psm.sellFeeBps() / 10000; // 1% sell fee
        assertApproxEqAbs(vault.previewRedeem(vault.balanceOf(address(psm))), buyFee + sellFee, 3); // buy and sell fees
        assertApproxEqAbs(psm.getProfit(), buyFee + sellFee, 3); // No profit taken yet
        // Try to sell more DOLA than available in PSM
        deal(address(DOLA), user, buyFee + sellFee); // Mint some DOLA to user to attempt taking profit by selling
        vm.expectRevert();
        psm.sell(user, buyFee + sellFee);
        vm.stopPrank();
    }

    function test_TakeProfit(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);

        uint256 initialCollateralBal = collateral.balanceOf(user);
        // Buy some DOLA
        vm.prank(user);
        psm.buy(user, amount);

        // Take profit

        psm.takeProfit();

        uint256 buyFee = amount * psm.buyFeeBps() / 10000; // 0.5% buy fee
        // Check that profit was taken
        assertApproxEqAbs(collateral.balanceOf(gov), buyFee, 2);

        uint256 dolaToSell = DOLA.balanceOf(user);
        uint256 sellFee = dolaToSell * psm.sellFeeBps() / 10000; // 1% sell fee
        // User sells all DOLA
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, dolaToSell); // User sells DOLA
        vm.stopPrank();
        assertEq(psm.supply(), 0); // Supply should be zero after selling all DOLA
        assertApproxEqAbs(collateral.balanceOf(user), initialCollateralBal - (buyFee + sellFee), 2); // User gets back collateral minus fees
        assertEq(DOLA.balanceOf(user), 0); // User should have no DOLA left

        // Gov balance has profit + buyFee
        uint256 govBalanceAfter = collateral.balanceOf(gov);

        psm.takeProfit(); // Try to take profit again (fees from previous sell)
        assertApproxEqAbs(
            collateral.balanceOf(gov), govBalanceAfter + sellFee, 3, "Gov balance not correct after second take profit"
        );
    }

    function test_Migrate_Vault(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        uint256 fee = test_BuyDOLAWithFee(amount);

        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        // Ensure minTotalSupply is met
        _seedMinTotalSupply(newVault);

        uint256 minCollateralAmount = vault.previewRedeem(vault.balanceOf(address(psm)));
        uint256 minSharesOut = vault.previewDeposit(minCollateralAmount);
        vm.startPrank(gov);
        psm.migrate(address(newVault), minCollateralAmount / 2, minSharesOut * 95 / 100);
        assertEq(address(psm.vault()), address(newVault));
        // Profit was taken and transferred to governance plus the buy fee
        assertApproxEqAbs(collateral.balanceOf(gov), fee, 2, "Not correct profit and fees to gov");
        // Check new vault has the correct balance
        assertApproxEqAbs(
            newVault.balanceOf(address(psm)), amount - fee, 2, "Not correct vault balance after migration"
        );
    }

    function test_Fail_Migrate_Vault_if_below_minCollateralOut(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        test_BuyDOLAWithFee(amount);
        uint256 minCollateralAmount = vault.previewRedeem(vault.balanceOf(address(psm)));
        uint256 minSharesOut = vault.previewDeposit(minCollateralAmount);

        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        _seedMinTotalSupply(newVault);

        vm.prank(gov);
        vm.expectRevert("Insufficient collateral balance for migration");
        psm.migrate(address(newVault), minCollateralAmount * 2, minSharesOut); // Try to migrate with less than minCollateralAmount
    }

    function test_Fail_Migrate_Vault_if_below_minSharesOut(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        test_BuyDOLAWithFee(amount);
        uint256 minCollateralAmount = vault.previewRedeem(vault.balanceOf(address(psm)));

        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        _seedMinTotalSupply(newVault);
        uint256 minSharesOut = newVault.previewDeposit(minCollateralAmount);

        vm.prank(gov);
        vm.expectRevert("Insufficient shares received from new vault");
        psm.migrate(address(newVault), minCollateralAmount / 2, minSharesOut + 1); // Requesting more shares than possible
    }

    function test_Fail_Migrate_if_minTotalSupply_not_met(uint256 amount) public {
        vm.assume(amount > 0.000001 ether && amount <= 10000000 ether);
        test_BuyDOLAWithFee(amount);
        uint256 minCollateralAmount = vault.previewRedeem(vault.balanceOf(address(psm)));
        uint256 minSharesOut = vault.previewDeposit(minCollateralAmount);

        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        // Do not seed min total supply to fail migration
        vm.prank(gov);
        vm.expectRevert("New vault does not meet min total supply");
        psm.migrate(address(newVault), minCollateralAmount, minSharesOut);
    }

    function test_2_users_buy_then_migrate_with_profit_then_contract_and_sell() public {
        address user2 = address(0x456);
        deal(address(collateral), address(user2), 5000 ether); // Give user2 some collateral

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

        uint256 buyFee1 = amount1 * psm.buyFeeBps() / 10000; // 0.5% buy fee
        uint256 buyFee2 = amount2 * psm.buyFeeBps() / 10000; // 0.5% buy fee
        uint256 dolaToSell1 = DOLA.balanceOf(user);
        uint256 dolaToSell2 = DOLA.balanceOf(user2);
        // Check balances after both users bought DOLA
        assertEq(dolaToSell1, amount1 - buyFee1);
        assertEq(dolaToSell2, amount2 - buyFee2);

        assertEq(collateral.balanceOf(address(gov)), 0); // Gov should have no collateral yet

        deal(address(collateral), address(vault), 100000 ether); // Simulate profit in vault
        // Migrate to new vault
        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        _seedMinTotalSupply(newVault);
        uint256 minCollateralAmount = vault.previewRedeem(vault.balanceOf(address(psm)));
        uint256 minSharesOut = vault.previewDeposit(minCollateralAmount);
        vm.prank(gov);
        psm.migrate(address(newVault), minCollateralAmount / 2, minSharesOut * 95 / 100);
        // After migration, profit and fees should be taken and transferred to governance
        uint256 fee = (amount1 + amount2) * psm.buyFeeBps() / 10000; // 0.5% buy fee
        assertApproxEqAbs(collateral.balanceOf(gov), fee, 2); // Gov should have profit + buy fee

        // Check new vault has the correct balance
        assertApproxEqAbs(
            newVault.balanceOf(address(psm)), amount1 + amount2 - fee, 1, "Vault balance not correct after migration"
        );

        // Full contraction but can still sell DOLA
        vm.prank(gov);
        fed.contraction(DOLA.balanceOf(address(psm)));

        // User 1 sells DOLA
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, dolaToSell1);
        vm.stopPrank();
        // User 2 sells DOLA
        vm.startPrank(user2);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user2, dolaToSell2);
        vm.stopPrank();

        // Check both users got their collateral back minus fees
        assertEq(collateral.balanceOf(user), user1CollateralBal - (buyFee1 + dolaToSell1 * psm.sellFeeBps() / 10000));
        assertEq(collateral.balanceOf(user2), user2CollateralBal - (buyFee2 + dolaToSell2 * psm.sellFeeBps() / 10000));
    }

    function test_migrate_manually_via_gov_if_maxRedeem_lower_than_psm_balance() public {
        address user2 = address(0x456);
        deal(address(collateral), user2, 5000 ether); // Give user2 some collateral

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

        uint256 buyFee1 = amount1 * psm.buyFeeBps() / 10000; // 0.5% buy fee
        uint256 buyFee2 = amount2 * psm.buyFeeBps() / 10000; // 0.5% buy fee
        uint256 dolaToSell1 = DOLA.balanceOf(user);
        uint256 dolaToSell2 = DOLA.balanceOf(user2);
        // Check balances after both users bought DOLA
        assertEq(dolaToSell1, amount1 - buyFee1);
        assertEq(dolaToSell2, amount2 - buyFee2);

        assertEq(collateral.balanceOf(address(gov)), 0); // Gov should have no collateral yet

        // Migrate to new vault
        MockERC4626 newVault = new MockERC4626(ERC20(address(collateral)), "New Vault", "NEW");
        _seedMinTotalSupply(newVault);
        uint256 vaultBal = vault.balanceOf(address(psm));
        vm.prank(gov);
        psm.sweep(IERC20(address(vault))); // Sweep vault balance to gov
        assertEq(vaultBal, vault.balanceOf(gov));

        uint256 minCollateralAmount = vault.previewRedeem(vaultBal);
        vm.prank(gov);
        psm.migrate(address(newVault), 0, 0);
        //Block buy and sell(updating controller), users cannot buy or sell while migration is in progress
        vm.mockCall(address(controller), abi.encodeWithSelector(Controller.onBuy.selector), abi.encode(false));
        vm.mockCall(address(controller), abi.encodeWithSelector(Controller.onSell.selector), abi.encode(false));
        vm.startPrank(gov);
        vault.redeem(vaultBal / 2, gov, gov); // Redeem half vault balance to PSM
        // vm.warp(block.timestamp + 1 days); // Move time forward to allow migration
        vault.redeem(vaultBal / 2, gov, gov); // Redeem half vault balance to PSM
        assertApproxEqAbs(collateral.balanceOf(gov), vault.previewRedeem(vaultBal), 2, "Gov balance not correct"); // Gov should have all collateral balance

        collateral.approve(address(newVault), type(uint256).max);
        uint256 shares = newVault.deposit(collateral.balanceOf(gov), address(psm)); // Deposit all collateral to new vault
        assertEq(newVault.balanceOf(address(psm)), shares, "New vault balance not correct after migration");
        vm.stopPrank();

        assertApproxEqAbs(psm.getProfit(), buyFee1 + buyFee2, 4, "not profit"); // Kept previous profit
        assertApproxEqAbs(newVault.previewRedeem(newVault.balanceOf(address(psm))), psm.supply() + psm.getProfit(), 2); // New vault should have the correct balance
        // Set back controller to allow buy and sell
        vm.clearMockedCalls();

        // User 1 sells DOLA
        vm.startPrank(user);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user, dolaToSell1);
        vm.stopPrank();
        // User 2 sells DOLA
        vm.startPrank(user2);
        DOLA.approve(address(psm), type(uint256).max);
        psm.sell(user2, dolaToSell2);
        vm.stopPrank();
        uint256 sellFee1 = dolaToSell1 * psm.sellFeeBps() / 10000; // 1% sell fee
        uint256 sellFee2 = dolaToSell2 * psm.sellFeeBps() / 10000; // 1% sell fee
        assertApproxEqAbs(collateral.balanceOf(user), user1CollateralBal - (buyFee1 + sellFee1), 4); // User 1 gets back collateral minus fees
        // Profit should include fees from both users
        assertApproxEqAbs(psm.getProfit(), buyFee1 + buyFee2 + sellFee1 + sellFee2, 4);
        psm.takeProfit(); // Take profit

        // Check balances after taking profit
        assertApproxEqAbs(collateral.balanceOf(gov), buyFee1 + buyFee2 + sellFee1 + sellFee2, 4);
        assertEq(newVault.previewRedeem(newVault.balanceOf(address(psm))), psm.supply());
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
        psm.setBuyFeeBps(100);
        assertEq(psm.buyFeeBps(), 100);
        psm.setSellFeeBps(200);
        assertEq(psm.sellFeeBps(), 200);
    }

    function test_GovCanUpdateController() public {
        Controller newController = new Controller();
        vm.startPrank(gov);
        psm.setController(address(newController));
        assertEq(address(psm.controller()), address(newController));
    }

    function test_PendingGov() public {
        address newGov = address(0x456);
        vm.prank(gov);
        psm.setPendingGov(newGov);
        assertEq(psm.pendingGov(), newGov);
    }

    function test_ClaimPendingGov() public {
        address newGov = address(0x456);
        vm.prank(gov);
        psm.setPendingGov(newGov);
        vm.prank(newGov);
        psm.claimPendingGov();
        assertEq(psm.gov(), newGov);
        assertEq(psm.pendingGov(), address(0));
    }

    function test_NonGovCannotUpdateFees() public {
        vm.startPrank(user);
        vm.expectRevert("Not gov");
        psm.setBuyFeeBps(100);
        vm.expectRevert("Not gov");
        psm.setSellFeeBps(200);
    }

    function test_Fail_BuyFee_TooHigh() public {
        vm.startPrank(gov);
        vm.expectRevert("Fee too high");
        psm.setBuyFeeBps(10001); // 100.1%
        vm.stopPrank();
    }

    function test_Fail_SellFee_TooHigh() public {
        vm.startPrank(gov);
        vm.expectRevert("Fee too high");
        psm.setSellFeeBps(10001); // 100.1%
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
        vm.mockCall(address(psm.controller()), abi.encodeWithSelector(Controller.onBuy.selector), abi.encode(false));
        vm.mockCall(address(psm.controller()), abi.encodeWithSelector(Controller.onSell.selector), abi.encode(false));
        vm.startPrank(user);
        vm.expectRevert("Denied by controller");
        psm.buy(user, 1000 ether);
        vm.expectRevert("Denied by controller");
        psm.sell(user, 1000 ether);
        vm.stopPrank();
    }

    function test_getCollateralOut(uint256 dolaAmount) public {
        vm.assume(dolaAmount > 0 && dolaAmount <= 10000000 ether);
        uint256 expectedCollateralOut = dolaAmount - (dolaAmount * psm.sellFeeBps() / 10000); // 1% fee
        assertEq(psm.getCollateralOut(dolaAmount), expectedCollateralOut);
    }

    function test_getDolaOut(uint256 collateralIn) public {
        vm.assume(collateralIn > 0 && collateralIn <= 10000000 ether);
        uint256 expectedDolaOut = collateralIn - (collateralIn * psm.buyFeeBps() / 10000); // 0.5% fee
        assertEq(psm.getDolaOut(collateralIn), expectedDolaOut);
    }

    function test_getTotalReserves(uint256 collateralAmount) public {
        vm.assume(collateralAmount > 0.0001 ether && collateralAmount <= 10000000 ether);
        uint256 initialDolaBal = DOLA.balanceOf(address(psm));
        vm.startPrank(user);
        psm.buy(user, collateralAmount);
        vm.stopPrank();
        // Check total reserves after buying DOLA
        uint256 totalReserves = psm.getTotalReserves();
        assertApproxEqAbs(totalReserves, collateralAmount, 2, "Total reserve doesn't match collateral"); // Total reserves is USDS supply
        assertApproxEqAbs(totalReserves, psm.supply() + psm.getProfit(), 1, "Profit not correct"); // Should equal supply + profit
        assertApproxEqAbs(
            initialDolaBal - DOLA.balanceOf(address(psm)),
            collateralAmount - psm.getProfit(),
            2,
            "Dola balance not correct"
        ); // DOLA bought should match collateral supplied minus profit
        assertApproxEqAbs(
            totalReserves,
            psm.vault().previewRedeem(psm.vault().balanceOf(address(psm))),
            1,
            "Vault Balance not correct"
        ); // Should match vault balance
    }

    function test_getProfit() public {
        uint256 collateralAmount = 1000 ether;
        vm.startPrank(user);
        psm.buy(user, collateralAmount);
        vm.stopPrank();

        uint256 profit = psm.getProfit();
        assertApproxEqAbs(profit, (collateralAmount * psm.buyFeeBps() / 10000), 1); // Profit should equal to fees collected
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

    function _seedMinTotalSupply(MockERC4626 vault) internal {
        // Ensure minTotalSupply is met
        deal(address(collateral), firstDepositor, 100_001 ether); // Mint enough collateral to firstDepositor
        vm.startPrank(firstDepositor);
        collateral.approve(address(vault), type(uint256).max);
        vault.deposit(100_001 ether, firstDepositor);
        vm.stopPrank();
    }
}
