// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Minimal interface to call accrueAllInterest on Morpho strategies
interface IMorphoStrategy {
    function accrueAllInterest() external;
}

/// @title V1.1 Performance Fee Fork Test
/// @notice Verifies performance fee correctness on deployed v1.1 Ethereum vaults.
///         Forks mainnet, warps time, accrues yield, and checks:
///         - Fee shares minted to feeRecipient
///         - Fee amount is ~15% of profit
///         - HWM advances correctly
///         - User gets principal + 85% of yield
contract V1_2PerformanceFee is Test {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // v1.1 deployed vault addresses (Ethereum, 2026-03-07)
    TezoroV1_2 constant VAULT_A = TezoroV1_2(0x7cc42747862ecACe79FA89BeFcB29C94d2558dEC);
    TezoroV1_2 constant VAULT_B = TezoroV1_2(0xD0F2812F57D284c0d30Ddd8f73b146Ef0cD5a25c);
    TezoroV1_2 constant VAULT_C = TezoroV1_2(0xa139C6a7dd1Bd76Ae3FBCCF4F8bEbA5C4f26513d);

    uint256 constant BPS = 10_000;
    uint256 constant DEPOSIT = 50_000e6; // 50k USDC
    uint256 constant WARP_DAYS = 90;

    address alice;

    function setUp() public {
        vm.createSelectFork("ethereum");
        alice = makeAddr("alice");
        deal(address(USDC), alice, DEPOSIT * 3); // enough for all 3 vaults
    }

    // -----------------------------------------------------------------------
    // Per-vault tests
    // -----------------------------------------------------------------------

    function test_feeAccrual_vaultA() public {
        _verifyFeeAccrual(VAULT_A, "Vault A");
    }

    function test_feeAccrual_vaultB() public {
        _verifyFeeAccrual(VAULT_B, "Vault B");
    }

    function test_feeAccrual_vaultC() public {
        _verifyFeeAccrual(VAULT_C, "Vault C");
    }

    // -----------------------------------------------------------------------
    // Config sanity checks
    // -----------------------------------------------------------------------

    function test_configCheck_allVaults() public view {
        TezoroV1_2[3] memory vaults = [VAULT_A, VAULT_B, VAULT_C];
        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(vaults[i].performanceFeeBps(), 1_500, "Fee should be 15%");
            assertTrue(vaults[i].feeRecipient() != address(0), "Fee recipient should be set");
            assertGt(vaults[i].highWaterMark(), 0, "HWM should be positive");
        }
    }

    // -----------------------------------------------------------------------
    // Core verification logic
    // -----------------------------------------------------------------------

    function _verifyFeeAccrual(TezoroV1_2 vault, string memory label) internal {
        address keeper = vault.keeper();
        address feeRecipient = vault.feeRecipient();

        // --- Step 1: Deposit ---
        vm.startPrank(alice);
        USDC.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // --- Step 2: Rebalance to deploy funds ---
        vm.prank(keeper);
        vault.rebalance();

        uint256 hwmBefore = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // --- Step 3: Warp time ---
        vm.warp(block.timestamp + WARP_DAYS * 1 days);
        vm.roll(block.number + WARP_DAYS * 7200);

        // --- Step 4: Accrue interest on Morpho strategies (others accrue automatically) ---
        _accrueInterestOnStrategies(vault);

        // --- Step 5: Reconcile to sync tracked balances ---
        // reconcile() calls _accruePerformanceFee() BEFORE updating trackedBalance,
        // so the first reconcile sees no gain. It only updates the balances.
        vm.prank(keeper);
        vault.reconcile();

        // --- Step 6: Collect fees — NOW the vault sees the updated balances ---
        // This second call to _accruePerformanceFee() sees the gain and mints fee shares.
        vm.prank(keeper);
        vault.collectFees();

        // --- Step 7: Verify fee correctness ---
        _assertFeeCorrectness(vault, label, hwmBefore, feeSharesBefore, feeRecipient);

        // --- Step 8: Redeem and verify alice profits ---
        _assertRedeemProfitable(vault, label);
    }

    function _assertFeeCorrectness(
        TezoroV1_2 vault,
        string memory label,
        uint256 hwmBefore,
        uint256 feeSharesBefore,
        address feeRecipient
    ) internal view {
        uint256 hwmAfter = vault.highWaterMark();
        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);

        // HWM should have advanced
        assertGt(hwmAfter, hwmBefore, string.concat(label, ": HWM should advance"));

        // Fee shares should have been minted
        assertGt(feeSharesAfter, feeSharesBefore, string.concat(label, ": fee shares should be minted"));

        // Check fee is ~15% of yield
        uint256 feeSharesMinted = feeSharesAfter - feeSharesBefore;
        uint256 feeValue = vault.convertToAssets(feeSharesMinted);
        assertGt(feeValue, 0, string.concat(label, ": fee value should be positive"));

        uint256 aliceRedeemable = vault.convertToAssets(vault.balanceOf(alice));
        uint256 aliceProfit = aliceRedeemable - DEPOSIT;
        uint256 totalYield = aliceProfit + feeValue;
        uint256 feePercent = (feeValue * BPS) / totalYield;

        // Fee should be between 10% and 20% of yield (15% target, with tolerance for
        // existing depositors, rounding, and timing of fee accrual)
        assertGe(feePercent, 1_000, string.concat(label, ": fee should be >= 10% of yield"));
        assertLe(feePercent, 2_000, string.concat(label, ": fee should be <= 20% of yield"));
    }

    function _assertRedeemProfitable(TezoroV1_2 vault, string memory label) internal {
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, string.concat(label, ": alice should have shares"));

        vm.startPrank(alice);
        uint256 redeemed = vault.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        assertGt(redeemed, DEPOSIT, string.concat(label, ": alice should profit after redeem"));
        assertEq(vault.balanceOf(alice), 0, string.concat(label, ": alice should have 0 shares"));
    }

    /// @dev Try to call accrueAllInterest() on each strategy.
    ///      Non-Morpho strategies don't have this function, so we use try/catch.
    function _accrueInterestOnStrategies(TezoroV1_2 vault) internal {
        IStrategy[] memory strategies = vault.getStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            try IMorphoStrategy(address(strategies[i])).accrueAllInterest() {} catch {}
        }
    }
}
