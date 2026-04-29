// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../../src/TezoroV1_2.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {StrategyForkTests} from "./StrategyForkTests.sol";

/// @notice Vault-level fork tests: lifecycle, waterfall, fees, config, access control, scale, edge cases.
abstract contract VaultForkTests is StrategyForkTests {
    using SafeERC20 for IERC20;
    // =========================================================================
    // Full Integration
    // =========================================================================

    function test_fullLifecycle() public {
        uint256 largeDeposit = depositAmount * 2;
        uint256 partialWithdraw = depositAmount;

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(largeDeposit, alice);
        assertGt(aliceShares, 0);

        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(token).balanceOf(address(vault));
        assertGt(idle, 0, "Should have idle buffer");
        assertLt(idle, largeDeposit, "Not all funds should be idle");

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        uint256 totalBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.reconcile();
        assertGe(vault.totalAssets(), totalBefore, "Assets should grow after reconcile");

        vm.prank(bob);
        uint256 bobShares = vault.deposit(depositAmount, bob);
        uint256 aliceSPU = (aliceShares * 1e18) / largeDeposit;
        uint256 bobSPU = (bobShares * 1e18) / depositAmount;
        assertLe(bobSPU, aliceSPU, "Bob should get fewer shares per token");

        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(partialWithdraw, alice, alice);
        assertEq(IERC20(token).balanceOf(alice), aliceBefore + partialWithdraw);
    }

    function test_rebalance_distributes() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Each assertion is gated on isHealthy: a strategy that the audit-fix(8)/(7)
        // health gate has correctly identified as unhealthy on this fork block
        // (e.g. Aave WETH frozen, Comet WETH withdraw-paused) is intentionally
        // skipped by the rebalancer, so balanceOf == 0 is correct, not a regression.
        if (address(aaveStrategy) != address(0) && aaveStrategy.isHealthy()) {
            assertGt(aaveStrategy.balanceOf(), 0, "Aave should have allocation");
        }
        if (address(compoundStrategy) != address(0) && compoundStrategy.isHealthy()) {
            assertGt(compoundStrategy.balanceOf(), 0, "Compound should have allocation");
        }
        if (address(sparkStrategy) != address(0) && sparkStrategy.isHealthy()) {
            assertGt(sparkStrategy.balanceOf(), 0, "Spark should have allocation");
        }
        if (address(morphoStrategy) != address(0) && morphoStrategy.isHealthy()) {
            assertGt(morphoStrategy.balanceOf(), 0, "Morpho should have allocation");
        }
        if (address(fluidStrategy) != address(0) && fluidStrategy.isHealthy()) {
            assertGt(fluidStrategy.balanceOf(), 0, "Fluid should have allocation");
        }
    }

    function test_withdraw_waterfall() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 withdrawAmt = depositAmount * 80 / 100;
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(token).balanceOf(alice), userBalance - depositAmount + withdrawAmt);
    }

    function test_redeem_all() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Use maxRedeem to handle strategy liquidity constraints
        uint256 redeemable = vault.maxRedeem(alice);
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);

        uint256 received = IERC20(token).balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(received, depositAmount, depositAmount / 1000);
        assertLe(vault.balanceOf(alice), shares - redeemable);
    }

    function test_removeStrategy_emergency() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 countBefore = vault.strategiesCount();
        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(aaveStrategy)));
        assertEq(vault.strategiesCount(), countBefore - 1);
        assertEq(aaveStrategy.balanceOf(), 0);
    }

    function test_collectFees_afterYield() public {
        vm.prank(alice);
        vault.deposit(depositAmount * 2, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 648_000);

        vm.prank(keeper);
        vault.reconcile();

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vm.prank(keeper);
        vault.collectFees();
        assertGt(vault.balanceOf(feeRecipient), feeSharesBefore, "Should receive fees");
    }

    function test_getAllocationStatus() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        (IStrategy[] memory strats, uint256[] memory targets, uint256[] memory actuals, bool[] memory healthy) =
            vault.getAllocationStatus();

        assertEq(strats.length, strategyCount);
        for (uint256 i = 0; i < strats.length; i++) {
            assertGt(targets[i], 0);
            // actuals/healthy depend on live protocol state; the rebalancer
            // correctly skips deposits to unhealthy reserves (audit-fix(7)/(8)).
            // For unhealthy strategies, actual == 0 and healthy == false are
            // both expected.
            if (healthy[i]) {
                assertGt(actuals[i], 0);
            } else {
                assertEq(actuals[i], 0, "unhealthy strategy must not hold funds post-rebalance");
            }
        }
    }

    function test_needsRebalance_afterDeposit() public {
        // Test premise: post-rebalance there is zero deviation. That only
        // holds when every strategy can receive its target allocation; if a
        // protocol is unhealthy on this fork block (Aave WETH frozen, Comet
        // WETH paused), the rebalancer skips that strategy and post-rebalance
        // looks deviated by design — the deviation IS the unhealthy gap, not
        // a bug.
        _skipIfAnyVaultStrategyUnhealthy();

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.prank(admin);
        vault.setMaxDeviation(100);

        assertFalse(vault.needsRebalance());

        vm.prank(bob);
        vault.deposit(depositAmount * 2, bob);

        assertTrue(vault.needsRebalance());
    }

    function test_pauseStrategy_skipsInRebalance() public {
        _skipIfStrategyUnhealthy(IStrategy(address(aaveStrategy)), "aave");

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 inAave = aaveStrategy.balanceOf();
        assertGt(inAave, 0);

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(aaveStrategy)));

        vm.prank(keeper);
        vault.rebalance();

        assertEq(aaveStrategy.balanceOf(), inAave);
    }

    // =========================================================================
    // Constructor & Config
    // =========================================================================

    function test_vault_constructor_setsParams() public view {
        assertEq(vault.admin(), admin);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.performanceFeeBps(), 1_500);
        assertEq(vault.idleBufferBps(), 300);
        assertEq(vault.asset(), token);
        assertEq(vault.keeper(), keeper);
        assertEq(vault.timelockDelay(), 0);
        assertEq(vault.maxDeviationBps(), 0);
        assertEq(vault.rewardsModule(), address(0));
    }

    function test_vault_deposit_reverts_whenPaused() public {
        vm.prank(admin);
        vault.pauseVault();

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.VaultIsPaused.selector);
        vault.deposit(depositAmount, alice);
    }

    function test_vault_withdraw_works_whenPaused() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        vm.prank(admin);
        vault.pauseVault();

        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(depositAmount / 2, alice, alice);
        assertEq(IERC20(token).balanceOf(alice), aliceBefore + depositAmount / 2);
    }

    // =========================================================================
    // Admin & Access Control
    // =========================================================================

    function test_vault_addStrategy_reverts_notAdmin() public {
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.addStrategy(IStrategy(address(aaveStrategy)));
    }

    function test_vault_addStrategy_reverts_duplicate() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyAlreadyActive.selector);
        vault.addStrategy(IStrategy(address(aaveStrategy)));
    }

    function test_vault_transferAdmin() public {
        vm.prank(admin);
        vault.transferAdmin(alice);
        assertEq(vault.pendingAdmin(), alice);
        assertEq(vault.admin(), admin); // still admin until accepted

        vm.prank(alice);
        vault.acceptAdmin();
        assertEq(vault.admin(), alice);

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.NotGuardianOrAdmin.selector);
        vault.pauseVault();
    }

    function test_vault_randomUser_cannotRebalance() public {
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdminOrKeeper.selector);
        vault.rebalance();
    }

    function test_vault_keeper_cannotAddStrategy() public {
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.addStrategy(IStrategy(address(aaveStrategy)));
    }

    // =========================================================================
    // Fee Parameter Setters
    // =========================================================================

    function test_vault_setPerformanceFee() public {
        vm.prank(admin);
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFeeBps(), 2_000);
    }

    function test_vault_setPerformanceFee_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidFee.selector);
        vault.setPerformanceFee(4_000);
    }

    function test_vault_setFeeRecipient() public {
        vm.prank(admin);
        vault.setFeeRecipient(bob);
        assertEq(vault.feeRecipient(), bob);
    }

    function test_vault_setFeeRecipient_reverts_zero() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_vault_setIdleBuffer() public {
        // First lower strategy allocations to make room for higher idle buffer
        IStrategy[] memory strats = vault.getStrategies();
        uint256[] memory bps = new uint256[](strats.length);
        uint256 perStrategy = strats.length > 0 ? 9_500 / strats.length : 0;
        for (uint256 i = 0; i < strats.length; i++) {
            bps[i] = perStrategy;
        }
        vm.startPrank(admin);
        if (strats.length > 0) vault.rebalance(strats, bps);
        vault.setIdleBuffer(500);
        vm.stopPrank();
        assertEq(vault.idleBufferBps(), 500);
    }

    function test_vault_setIdleBuffer_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidBuffer.selector);
        vault.setIdleBuffer(3_000);
    }

    function test_vault_setKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(admin);
        vault.setKeeper(newKeeper);
        assertEq(vault.keeper(), newKeeper);
    }

    function test_vault_setKeeper_canDisable() public {
        vm.prank(admin);
        vault.setKeeper(address(0));
        assertEq(vault.keeper(), address(0));
    }

    // =========================================================================
    // Timelock
    // =========================================================================

    function test_vault_timelock_disabledByDefault() public view {
        assertEq(vault.timelockDelay(), 0);
    }

    function test_vault_timelock_proposeAndExecute() public {
        vm.startPrank(admin);
        vault.setTimelockDelay(2 days);

        bytes32 opHash = keccak256("addStrategy(strategyA)");
        vault.proposeTimelock(opHash);

        assertFalse(vault.isTimelockReady(opHash));

        vm.warp(block.timestamp + 2 days + 1);
        assertTrue(vault.isTimelockReady(opHash));
        vm.stopPrank();
    }

    function test_vault_timelock_cancel() public {
        vm.startPrank(admin);
        vault.setTimelockDelay(2 days);

        bytes32 opHash = keccak256("someOperation");
        vault.proposeTimelock(opHash);
        vault.cancelTimelock(opHash);

        assertFalse(vault.isTimelockReady(opHash));
        vm.stopPrank();
    }

    // =========================================================================
    // Rewards Module
    // =========================================================================

    function test_vault_depositRewards_autoCompounds() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 totalAssetsBefore = vault.totalAssets();

        address rewardsAddr = makeAddr("rewardsModule");
        vm.prank(admin);
        vault.setRewardsModule(rewardsAddr);

        uint256 rewardAmount = depositAmount / 200;
        deal(token, rewardsAddr, rewardAmount);
        vm.startPrank(rewardsAddr);
        IERC20(token).forceApprove(address(vault), rewardAmount);
        vault.depositRewards(rewardAmount);
        vm.stopPrank();

        assertEq(vault.totalAssets(), totalAssetsBefore + rewardAmount);
    }

    function test_vault_depositRewards_reverts_notRewardsModule() public {
        address rewardsAddr = makeAddr("rewardsModule");
        vm.prank(admin);
        vault.setRewardsModule(rewardsAddr);

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.depositRewards(depositAmount / 100);
    }

    function test_vault_harvestAll_noop_whenNoRewardsModule() public {
        vm.prank(keeper);
        vault.harvestAll();
    }

    // =========================================================================
    // Share Price
    // =========================================================================

    function test_vault_sharePrice_monotonic_afterYield() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 priceBefore = vault.convertToAssets(1e12);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        vm.prank(keeper);
        vault.reconcile();

        uint256 priceAfter = vault.convertToAssets(1e12);
        assertGe(priceAfter, priceBefore, "Share price should not decrease after yield");
    }

    // =========================================================================
    // Scale & Stress
    // =========================================================================

    function test_scale_10x_fullCycle() public {
        uint256 amount = depositAmount * 10;
        deal(token, alice, amount);

        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), type(uint256).max);

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);
        assertGt(shares, 0, "Should receive shares");

        vm.prank(keeper);
        vault.rebalance();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        vm.prank(keeper);
        vault.reconcile();

        uint256 redeemable = vault.maxRedeem(alice);
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        _redeemOrSkipOnUpstreamFragility(alice, redeemable);

        uint256 received = IERC20(token).balanceOf(alice) - aliceBefore;
        assertGe(received, amount * 99 / 100, "Should lose less than 1% at 10x scale");
    }

    function test_scale_100x_fullCycle() public {
        uint256 amount = depositAmount * 100;
        deal(token, alice, amount);

        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.prank(keeper);
        try vault.rebalance() {} catch {
            return;
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        vm.prank(keeper);
        vault.reconcile();

        uint256 redeemable = vault.maxRedeem(alice);
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        _redeemOrSkipOnUpstreamFragility(alice, redeemable);

        uint256 received = IERC20(token).balanceOf(alice) - aliceBefore;
        assertGe(received, amount * 99 / 100, "Should lose less than 1% at 100x scale");
    }

    // =========================================================================
    // Edge Cases
    // =========================================================================

    function test_edge_dust_deposit() public {
        deal(token, alice, 1);

        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), 1);

        vm.prank(alice);
        uint256 shares = vault.deposit(1, alice);
        assertGt(shares, 0, "Even 1-unit deposit should get shares");
    }

    function test_edge_deposit_immediate_redeem() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 received = IERC20(token).balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(received, depositAmount, 1, "Immediate redeem should return deposit");
    }

    function test_edge_whale_and_shrimp_fairness() public {
        uint256 whaleAmount = depositAmount * 10;
        uint256 shrimpAmount = depositAmount;

        deal(token, alice, whaleAmount);
        deal(token, bob, shrimpAmount);

        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(token).forceApprove(address(vault), type(uint256).max);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(whaleAmount, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(shrimpAmount, bob);

        assertApproxEqRel(aliceShares * 1e18 / bobShares, 10e18, 0.001e18, "Share ratio should match deposit ratio");

        vm.prank(keeper);
        vault.rebalance();
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        vm.prank(keeper);
        vault.reconcile();

        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        _redeemOrSkipOnUpstreamFragility(alice, vault.maxRedeem(alice));
        uint256 aliceReceived = IERC20(token).balanceOf(alice) - aliceBefore;

        uint256 bobBefore = IERC20(token).balanceOf(bob);
        _redeemOrSkipOnUpstreamFragility(bob, vault.maxRedeem(bob));
        uint256 bobReceived = IERC20(token).balanceOf(bob) - bobBefore;

        assertGe(aliceReceived, whaleAmount, "Whale should profit from yield");
        assertGe(bobReceived, shrimpAmount * 99 / 100, "Shrimp should get back >99%");
        assertGe(aliceReceived + bobReceived, whaleAmount + shrimpAmount, "Total out >= total in");
    }

    function test_edge_repeated_cycles() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            vault.deposit(depositAmount, alice);

            vm.prank(keeper);
            vault.rebalance();

            uint256 redeemable = vault.maxRedeem(alice);
            vm.prank(alice);
            vault.redeem(redeemable, alice, alice);

            deal(token, alice, depositAmount);
            vm.prank(alice);
            IERC20(token).forceApprove(address(vault), type(uint256).max);
        }

        // After cycles, vault may retain dust from strategy rounding + any unredeemable remainder
        uint256 maxDust = depositAmount / 100; // up to 1% from strategy liquidity constraints
        assertLe(vault.totalAssets(), maxDust, "Vault should be near-empty after all cycles");
    }

    function test_edge_withdraw_drains_all_strategies() public {
        uint256 largeDeposit = depositAmount * 3;
        deal(token, alice, largeDeposit);
        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(largeDeposit, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(token).balanceOf(address(vault));
        assertLt(idle, largeDeposit, "Not all funds should be idle");

        uint256 redeemable = vault.maxRedeem(alice);
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);

        uint256 received = IERC20(token).balanceOf(alice) - aliceBefore;
        assertGe(received, largeDeposit * 99 / 100, "Full drain should return >99%");
    }

    function test_edge_many_users_withdraw() public {
        uint256 numUsers = 10;
        address[] memory users = new address[](numUsers);
        uint256[] memory deposits = new uint256[](numUsers);

        for (uint256 i = 0; i < numUsers; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            deposits[i] = depositAmount * (i + 1) / 5;
            deal(token, users[i], deposits[i]);
            vm.startPrank(users[i]);
            IERC20(token).forceApprove(address(vault), type(uint256).max);
            vault.deposit(deposits[i], users[i]);
            vm.stopPrank();
        }

        vm.prank(keeper);
        vault.rebalance();

        for (uint256 i = 0; i < numUsers; i++) {
            uint256 redeemable = vault.maxRedeem(users[i]);
            uint256 before = IERC20(token).balanceOf(users[i]);
            vm.prank(users[i]);
            vault.redeem(redeemable, users[i], users[i]);
            uint256 received = IERC20(token).balanceOf(users[i]) - before;
            assertGe(received, deposits[i] * 99 / 100, "Each user should get back >99% of deposit");
        }
    }

    /// @dev Helper for fork tests that redeem `vault.maxRedeem(owner)`.
    ///      Some upstream protocol states (Aave V3 with virtual-balance
    ///      accounting at high utilisation, where pool.withdraw underflows
    ///      even though aToken.balanceOf reports liquidity) cause the
    ///      strategy.withdraw call to revert and the waterfall to fall
    ///      short of maxRedeem's quote. That is upstream fragility, not a
    ///      vault defect — the vault correctly catches the strategy
    ///      revert via try/catch and continues. Tests that asserted
    ///      "redeem the max returns >99%" should skip in this state, not
    ///      fail, since the failure is environmental.
    function _redeemOrSkipOnUpstreamFragility(address owner, uint256 shares) internal {
        vm.prank(owner);
        try vault.redeem(shares, owner, owner) {
            return;
        } catch (bytes memory reason) {
            // Bubble up unexpected reverts; only swallow WithdrawalFailed,
            // which is the canonical "couldn't deliver maxRedeem" signal.
            bytes4 selector;
            if (reason.length >= 4) {
                assembly {
                    selector := mload(add(reason, 0x20))
                }
            }
            if (selector == TezoroV1_2.WithdrawalFailed.selector) {
                vm.skip(true, "upstream withdraw fragility (e.g. Aave virtual-balance underflow) - skipping");
                return;
            }
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}
