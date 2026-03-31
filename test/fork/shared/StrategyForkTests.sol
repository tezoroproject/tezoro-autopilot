// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Strategy} from "../../../src/strategies/AaveV3Strategy.sol";
import {CompoundV3Strategy} from "../../../src/strategies/CompoundV3Strategy.sol";
import {MorphoBlueMultiStrategy} from "../../../src/strategies/MorphoBlueMultiStrategy.sol";
import {FluidStrategy} from "../../../src/strategies/FluidStrategy.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {BaseChainForkSetup} from "./BaseChainForkSetup.sol";

/// @notice Per-strategy fork tests: deposit, withdraw, emergency, health, access, harvest, yield.
abstract contract StrategyForkTests is BaseChainForkSetup {
    // =========================================================================
    // Aave V3 Tests
    // =========================================================================

    function test_aave_deposit() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(aaveStrategy.balanceOf(), 0, "Aave should have funds after rebalance");
    }

    function test_aave_withdraw() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = aaveStrategy.balanceOf();
        vm.prank(address(vault));
        uint256 withdrawn = aaveStrategy.withdraw(balBefore / 2);

        assertGt(withdrawn, 0);
        assertLt(aaveStrategy.balanceOf(), balBefore);
    }

    function test_aave_emergencyWithdraw() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(aaveStrategy.balanceOf(), 0);
        vm.prank(address(vault));
        uint256 withdrawn = aaveStrategy.emergencyWithdraw();

        assertGt(withdrawn, 0);
        assertLe(aaveStrategy.balanceOf(), 1);
    }

    function test_aave_isHealthy() public view {
        if (address(aaveStrategy) == address(0)) return;
        assertTrue(aaveStrategy.isHealthy());
    }

    function test_aave_onlyVault() public {
        if (address(aaveStrategy) == address(0)) return;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AaveV3Strategy.NotVault.selector);
        aaveStrategy.deposit(depositAmount / 100);
    }

    // =========================================================================
    // Compound V3 Tests
    // =========================================================================

    function test_compound_deposit() public {
        if (address(compoundStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(compoundStrategy.balanceOf(), 0, "Compound should have funds");
    }

    function test_compound_withdraw() public {
        if (address(compoundStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = compoundStrategy.balanceOf();
        vm.prank(address(vault));
        uint256 withdrawn = compoundStrategy.withdraw(balBefore / 2);

        assertGt(withdrawn, 0);
        assertLt(compoundStrategy.balanceOf(), balBefore);
    }

    function test_compound_emergencyWithdraw() public {
        if (address(compoundStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.prank(address(vault));
        uint256 withdrawn = compoundStrategy.emergencyWithdraw();
        assertGt(withdrawn, 0);
    }

    function test_compound_isHealthy() public view {
        if (address(compoundStrategy) == address(0)) return;
        assertTrue(compoundStrategy.isHealthy());
    }

    function test_compound_onlyVault() public {
        if (address(compoundStrategy) == address(0)) return;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(CompoundV3Strategy.NotVault.selector);
        compoundStrategy.deposit(depositAmount / 100);
    }

    function test_compound_yieldAccrual() public {
        if (address(compoundStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = compoundStrategy.balanceOf();
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        assertGe(compoundStrategy.balanceOf(), balBefore, "Should grow over time");
    }

    // =========================================================================
    // Spark Tests
    // =========================================================================

    function test_spark_deposit() public {
        if (address(sparkStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(sparkStrategy.balanceOf(), 0, "Spark should have funds");
    }

    function test_spark_withdraw() public {
        if (address(sparkStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = sparkStrategy.balanceOf();
        vm.prank(address(vault));
        uint256 withdrawn = sparkStrategy.withdraw(balBefore / 2);
        assertGt(withdrawn, 0);
    }

    function test_spark_emergencyWithdraw() public {
        if (address(sparkStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.prank(address(vault));
        uint256 withdrawn = sparkStrategy.emergencyWithdraw();
        assertGt(withdrawn, 0);
    }

    function test_spark_isHealthy() public view {
        if (address(sparkStrategy) == address(0)) return;
        assertTrue(sparkStrategy.isHealthy());
    }

    // =========================================================================
    // Harvest / Reward Tests
    // =========================================================================

    function test_aave_harvest() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        address rewardsRecipient = makeAddr("rewardsRecipient");
        vm.prank(admin);
        vault.setRewardsModule(rewardsRecipient);

        vm.prank(keeper);
        vault.harvestAll();
    }

    function test_compound_harvest() public {
        if (address(compoundStrategy) == address(0)) return;
        if (!_compRewardsActive()) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        address rewardsRecipient = makeAddr("rewardsRecipient");
        vm.prank(admin);
        vault.setRewardsModule(rewardsRecipient);

        uint256 compBefore = IERC20(compRewardToken).balanceOf(rewardsRecipient);
        vm.prank(keeper);
        vault.harvestAll();

        uint256 compAfter = IERC20(compRewardToken).balanceOf(rewardsRecipient);
        assertGt(compAfter, compBefore, "COMP rewards should be claimed after 30 days");
    }

    function test_spark_harvest() public {
        if (address(sparkStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        address rewardsRecipient = makeAddr("rewardsRecipient");
        vm.prank(admin);
        vault.setRewardsModule(rewardsRecipient);

        vm.prank(keeper);
        vault.harvestAll();
    }

    // =========================================================================
    // Morpho Blue Tests
    // =========================================================================

    function test_morpho_deposit() public {
        if (address(morphoStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(morphoStrategy.balanceOf(), 0, "Morpho should have funds after rebalance");
    }

    function test_morpho_withdraw() public {
        if (address(morphoStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = morphoStrategy.balanceOf();
        vm.prank(address(vault));
        uint256 withdrawn = morphoStrategy.withdraw(balBefore / 2);

        assertGt(withdrawn, 0);
        assertLt(morphoStrategy.balanceOf(), balBefore);
    }

    function test_morpho_emergencyWithdraw() public {
        if (address(morphoStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(morphoStrategy.balanceOf(), 0);
        vm.prank(address(vault));
        uint256 withdrawn = morphoStrategy.emergencyWithdraw();

        assertGt(withdrawn, 0);
        assertEq(morphoStrategy.balanceOf(), 0);
    }

    function test_morpho_isHealthy() public view {
        if (address(morphoStrategy) == address(0)) return;
        assertTrue(morphoStrategy.isHealthy());
    }

    function test_morpho_onlyVault() public {
        if (address(morphoStrategy) == address(0)) return;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(MorphoBlueMultiStrategy.NotVault.selector);
        morphoStrategy.deposit(depositAmount / 100);
    }

    // =========================================================================
    // Fluid Tests
    // =========================================================================

    function test_fluid_deposit() public {
        if (address(fluidStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        assertGt(fluidStrategy.balanceOf(), 0, "Fluid should have funds after rebalance");
    }

    function test_fluid_withdraw() public {
        if (address(fluidStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = fluidStrategy.balanceOf();
        vm.prank(address(vault));
        uint256 withdrawn = fluidStrategy.withdraw(balBefore / 2);

        assertGt(withdrawn, 0);
        assertLt(fluidStrategy.balanceOf(), balBefore);
    }

    function test_fluid_emergencyWithdraw() public {
        if (address(fluidStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.prank(address(vault));
        uint256 withdrawn = fluidStrategy.emergencyWithdraw();
        assertGt(withdrawn, 0);
    }

    function test_fluid_isHealthy() public view {
        if (address(fluidStrategy) == address(0)) return;
        assertTrue(fluidStrategy.isHealthy());
    }

    function test_fluid_onlyVault() public {
        if (address(fluidStrategy) == address(0)) return;
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(FluidStrategy.NotVault.selector);
        fluidStrategy.deposit(depositAmount / 100);
    }

    function test_fluid_yieldAccrual() public {
        if (address(fluidStrategy) == address(0)) return;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 balBefore = fluidStrategy.balanceOf();
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        assertGe(fluidStrategy.balanceOf(), balBefore, "Should grow over time");
    }

    // =========================================================================
    // sweepReward Tests
    // =========================================================================

    function test_aave_sweepReward() public {
        if (address(aaveStrategy) == address(0)) return;
        if (compRewardToken == address(0)) return;

        // Simulate reward tokens landing on strategy (e.g., from merkle claim)
        uint256 stuckAmount = 100e18;
        deal(compRewardToken, address(aaveStrategy), stuckAmount);

        address recipient = makeAddr("rewardRecipient");
        vm.prank(address(vault));
        uint256 swept = aaveStrategy.sweepReward(compRewardToken, recipient);

        assertEq(swept, stuckAmount, "Should sweep full balance");
        assertEq(IERC20(compRewardToken).balanceOf(recipient), stuckAmount, "Recipient should receive tokens");
        assertEq(IERC20(compRewardToken).balanceOf(address(aaveStrategy)), 0, "Strategy should be empty");
    }

    function test_aave_sweepReward_reverts_cannotSweepAsset() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(address(vault));
        vm.expectRevert(AaveV3Strategy.CannotSweepAsset.selector);
        aaveStrategy.sweepReward(token, makeAddr("recipient"));
    }

    function test_aave_sweepReward_reverts_notVault() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AaveV3Strategy.NotVault.selector);
        aaveStrategy.sweepReward(compRewardToken == address(0) ? address(0x1) : compRewardToken, makeAddr("r"));
    }

    function test_morpho_sweepReward() public {
        if (address(morphoStrategy) == address(0)) return;
        if (compRewardToken == address(0)) return;

        uint256 stuckAmount = 50e18;
        deal(compRewardToken, address(morphoStrategy), stuckAmount);

        address recipient = makeAddr("rewardRecipient");
        vm.prank(address(vault));
        uint256 swept = morphoStrategy.sweepReward(compRewardToken, recipient);

        assertEq(swept, stuckAmount);
        assertEq(IERC20(compRewardToken).balanceOf(recipient), stuckAmount);
    }

    function test_fluid_sweepReward() public {
        if (address(fluidStrategy) == address(0)) return;
        if (compRewardToken == address(0)) return;

        uint256 stuckAmount = 50e18;
        deal(compRewardToken, address(fluidStrategy), stuckAmount);

        address recipient = makeAddr("rewardRecipient");
        vm.prank(address(vault));
        uint256 swept = fluidStrategy.sweepReward(compRewardToken, recipient);

        assertEq(swept, stuckAmount);
        assertEq(IERC20(compRewardToken).balanceOf(recipient), stuckAmount);
    }

    /// @notice Test vault.sweepStrategyReward() end-to-end: tokens on strategy → RM
    function test_vault_sweepStrategyReward() public {
        if (address(morphoStrategy) == address(0)) return;
        if (compRewardToken == address(0)) return;

        address rm = makeAddr("rewardsModule");
        vm.prank(admin);
        vault.setRewardsModule(rm);

        // Simulate reward tokens on strategy
        uint256 stuckAmount = 100e18;
        deal(compRewardToken, address(morphoStrategy), stuckAmount);

        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(morphoStrategy)), compRewardToken);

        assertEq(IERC20(compRewardToken).balanceOf(rm), stuckAmount, "RM should receive tokens");
        assertEq(IERC20(compRewardToken).balanceOf(address(morphoStrategy)), 0, "Strategy should be empty");
    }
}
