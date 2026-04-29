// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TezoroV1_2} from "../../../src/TezoroV1_2.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {RewardsModuleForkTests} from "./RewardsModuleForkTests.sol";

/// @notice Final abstract layer: Guardian role + Per-Strategy Caps.
///         Chain-specific test contracts (EthUSDC, ArbUSDC, etc.) inherit this.
abstract contract BaseChainForkTest is RewardsModuleForkTests {
    // =========================================================================
    // Guardian Role
    // =========================================================================

    function test_guardian_canPauseStrategy() public {
        if (address(aaveStrategy) == address(0)) return;

        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(aaveStrategy)));
        assertTrue(vault.pausedStrategies(IStrategy(address(aaveStrategy))));
    }

    function test_guardian_canPauseVault() public {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pauseVault();
        assertTrue(vault.paused());
    }

    function test_guardian_cannotUnpauseStrategy() public {
        if (address(aaveStrategy) == address(0)) return;

        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(aaveStrategy)));

        vm.prank(guardian);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.unpauseStrategy(IStrategy(address(aaveStrategy)));
    }

    function test_guardian_cannotUnpauseVault() public {
        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(admin);
        vault.pauseVault();

        vm.prank(guardian);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.unpauseVault();
    }

    function test_keeper_cannotPause() public {
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotGuardianOrAdmin.selector);
        vault.pauseVault();
    }

    function test_randomUser_cannotPause() public {
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotGuardianOrAdmin.selector);
        vault.pauseVault();
    }

    function test_guardian_pauseStrategy_skipsInRebalance() public {
        if (address(aaveStrategy) == address(0)) return;

        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 inAave = aaveStrategy.balanceOf();
        assertGt(inAave, 0);

        // Guardian pauses the strategy
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(aaveStrategy)));

        // Rebalance should skip paused strategy
        vm.prank(keeper);
        vault.rebalance();

        assertEq(aaveStrategy.balanceOf(), inAave, "Paused strategy balance should not change");
    }

    function test_guardian_pauseVault_blocksDeposits_allowsWithdrawals() public {
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        address guardian = makeAddr("guardian");
        vm.prank(admin);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pauseVault();

        // Deposits blocked
        vm.prank(bob);
        vm.expectRevert(TezoroV1_2.VaultIsPaused.selector);
        vault.deposit(depositAmount, bob);

        // Withdrawals still work
        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(depositAmount / 2, alice, alice);
        assertEq(IERC20(token).balanceOf(alice), aliceBefore + depositAmount / 2);
    }

    // =========================================================================
    // Per-Strategy Max Caps
    // =========================================================================

    function test_caps_setMaxAllocation() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.prank(admin);
        vault.setMaxAllocation(IStrategy(address(aaveStrategy)), 3_000);
        assertEq(vault.maxAllocationBps(IStrategy(address(aaveStrategy))), 3_000);
    }

    function test_caps_rebalance_reverts_aboveCap() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.startPrank(admin);
        vault.setMaxAllocation(IStrategy(address(aaveStrategy)), 3_000);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(aaveStrategy));
        bps[0] = 3_001;

        vm.expectRevert(TezoroV1_2.AllocationExceedsCap.selector);
        vault.rebalance(strats, bps);
        vm.stopPrank();
    }

    function test_caps_rebalance_atCap() public {
        if (address(aaveStrategy) == address(0)) return;

        // Set all strategies' allocations so total stays within BPS
        IStrategy[] memory allStrats = vault.getStrategies();
        uint256[] memory allBps = new uint256[](allStrats.length);
        for (uint256 i = 0; i < allStrats.length; i++) {
            allBps[i] = address(allStrats[i]) == address(aaveStrategy) ? 3_000 : 0;
        }

        vm.startPrank(admin);
        vault.setMaxAllocation(IStrategy(address(aaveStrategy)), 3_000);
        vault.rebalance(allStrats, allBps);
        vm.stopPrank();

        assertEq(vault.targetAllocationBps(IStrategy(address(aaveStrategy))), 3_000);
    }

    function test_caps_rebalance_clamps_to_cap() public {
        if (address(aaveStrategy) == address(0)) return;
        if (strategyCount < 2) return;

        // Set all strategies' allocations: aave=2000, distribute rest among others
        IStrategy[] memory allStrats = vault.getStrategies();
        uint256[] memory allBps = new uint256[](allStrats.length);
        uint256 remaining = 9_700 - 2_000;
        uint256 otherCount = allStrats.length - 1;
        uint256 perOther = otherCount > 0 ? remaining / otherCount : 0;
        uint256 otherIdx = 0;
        for (uint256 i = 0; i < allStrats.length; i++) {
            if (address(allStrats[i]) == address(aaveStrategy)) {
                allBps[i] = 2_000;
            } else {
                otherIdx++;
                allBps[i] = otherIdx == otherCount ? remaining - perOther * (otherCount - 1) : perOther;
            }
        }

        vm.startPrank(admin);
        vault.setMaxAllocation(IStrategy(address(aaveStrategy)), 2_000);
        vault.rebalance(allStrats, allBps);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 total = vault.totalAssets();
        uint256 aaveBalance = vault.trackedBalance(IStrategy(address(aaveStrategy)));
        uint256 maxAllowed = (total * 2_000) / 10_000;

        assertLe(aaveBalance, maxAllowed + 1, "Aave should not exceed its 20% cap");
        assertGt(aaveBalance, 0, "Aave should have some allocation");
    }

    function test_caps_noCap_allowsAnyAllocation() public {
        if (address(aaveStrategy) == address(0)) return;

        // Set aave to 9700, zero out all others so total stays within BPS
        IStrategy[] memory allStrats = vault.getStrategies();
        uint256[] memory allBps = new uint256[](allStrats.length);
        for (uint256 i = 0; i < allStrats.length; i++) {
            allBps[i] = address(allStrats[i]) == address(aaveStrategy) ? 9_700 : 0;
        }

        // maxAllocationBps defaults to 0 = no cap
        vm.prank(admin);
        vault.rebalance(allStrats, allBps);
        assertEq(vault.targetAllocationBps(IStrategy(address(aaveStrategy))), 9_700);
    }

    function test_caps_removeStrategy_cleansCap() public {
        if (address(aaveStrategy) == address(0)) return;

        vm.startPrank(admin);
        vault.setMaxAllocation(IStrategy(address(aaveStrategy)), 4_000);
        vault.removeStrategy(IStrategy(address(aaveStrategy)));
        vm.stopPrank();

        assertEq(vault.maxAllocationBps(IStrategy(address(aaveStrategy))), 0);
    }

    // =========================================================================
    // Deposit Cap
    // =========================================================================

    function test_depositCap_setAndGet() public {
        vm.prank(admin);
        vault.setDepositCap(1_000_000e6);
        assertEq(vault.depositCap(), 1_000_000e6);
    }

    function test_depositCap_blocksExcessDeposit() public {
        vm.prank(admin);
        vault.setDepositCap(depositAmount);

        // First deposit fills the cap
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Second deposit should revert (maxDeposit returns 0)
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit should be 0 when at cap");

        vm.prank(bob);
        vm.expectRevert(); // ERC-4626 reverts on exceeding maxDeposit
        vault.deposit(1, bob);
    }

    function test_depositCap_allowsPartialDeposit() public {
        uint256 cap = depositAmount + depositAmount / 2;
        vm.prank(admin);
        vault.setDepositCap(cap);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 remaining = vault.maxDeposit(bob);
        assertGt(remaining, 0, "Should have room for partial deposit");
        assertLe(remaining, depositAmount / 2 + 1, "Remaining should be ~half depositAmount");

        vm.prank(bob);
        vault.deposit(remaining, bob);
    }

    function test_depositCap_zeroCap_noLimit() public {
        // Default: no cap
        assertEq(vault.depositCap(), 0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);
    }

    function test_depositCap_removeCap() public {
        vm.startPrank(admin);
        vault.setDepositCap(depositAmount);
        vault.setDepositCap(0); // remove cap
        vm.stopPrank();

        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_depositCap_withdrawsStillWork() public {
        vm.prank(admin);
        vault.setDepositCap(depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Withdrawals should not be affected by cap
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeem(half, alice, alice);

        // After withdrawal, there's room for new deposits
        assertGt(vault.maxDeposit(bob), 0, "Should have room after withdrawal");
    }

    function test_depositCap_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setDepositCap(1);
    }
}
