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

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

contract SupplyTest is Test {
    PSM psm;
    PSMFed fed;
    Controller controller;
    MockERC20 collateral;
    MockERC4626 vault;
    MockERC20 DOLA;
    address gov = address(0xfee);
    address operator = address(this);
    address attacker = address(0x123);
    address user = address(0x456);
    uint256 initialSupply = 1 ether;

    function setUp() public {
        collateral = new MockERC20();
        vault = new MockERC4626(ERC20(address(collateral)), "MOCK", "MOCK");
        DOLA = new MockERC20();

        collateral.mint(attacker, 10_000_000_001 ether);
        vm.startPrank(attacker);
        collateral.approve(address(vault), type(uint256).max);
        vault.deposit(initialSupply, attacker);
        assertEq(vault.balanceOf(attacker), initialSupply);
        collateral.mint(user, 10_000_000 ether);
        vm.stopPrank();
        vm.prank(user);
        collateral.approve(address(vault), type(uint256).max);
    }

    function test_totalSupply() public {
        vm.prank(attacker);
        collateral.transfer(address(vault), 10_000_000_000 ether);
        assertEq(vault.totalSupply(), initialSupply);
        vm.prank(user);
        vault.deposit(10_000_000 ether, user);
        console.log("Vault total supply after user deposit:", vault.totalSupply());
        console2.log(vault.balanceOf(user));
        console2.log(vault.previewRedeem(vault.balanceOf(user)));
        vm.startPrank(attacker);
        vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        console2.log("Attacker balance after redeem:", collateral.balanceOf(attacker));
        console2.log("Attacker balance after redeem:", collateral.balanceOf(attacker) / 1e18);

        vm.stopPrank();
        vm.startPrank(user);
        vault.redeem(vault.balanceOf(user), user, user);
        console2.log("User balance after redeem:", collateral.balanceOf(user));
        console2.log("User balance after redeem:", collateral.balanceOf(user) / 1e18);
        // 0.000000000000000001% is the precision for the assertApproxEqRel
        assertApproxEqRel(collateral.balanceOf(user), 10_000_000 ether, 0.000000000000000001 ether);
    }
}
