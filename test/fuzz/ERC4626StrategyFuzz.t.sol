// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// MetaMorpho USDC vaults (ERC-4626) on Ethereum mainnet
address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
address constant GAUNTLET_USDC_CORE = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

/// @notice Fuzz tests for ERC4626MultiStrategyV1_2 on Ethereum mainnet fork.
///         Tests properties that must hold for ANY valid input amount.
contract ERC4626StrategyFuzz is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategyV1_2 strategy;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    uint256 constant MAX_DEPOSIT = 5_000_000e6; // 5M USDC

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new ERC4626MultiStrategyV1_2(USDC, vaultAddr, adminAddr, "ERC4626 Fuzz", 64, new address[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(STEAKHOUSE_USDC);
        strategy.addSubVault(GAUNTLET_USDC_CORE);
        vm.stopPrank();

        deal(USDC, vaultAddr, MAX_DEPOSIT * 10);
        vm.prank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), type(uint256).max);
    }

    // ====== Property: deposit preserves balanceOf ======

    function testFuzz_deposit_preservesBalance(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        assertEq(strategy.balanceOf(), amount, "balanceOf should equal deposited amount");
        assertEq(IERC20(USDC).balanceOf(address(strategy)), amount, "All should be idle");
    }

    // ====== Property: allocate conserves total balance ======

    function testFuzz_allocate_conservesBalance(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, amount);

        uint256 balance = strategy.balanceOf();
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));

        assertEq(idle, 0, "No idle after full allocate");
        assertGe(balance, amount - 1, "Balance should match deposit");
        assertLe(balance, amount + 1, "Balance should not exceed deposit");
    }

    // ====== Property: allocate then deallocate round-trip ======

    function testFuzz_allocateDeallocate_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, amount);

        // Deallocate slightly less to avoid rounding overflow
        uint256 svBal = strategy.subVaultBalance(STEAKHOUSE_USDC);
        uint256 safeAmount = svBal > 1 ? svBal - 1 : svBal;

        vm.prank(keeperAddr);
        strategy.deallocate(STEAKHOUSE_USDC, safeAmount);

        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 totalBal = strategy.balanceOf();

        assertGe(totalBal, amount - 2, "Should recover nearly all funds");
        assertGt(idle, 0, "Should have some idle after deallocate");
    }

    // ====== Property: split allocation across sub-vaults conserves total ======

    function testFuzz_splitAllocation_conservesTotal(uint256 amount, uint256 splitBps) public {
        amount = bound(amount, 10e6, MAX_DEPOSIT);
        splitBps = bound(splitBps, 100, 9900); // 1% to 99%

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        uint256 toA = amount * splitBps / 10_000;
        uint256 toB = amount - toA;

        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, toA);
        strategy.allocate(GAUNTLET_USDC_CORE, toB);
        vm.stopPrank();

        uint256 totalBal = strategy.balanceOf();
        assertGe(totalBal, amount - 2, "Total balance conserved after split");
        assertLe(totalBal, amount + 2, "Total balance conserved after split");
    }

    // ====== Property: withdraw never returns more than requested ======

    function testFuzz_withdraw_neverExceedsRequest(uint256 deposit, uint256 withdrawAmt) public {
        deposit = bound(deposit, 10e6, MAX_DEPOSIT);
        withdrawAmt = bound(withdrawAmt, 1e6, deposit);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        // Allocate half to sub-vault
        uint256 toVault = deposit / 2;
        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, toVault);

        uint256 vaultBalBefore = IERC20(USDC).balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(withdrawAmt);

        uint256 vaultBalAfter = IERC20(USDC).balanceOf(vaultAddr);
        uint256 received = vaultBalAfter - vaultBalBefore;

        assertLe(withdrawn, withdrawAmt, "Withdrawn should not exceed request");
        assertEq(received, withdrawn, "Vault should receive exactly withdrawn amount");
    }

    // ====== Property: withdraw from idle when sufficient ======

    function testFuzz_withdraw_fromIdleWhenSufficient(uint256 deposit, uint256 withdrawAmt) public {
        deposit = bound(deposit, 10e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        uint256 toVault = deposit / 2;
        uint256 idle = deposit - toVault;
        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, toVault);

        withdrawAmt = bound(withdrawAmt, 1e6, idle);

        uint256 svBalBefore = strategy.subVaultBalance(STEAKHOUSE_USDC);

        vm.prank(vaultAddr);
        strategy.withdraw(withdrawAmt);

        uint256 svBalAfter = strategy.subVaultBalance(STEAKHOUSE_USDC);

        assertEq(svBalAfter, svBalBefore, "Sub-vault should be untouched for idle-only withdraw");
    }

    // ====== Property: availableLiquidity <= balanceOf always ======

    function testFuzz_availableLiquidity_leq_balanceOf(uint256 deposit, uint256 allocBps) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);
        allocBps = bound(allocBps, 0, 10_000);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        uint256 toAllocate = deposit * allocBps / 10_000;
        if (toAllocate > 0) {
            vm.prank(keeperAddr);
            strategy.allocate(STEAKHOUSE_USDC, toAllocate);
        }

        uint256 bal = strategy.balanceOf();
        uint256 avail = strategy.availableLiquidity();

        assertLe(avail, bal, "availableLiquidity must be <= balanceOf");
    }

    // ====== Property: emergency withdraw collects everything ======

    function testFuzz_emergencyWithdraw_collectsAll(uint256 deposit) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        uint256 half = deposit / 2;
        uint256 remainder = deposit - half;
        vm.startPrank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, half);
        strategy.allocate(GAUNTLET_USDC_CORE, remainder);
        vm.stopPrank();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertGe(withdrawn, deposit - 2, "Emergency should recover all funds");
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0, "Strategy should be empty");
        assertEq(strategy.balanceOf(), 0, "balanceOf should be zero");
    }

    // ====== Property: yield accrual increases balance ======

    function testFuzz_yieldAccrual_increasesBalance(uint256 deposit, uint256 daysElapsed) public {
        deposit = bound(deposit, 100e6, MAX_DEPOSIT);
        daysElapsed = bound(daysElapsed, 1, 365);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, deposit);

        uint256 balBefore = strategy.balanceOf();

        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        uint256 balAfter = strategy.balanceOf();

        assertGe(balAfter, balBefore, "Balance should not decrease after yield accrual");
    }

    // ====== Property: allocate reverts if exceeds idle ======

    function testFuzz_allocate_revertsOnOverspend(uint256 deposit, uint256 extra) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);
        extra = bound(extra, 1, 1_000_000e6);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.InsufficientIdle.selector);
        strategy.allocate(STEAKHOUSE_USDC, deposit + extra);
    }

    // ====== Property: deposit + full withdraw = original amount ======

    function testFuzz_depositFullWithdraw_returnsAll(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(amount);

        assertEq(withdrawn, amount, "Full idle withdraw should return exact amount");
    }

    // ====== Property: withdraw capped at available ======

    function testFuzz_withdraw_moreThanBalance_cappedAtAvailable(uint256 deposit) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, deposit);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        assertGe(withdrawn, deposit - 1, "Should withdraw nearly all");
        assertLe(withdrawn, deposit + 1, "Should not exceed deposited");
    }

    // ====== Property: recall + freeze works ======

    function testFuzz_recallSubVault_recovers(uint256 deposit) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, deposit);

        vm.prank(adminAddr);
        strategy.recallSubVault(STEAKHOUSE_USDC);

        assertTrue(strategy.depositFrozenSubVaults(STEAKHOUSE_USDC), "Should be frozen");
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idle, deposit - 1, "Idle should recover nearly all");

        // Allocate should be blocked
        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(STEAKHOUSE_USDC, 1e6);
    }

    // ====== Property: freeze/unfreeze cycle preserves funds ======

    function testFuzz_freezeUnfreeze_doesNotLoseFunds(uint256 deposit) public {
        deposit = bound(deposit, 10e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        strategy.allocate(STEAKHOUSE_USDC, deposit);

        uint256 balBefore = strategy.balanceOf();

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(STEAKHOUSE_USDC);

        // Funds still in sub-vault, balance unchanged
        assertEq(strategy.balanceOf(), balBefore, "Freeze should not change balance");

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(STEAKHOUSE_USDC);

        assertEq(strategy.balanceOf(), balBefore, "Unfreeze should not change balance");
    }
}
