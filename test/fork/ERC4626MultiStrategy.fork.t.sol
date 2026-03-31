// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategy} from "../../src/strategies/ERC4626MultiStrategy.sol";

// Real Ethereum mainnet addresses
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// MetaMorpho USDC vaults (ERC-4626)
address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
address constant GAUNTLET_USDC_CORE = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

/// @notice Fork test for ERC4626MultiStrategy against real MetaMorpho vaults on Ethereum mainnet.
contract ERC4626MultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategy strategy;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    uint256 constant DEPOSIT_AMOUNT = 100_000e6; // 100k USDC

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new ERC4626MultiStrategy(USDC, vaultAddr, adminAddr, "MetaMorpho USDC", 64, new address[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(STEAKHOUSE_USDC);
        strategy.addSubVault(GAUNTLET_USDC_CORE);
        vm.stopPrank();

        // Fund the vault with USDC
        deal(USDC, vaultAddr, DEPOSIT_AMOUNT * 3);
        vm.prank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), type(uint256).max);
    }

    // ========== Basic lifecycle ==========

    function test_deposit_holdsIdle() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        assertEq(IERC20(USDC).balanceOf(address(strategy)), DEPOSIT_AMOUNT);
        assertEq(strategy.balanceOf(), DEPOSIT_AMOUNT);
    }

    function test_allocate_toRealMetaMorphoVault() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 50_000e6);

        // Idle should be ~50k
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 50_000e6);

        // Sub-vault balance should be ~50k (minus rounding)
        uint256 steakhouseBal = strategy.subVaultBalance(STEAKHOUSE_USDC);
        assertGe(steakhouseBal, 49_999e6);
        assertLe(steakhouseBal, 50_001e6);
    }

    function test_allocate_toMultipleVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 60_000e6);
        strategy.allocate(GAUNTLET_USDC_CORE, 30_000e6);
        vm.stopPrank();

        // 10k idle
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 10_000e6);

        // Total balance should be ~100k
        assertGe(strategy.balanceOf(), 99_999e6);
        assertLe(strategy.balanceOf(), 100_001e6);
    }

    function test_deallocate_fromRealVault() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 80_000e6);

        // Deallocate 30k back
        vm.prank(keeperAddr);
        strategy.deallocate(STEAKHOUSE_USDC, 30_000e6);

        // Idle should be ~50k (20k original + 30k deallocated)
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idle, 49_999e6);
        assertLe(idle, 50_001e6);
    }

    // ========== Withdraw waterfall ==========

    function test_withdraw_fromIdleOnly() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(40_000e6);

        assertEq(withdrawn, 40_000e6);
        assertEq(IERC20(USDC).balanceOf(vaultAddr), DEPOSIT_AMOUNT * 3 - DEPOSIT_AMOUNT + 40_000e6);
    }

    function test_withdraw_waterfallThroughRealVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        // Allocate everything
        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 50_000e6);
        strategy.allocate(GAUNTLET_USDC_CORE, 50_000e6);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);

        // Withdraw 70k -- must pull from sub-vaults
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(70_000e6);

        assertGe(withdrawn, 69_999e6);
    }

    function test_withdraw_idlePlusSubVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 70_000e6);

        // Idle = 30k, Steakhouse = 70k. Withdraw 60k.
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(60_000e6);

        // Should get full 60k (30k idle + 30k from Steakhouse)
        assertGe(withdrawn, 59_999e6);
    }

    // ========== Emergency ==========

    function test_emergencyWithdraw_collectsFromAllRealVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 40_000e6);
        strategy.allocate(GAUNTLET_USDC_CORE, 40_000e6);
        vm.stopPrank();

        // 20k idle + 40k Steakhouse + 40k Gauntlet
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertGe(withdrawn, 99_999e6);
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);
    }

    // ========== Views against real data ==========

    function test_balanceOf_aggregatesRealVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 50_000e6);
        strategy.allocate(GAUNTLET_USDC_CORE, 30_000e6);
        vm.stopPrank();

        // 20k idle + 50k + 30k = 100k
        uint256 bal = strategy.balanceOf();
        assertGe(bal, 99_999e6);
        assertLe(bal, 100_001e6);
    }

    function test_availableLiquidity_aggregatesRealVaults() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 60_000e6);

        uint256 avail = strategy.availableLiquidity();
        // Should be ~100k (40k idle + ~60k from Steakhouse maxWithdraw)
        assertGe(avail, 99_999e6);
    }

    function test_isHealthy_withRealVaults() public view {
        // MetaMorpho vaults have real deposits, so totalAssets > 0
        assertTrue(strategy.isHealthy());
    }

    // ========== Admin operations against real vaults ==========

    function test_addSubVault_revertsOnAssetMismatch_real() public {
        // WETH vault -- wrong asset for USDC strategy
        // Fluid WETH fToken is ERC-4626 with WETH as asset
        address fluidWETH = 0x90551c1795392094FE6D29B758EcCD233cFAa260;
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategy.AssetMismatch.selector);
        strategy.addSubVault(fluidWETH);
    }

    function test_removeSubVault_thenAllocateReverts() public {
        vm.prank(adminAddr);
        strategy.removeSubVault(STEAKHOUSE_USDC);

        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategy.SubVaultNotApproved.selector);
        strategy.allocate(STEAKHOUSE_USDC, 50_000e6);
    }

    // ========== Sub-vault view helpers ==========

    function test_subVaultBalance_perVault() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 60_000e6);
        strategy.allocate(GAUNTLET_USDC_CORE, 20_000e6);
        vm.stopPrank();

        uint256 steakhouseBal = strategy.subVaultBalance(STEAKHOUSE_USDC);
        uint256 gauntletBal = strategy.subVaultBalance(GAUNTLET_USDC_CORE);

        assertGe(steakhouseBal, 59_999e6);
        assertLe(steakhouseBal, 60_001e6);
        assertGe(gauntletBal, 19_999e6);
        assertLe(gauntletBal, 20_001e6);
    }

    function test_getSubVaults_returnsAdded() public view {
        address[] memory vaults = strategy.getSubVaults();
        assertEq(vaults.length, 2);
        assertEq(vaults[0], STEAKHOUSE_USDC);
        assertEq(vaults[1], GAUNTLET_USDC_CORE);
    }

    // ========== Security hardening ==========

    function test_yieldAccrual_afterTimeWarp() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, DEPOSIT_AMOUNT);

        uint256 balBefore = strategy.balanceOf();

        // Warp 30 days forward
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        uint256 balAfter = strategy.balanceOf();

        // MetaMorpho vaults auto-compound, so balance should increase
        assertGt(balAfter, balBefore, "yield should accrue over 30 days");
    }

    function test_withdraw_moreThanBalance_returnsCapped() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, DEPOSIT_AMOUNT);

        uint256 balBefore = strategy.balanceOf();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        // Should return all available, not revert
        assertGe(withdrawn, balBefore - 1e6, "should withdraw nearly all");
        assertLe(withdrawn, balBefore + 1e6, "should not exceed balance");
    }

    function test_twoStepAdminTransfer_fullFlow() public {
        address newAdmin = makeAddr("newAdmin");

        // Step 1: current admin proposes transfer
        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);

        // Admin should still be the old one
        assertEq(strategy.admin(), adminAddr);

        // Step 2: new admin accepts
        vm.prank(newAdmin);
        strategy.acceptAdmin();

        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));
    }

    function test_recallSubVault_realVault() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, 80_000e6);

        uint256 idleBefore = IERC20(USDC).balanceOf(address(strategy));
        assertEq(idleBefore, 20_000e6);

        // Recall pulls all shares back and freezes deposits
        vm.prank(adminAddr);
        strategy.recallSubVault(STEAKHOUSE_USDC);

        // Sub-vault should be deposit-frozen
        assertTrue(strategy.depositFrozenSubVaults(STEAKHOUSE_USDC));

        // Idle should have recovered the allocated funds
        uint256 idleAfter = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idleAfter, 99_999e6, "idle should recover allocated funds");

        // No shares should remain in the sub-vault
        uint256 remainingShares = IERC4626(STEAKHOUSE_USDC).balanceOf(address(strategy));
        assertEq(remainingShares, 0, "all shares should be redeemed");
    }

    function test_sweepReward_revertsOnUSDC() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategy.CannotSweepAsset.selector);
        strategy.sweepReward(USDC, vaultAddr);
    }

    function test_sweepReward_revertsOnShareToken() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        // STEAKHOUSE_USDC is an approved sub-vault, so isApproved[STEAKHOUSE_USDC] == true
        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategy.CannotSweepAsset.selector);
        strategy.sweepReward(STEAKHOUSE_USDC, vaultAddr);
    }

    function test_multiCycle_allocDeallocSolvency() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        uint256 initialBal = strategy.balanceOf();

        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(keeperAddr);

            // Allocate to both vaults
            strategy.allocate(STEAKHOUSE_USDC, 30_000e6);
            strategy.allocate(GAUNTLET_USDC_CORE, 20_000e6);

            // Deallocate everything back to idle
            uint256 steakhouseBal = strategy.subVaultBalance(STEAKHOUSE_USDC);
            uint256 gauntletBal = strategy.subVaultBalance(GAUNTLET_USDC_CORE);
            strategy.deallocate(STEAKHOUSE_USDC, steakhouseBal);
            strategy.deallocate(GAUNTLET_USDC_CORE, gauntletBal);

            vm.stopPrank();
        }

        uint256 finalBal = strategy.balanceOf();

        // Final balance should be within 0.1% of initial (rounding losses only)
        uint256 tolerance = initialBal / 1000; // 0.1%
        assertGe(finalBal, initialBal - tolerance, "solvency: balance dropped more than 0.1%");
        assertLe(finalBal, initialBal + tolerance, "solvency: balance grew unexpectedly");
    }
}
