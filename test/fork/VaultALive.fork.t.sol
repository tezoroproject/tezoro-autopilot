// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";

/// @title VaultALive — fork tests against the deployed Vault A on Ethereum mainnet
/// @notice Tests the live vault at 0x6992B35d23A0B7732a6b0d6e6Fc10A76c08B3d16
///         Verifies: user flows, vault state, keeper operations, admin operations
contract VaultALive is Test {
    // -- Deployed addresses --
    TezoroV1_2 constant VAULT = TezoroV1_2(0x6992B35d23A0B7732a6b0d6e6Fc10A76c08B3d16);
    RewardsModuleV1_2 constant REWARDS = RewardsModuleV1_2(0x29054FC109E4746047ddc6124e6Db0ceAE24ab50);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Strategy addresses
    IStrategy constant AAVE_STRATEGY = IStrategy(0x72fEd3E0038635ed332C3121280c42339a65f05d);
    IStrategy constant COMPOUND_STRATEGY = IStrategy(0xEAF050076D402105e3121BE0833d6b6Af91588Fd);
    IStrategy constant SPARK_STRATEGY = IStrategy(0xa5D8da49d4DbF324d492a045058793F8b7a162C9);

    // Test users
    address alice;
    address bob;

    // On-chain roles (read in setUp)
    address admin;
    address keeper;
    address guardian;

    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // 10k USDC
    uint256 constant USER_BALANCE = 100_000e6; // 100k USDC

    function setUp() public {
        vm.createSelectFork("ethereum");

        // Read live roles from the vault
        admin = VAULT.admin();
        keeper = VAULT.keeper();
        guardian = VAULT.guardian();

        // Create test users
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Fund test users
        deal(address(USDC), alice, USER_BALANCE);
        deal(address(USDC), bob, USER_BALANCE);
    }

    // -----------------------------------------------------------------------
    // Vault state verification
    // -----------------------------------------------------------------------

    function test_live_strategies_registered() public view {
        IStrategy[] memory strats = VAULT.getStrategies();
        assertEq(strats.length, 3, "Should have 3 strategies");
        assertEq(address(strats[0]), address(AAVE_STRATEGY), "Strategy 0 is Aave");
        assertEq(address(strats[1]), address(COMPOUND_STRATEGY), "Strategy 1 is Compound");
        assertEq(address(strats[2]), address(SPARK_STRATEGY), "Strategy 2 is Spark");
    }

    function test_live_fee_config() public view {
        assertEq(VAULT.performanceFeeBps(), 1_500, "Performance fee should be 15%");
        assertEq(VAULT.idleBufferBps(), 300, "Idle buffer should be 3%");
    }

    function test_live_roles() public view {
        assertTrue(admin != address(0), "Admin should be set");
        assertTrue(keeper != address(0), "Keeper should be set");
        // Guardian may or may not be set on the live vault
    }

    function test_live_all_strategies_healthy() public view {
        assertTrue(AAVE_STRATEGY.isHealthy(), "Aave should be healthy");
        assertTrue(COMPOUND_STRATEGY.isHealthy(), "Compound should be healthy");
        assertTrue(SPARK_STRATEGY.isHealthy(), "Spark should be healthy");
    }

    function test_live_asset_is_usdc() public view {
        assertEq(address(VAULT.asset()), address(USDC), "Vault asset should be USDC");
    }

    function test_live_rewards_module_set() public view {
        assertEq(VAULT.rewardsModule(), address(REWARDS), "Rewards module should match");
    }

    function test_live_vault_not_paused() public view {
        assertFalse(VAULT.paused(), "Vault should not be paused");
    }

    function test_live_totalAssets_positive() public view {
        uint256 total = VAULT.totalAssets();
        assertGt(total, 0, "Total assets should be positive if vault has deposits");
    }

    // -----------------------------------------------------------------------
    // User flows
    // -----------------------------------------------------------------------

    function test_live_deposit() public {
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        uint256 shares = VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertGt(VAULT.balanceOf(alice), 0, "Alice should have vault shares");
    }

    function test_live_withdraw_from_idle() public {
        // Deposit first
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);

        // Withdraw a small amount (should come from idle)
        uint256 withdrawAmount = 1_000e6;
        uint256 balanceBefore = USDC.balanceOf(alice);
        VAULT.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        uint256 balanceAfter = USDC.balanceOf(alice);
        assertGe(balanceAfter - balanceBefore, withdrawAmount, "Should receive at least withdraw amount");
    }

    function test_live_withdraw_waterfall() public {
        // Deposit a large amount
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Rebalance to push funds into strategies
        vm.prank(keeper);
        VAULT.rebalance();

        // Now withdraw everything — should pull from strategies
        uint256 shares = VAULT.balanceOf(alice);
        vm.startPrank(alice);
        uint256 assets = VAULT.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(assets, 0, "Should redeem assets");
        assertEq(VAULT.balanceOf(alice), 0, "Alice should have 0 shares after full redeem");
    }

    function test_live_redeem_all() public {
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);

        uint256 shares = VAULT.balanceOf(alice);
        uint256 assets = VAULT.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(assets, 0, "Should receive assets");
        assertEq(VAULT.balanceOf(alice), 0, "Should have 0 shares");
    }

    function test_live_approve_then_deposit() public {
        vm.startPrank(alice);

        // Approve exact amount, then deposit
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        assertGe(USDC.allowance(alice, address(VAULT)), DEPOSIT_AMOUNT, "Allowance should be set");

        uint256 shares = VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares from deposit");
    }

    function test_live_deposit_reverts_when_paused() public {
        // Pause the vault
        vm.prank(admin);
        VAULT.pauseVault();

        // Attempt deposit — should revert
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        vm.expectRevert();
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Cleanup: unpause
        vm.prank(admin);
        VAULT.unpauseVault();
    }

    function test_live_multiple_users_deposit_withdraw() public {
        // Alice deposits
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Bob deposits
        vm.startPrank(bob);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Both should have shares
        assertGt(VAULT.balanceOf(alice), 0, "Alice has shares");
        assertGt(VAULT.balanceOf(bob), 0, "Bob has shares");

        // Alice redeems
        vm.startPrank(alice);
        VAULT.redeem(VAULT.balanceOf(alice), alice, alice);
        vm.stopPrank();

        // Bob still has shares
        assertGt(VAULT.balanceOf(bob), 0, "Bob still has shares");
        assertEq(VAULT.balanceOf(alice), 0, "Alice has 0 shares");

        // Bob redeems
        vm.startPrank(bob);
        VAULT.redeem(VAULT.balanceOf(bob), bob, bob);
        vm.stopPrank();

        assertEq(VAULT.balanceOf(bob), 0, "Bob has 0 shares");
    }

    // -----------------------------------------------------------------------
    // Vault operations (keeper-pranked)
    // -----------------------------------------------------------------------

    function test_live_reconcile() public {
        uint256 totalBefore = VAULT.totalAssets();

        vm.prank(keeper);
        VAULT.reconcile();

        uint256 totalAfter = VAULT.totalAssets();
        // After reconcile, totalAssets may change (yield accrued)
        // Just verify it doesn't revert and value is sane
        assertGe(totalAfter, 0, "Total assets should be non-negative");
        // Allow small deviation from before (yield could be positive or rounding)
        assertGe(totalAfter, (totalBefore * 99) / 100, "Total assets should not drop significantly");
    }

    function test_live_rebalance() public {
        // Deposit to add idle funds
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        uint256 idleBefore = VAULT.idleBalance();

        vm.prank(keeper);
        VAULT.rebalance();

        uint256 idleAfter = VAULT.idleBalance();
        // After rebalance, idle should decrease (funds deployed to strategies)
        assertLe(idleAfter, idleBefore, "Idle should decrease after rebalance");

        // Cleanup: redeem alice's shares
        vm.startPrank(alice);
        VAULT.redeem(VAULT.balanceOf(alice), alice, alice);
        vm.stopPrank();
    }

    function test_live_collectFees() public {
        // Deposit and let time pass for yield
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        VAULT.rebalance();

        // Time warp to accrue yield
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // Reconcile to track yield
        vm.prank(keeper);
        VAULT.reconcile();

        // Collect fees
        vm.prank(keeper);
        VAULT.collectFees();

        // Cleanup
        vm.startPrank(alice);
        VAULT.redeem(VAULT.balanceOf(alice), alice, alice);
        vm.stopPrank();
    }

    function test_live_harvestAll() public {
        // Deposit and deploy to strategies
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(keeper);
        VAULT.rebalance();

        // Time warp for rewards to accrue
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);

        // Harvest all
        vm.prank(keeper);
        VAULT.harvestAll();

        // Cleanup
        vm.startPrank(alice);
        VAULT.redeem(VAULT.balanceOf(alice), alice, alice);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Management operations (admin-pranked)
    // -----------------------------------------------------------------------

    function test_live_forceRedeem() public {
        // Alice deposits
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        uint256 sharesBefore = VAULT.balanceOf(alice);
        assertGt(sharesBefore, 0, "Alice should have shares");

        // Admin force-redeems Alice
        vm.prank(admin);
        VAULT.forceRedeem(alice);

        assertEq(VAULT.balanceOf(alice), 0, "Alice should have 0 shares after force redeem");
    }

    function test_live_pause_unpause() public {
        // Pause
        vm.prank(admin);
        VAULT.pauseVault();
        assertTrue(VAULT.paused(), "Vault should be paused");

        // Unpause
        vm.prank(admin);
        VAULT.unpauseVault();
        assertFalse(VAULT.paused(), "Vault should be unpaused");
    }

    function test_live_guardian_can_pause() public {
        if (guardian == address(0)) return; // Skip if no guardian set
        vm.prank(guardian);
        VAULT.pauseVault();
        assertTrue(VAULT.paused(), "Guardian should be able to pause");

        // Cleanup: admin unpause
        vm.prank(admin);
        VAULT.unpauseVault();
    }

    function test_live_guardian_cannot_unpause() public {
        if (guardian == address(0)) return; // Skip if no guardian set
        vm.prank(admin);
        VAULT.pauseVault();

        vm.prank(guardian);
        vm.expectRevert();
        VAULT.unpauseVault();

        // Cleanup
        vm.prank(admin);
        VAULT.unpauseVault();
    }

    function test_live_nonAdmin_cannot_pause() public {
        vm.prank(alice);
        vm.expectRevert();
        VAULT.pauseVault();
    }

    function test_live_nonKeeper_cannot_rebalance() public {
        vm.prank(alice);
        vm.expectRevert();
        VAULT.rebalance();
    }

    // -----------------------------------------------------------------------
    // Full lifecycle
    // -----------------------------------------------------------------------

    function test_live_full_lifecycle() public {
        // 1. Deposit
        vm.startPrank(alice);
        USDC.approve(address(VAULT), DEPOSIT_AMOUNT);
        uint256 shares = VAULT.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
        assertGt(shares, 0, "Step 1: shares received");

        // 2. Rebalance — deploy to strategies
        vm.prank(keeper);
        VAULT.rebalance();

        // 3. Time warp — yield accrues
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile — sync yield
        vm.prank(keeper);
        VAULT.reconcile();

        // 5. Collect fees
        vm.prank(keeper);
        VAULT.collectFees();

        // 6. Harvest rewards
        vm.prank(keeper);
        VAULT.harvestAll();

        // 7. Full redeem
        uint256 aliceShares = VAULT.balanceOf(alice);
        vm.startPrank(alice);
        uint256 redeemedAssets = VAULT.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        // Should get back at least what was deposited (yield)
        assertGe(redeemedAssets, DEPOSIT_AMOUNT, "Should get back at least deposited amount");
        assertEq(VAULT.balanceOf(alice), 0, "Should have 0 shares");
    }
}
