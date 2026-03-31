// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoBlueMultiStrategy} from "../../src/strategies/MorphoBlueMultiStrategy.sol";
import {IMorpho, MarketParams, MorphoMarket, Position, Id} from "../../src/interfaces/IMorpho.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

// Two well-known, high-liquidity USDC markets on Ethereum mainnet
bytes32 constant USDC_WSTETH_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
bytes32 constant USDC_WBTC_MARKET = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;
bytes32 constant USDC_CBBTC_MARKET = 0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64;

/// @notice Fuzz tests for MorphoBlueMultiStrategy on Ethereum mainnet fork.
///         Tests properties that must hold for ANY valid input amount.
contract MorphoStrategyFuzz is Test {
    using SafeERC20 for IERC20;

    MorphoBlueMultiStrategy strategy;
    IMorpho morpho = IMorpho(MORPHO);

    Id midA;
    Id midB;
    Id midC;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    uint256 constant MAX_DEPOSIT = 5_000_000e6; // 5M USDC

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new MorphoBlueMultiStrategy(USDC, MORPHO, vaultAddr, adminAddr, "Morpho Fuzz", 64, new MarketParams[](0));

        midA = Id.wrap(USDC_WSTETH_MARKET);
        midB = Id.wrap(USDC_WBTC_MARKET);
        midC = Id.wrap(USDC_CBBTC_MARKET);

        MarketParams memory mpA = morpho.idToMarketParams(midA);
        MarketParams memory mpB = morpho.idToMarketParams(midB);
        MarketParams memory mpC = morpho.idToMarketParams(midC);

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addMarket(mpA);
        strategy.addMarket(mpB);
        strategy.addMarket(mpC);
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
        strategy.allocate(midA, amount);

        uint256 balance = strategy.balanceOf();
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));

        assertEq(idle, 0, "No idle after full allocate");
        // Balance should match deposit (within 1 unit from share rounding)
        assertGe(balance, amount - 1, "Balance should match deposit");
        assertLe(balance, amount + 1, "Balance should not exceed deposit");
    }

    // ====== Property: allocate then deallocate round-trip ======

    function testFuzz_allocateDeallocate_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(midA, amount);

        // Deallocate slightly less to avoid share rounding overflow
        uint256 mBal = strategy.marketBalance(midA);
        uint256 safeAmount = mBal > 1 ? mBal - 1 : mBal;

        vm.prank(keeperAddr);
        strategy.deallocate(midA, safeAmount);

        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 totalBal = strategy.balanceOf();

        // Should recover nearly everything
        assertGe(totalBal, amount - 2, "Should recover nearly all funds");
        assertGt(idle, 0, "Should have some idle after deallocate");
    }

    // ====== Property: split allocation across markets conserves total ======

    function testFuzz_splitAllocation_conservesTotal(uint256 amount, uint256 splitBps) public {
        amount = bound(amount, 10e6, MAX_DEPOSIT);
        splitBps = bound(splitBps, 100, 9900); // 1% to 99%

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        uint256 toA = amount * splitBps / 10_000;
        uint256 toB = amount - toA;

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, toA);
        strategy.allocate(midB, toB);
        vm.stopPrank();

        uint256 totalBal = strategy.balanceOf();
        assertGe(totalBal, amount - 2, "Total balance conserved after split");
        assertLe(totalBal, amount + 2, "Total balance conserved after split");

        uint256 balA = strategy.marketBalance(midA);
        uint256 balB = strategy.marketBalance(midB);
        assertGe(balA, toA - 1, "Market A balance matches allocation");
        assertGe(balB, toB - 1, "Market B balance matches allocation");
    }

    // ====== Property: withdraw never returns more than requested ======

    function testFuzz_withdraw_neverExceedsRequest(uint256 deposit, uint256 withdrawAmt) public {
        deposit = bound(deposit, 10e6, MAX_DEPOSIT);
        withdrawAmt = bound(withdrawAmt, 1e6, deposit);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        // Allocate half to market
        uint256 toMarket = deposit / 2;
        vm.prank(keeperAddr);
        strategy.allocate(midA, toMarket);

        uint256 vaultBalBefore = IERC20(USDC).balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(withdrawAmt);

        uint256 vaultBalAfter = IERC20(USDC).balanceOf(vaultAddr);
        uint256 received = vaultBalAfter - vaultBalBefore;

        assertLe(withdrawn, withdrawAmt, "Withdrawn should not exceed request");
        assertEq(received, withdrawn, "Vault should receive exactly withdrawn amount");
    }

    // ====== Property: withdraw from idle only when sufficient ======

    function testFuzz_withdraw_fromIdleWhenSufficient(uint256 deposit, uint256 withdrawAmt) public {
        deposit = bound(deposit, 10e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        // Allocate half, keep half idle
        uint256 toMarket = deposit / 2;
        uint256 idle = deposit - toMarket;
        vm.prank(keeperAddr);
        strategy.allocate(midA, toMarket);

        // Withdraw less than idle -- should only touch idle
        withdrawAmt = bound(withdrawAmt, 1e6, idle);

        uint256 marketBalBefore = strategy.marketBalance(midA);

        vm.prank(vaultAddr);
        strategy.withdraw(withdrawAmt);

        uint256 marketBalAfter = strategy.marketBalance(midA);

        // Market balance should be untouched since we withdrew from idle
        assertEq(marketBalAfter, marketBalBefore, "Market should be untouched for idle-only withdraw");
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
            strategy.allocate(midA, toAllocate);
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

        // Split across all 3 markets
        uint256 perMarket = deposit / 3;
        uint256 remainder = deposit - perMarket * 2;
        vm.startPrank(keeperAddr);
        strategy.allocate(midA, perMarket);
        strategy.allocate(midB, perMarket);
        strategy.allocate(midC, remainder);
        vm.stopPrank();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        // Should recover nearly everything
        assertGe(withdrawn, deposit - 3, "Emergency should recover all funds");
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
        strategy.allocate(midA, deposit);

        uint256 balBefore = strategy.balanceOf();

        // Warp forward
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        // Accrue interest
        morpho.accrueInterest(morpho.idToMarketParams(midA));

        uint256 balAfter = strategy.balanceOf();

        // Balance should grow (or at minimum stay the same)
        assertGe(balAfter, balBefore, "Balance should not decrease after yield accrual");
    }

    // ====== Property: three-market allocation solvency ======

    function testFuzz_threeMarket_solvency(uint256 deposit, uint256 splitA, uint256 splitB) public {
        deposit = bound(deposit, 30e6, MAX_DEPOSIT);
        splitA = bound(splitA, 1000, 8000); // 10-80%
        splitB = bound(splitB, 500, 10_000 - splitA - 500); // remainder split

        uint256 toA = deposit * splitA / 10_000;
        uint256 toB = deposit * splitB / 10_000;
        uint256 toC = deposit - toA - toB;

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, toA);
        strategy.allocate(midB, toB);
        strategy.allocate(midC, toC);
        vm.stopPrank();

        // Verify total balance matches deposit
        uint256 bal = strategy.balanceOf();
        assertGe(bal, deposit - 3, "Solvency: total >= deposit");
        assertLe(bal, deposit + 3, "Solvency: total <= deposit + dust");

        // Verify per-market balances sum correctly
        uint256 mA = strategy.marketBalance(midA);
        uint256 mB = strategy.marketBalance(midB);
        uint256 mC = strategy.marketBalance(midC);
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 computed = mA + mB + mC + idle;

        assertGe(computed, deposit - 3, "Per-market sum matches total");
        assertLe(computed, deposit + 3, "Per-market sum matches total");
    }

    // ====== Property: partial withdraw from multi-market ======

    function testFuzz_partialWithdraw_multiMarket(uint256 deposit, uint256 withdrawPct) public {
        deposit = bound(deposit, 100e6, MAX_DEPOSIT);
        withdrawPct = bound(withdrawPct, 1, 100);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        // Allocate all to two markets
        uint256 half = deposit / 2;
        vm.startPrank(keeperAddr);
        strategy.allocate(midA, half);
        strategy.allocate(midB, deposit - half);
        vm.stopPrank();

        uint256 withdrawAmt = deposit * withdrawPct / 100;
        uint256 balBefore = strategy.balanceOf();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(withdrawAmt);

        uint256 balAfter = strategy.balanceOf();

        // Withdrawn should be close to requested (within 2 from share rounding across 2 markets)
        assertGe(withdrawn, withdrawAmt - 2, "Should withdraw requested amount");

        // Remaining balance should be conserved (rearranged to avoid uint underflow)
        assertGe(balAfter + withdrawn + 2, balBefore, "Balance conservation");
    }

    // ====== Property: allocate reverts if exceeds idle ======

    function testFuzz_allocate_revertsOnOverspend(uint256 deposit, uint256 extra) public {
        deposit = bound(deposit, 1e6, MAX_DEPOSIT);
        extra = bound(extra, 1, 1_000_000e6);

        vm.prank(vaultAddr);
        strategy.deposit(deposit);

        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.InsufficientIdle.selector);
        strategy.allocate(midA, deposit + extra);
    }

    // ====== Property: deposit + full withdraw = original amount ======

    function testFuzz_depositFullWithdraw_returnsAll(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        // Keep as idle (no allocation) -- should get exact amount back
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(amount);

        assertEq(withdrawn, amount, "Full idle withdraw should return exact amount");
    }

    // ====== Property: withdraw(max) is capped at available balance ======

    function testFuzz_withdraw_moreThanBalance_cappedAtAvailable(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(midA, amount);

        uint256 vaultBalBefore = IERC20(USDC).balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        uint256 vaultBalAfter = IERC20(USDC).balanceOf(vaultAddr);
        uint256 received = vaultBalAfter - vaultBalBefore;

        assertLe(withdrawn, amount + 1, "Withdrawn should not exceed deposit + rounding");
        assertEq(received, withdrawn, "Vault should receive exactly withdrawn amount");
        assertLe(strategy.balanceOf(), 1, "Strategy balance should be ~0 after max withdraw");
    }

    // ====== Property: multi-market rebalance conserves funds ======

    function testFuzz_multiMarket_rebalance_conservation(uint256 amount, uint256 bpsA, uint256 bpsB) public {
        amount = bound(amount, 30e6, MAX_DEPOSIT);
        bpsA = bound(bpsA, 1000, 5000);
        bpsB = bound(bpsB, 1000, 10_000 - bpsA - 1000);
        uint256 bpsC = 10_000 - bpsA - bpsB;

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        uint256 toA = amount * bpsA / 10_000;
        uint256 toB = amount * bpsB / 10_000;
        uint256 toC = amount * bpsC / 10_000;

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, toA);
        strategy.allocate(midB, toB);
        strategy.allocate(midC, toC);
        vm.stopPrank();

        // Deallocate from midA
        uint256 mBalA = strategy.marketBalance(midA);
        uint256 safeA = mBalA > 1 ? mBalA - 1 : mBalA;

        vm.prank(keeperAddr);
        strategy.deallocate(midA, safeA);

        // Re-allocate idle to midB
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        if (idle > 0) {
            vm.prank(keeperAddr);
            strategy.allocate(midB, idle);
        }

        uint256 totalBal = strategy.balanceOf();
        assertGe(totalBal, amount - 3, "Rebalance should conserve funds (lower bound)");
        assertLe(totalBal, amount + 3, "Rebalance should conserve funds (upper bound)");
    }

    // ====== Property: recallMarket recovers funds to idle ======

    function testFuzz_recallMarket_recovers(uint256 amount) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(midA, amount);

        vm.prank(adminAddr);
        strategy.recallMarket(midA);

        // Market should be frozen after recall
        assertTrue(strategy.depositFrozenMarkets(midA), "Market should be frozen after recall");

        // Idle should hold nearly all the funds
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idle, amount - 1, "Idle should recover nearly all funds after recall");
    }

    // ====== Property: freeze/unfreeze does not lose funds ======

    function testFuzz_freezeUnfreeze_doesNotLoseFunds(uint256 amount) public {
        amount = bound(amount, 10e6, MAX_DEPOSIT);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        uint256 half = amount / 2;

        vm.prank(keeperAddr);
        strategy.allocate(midA, half);

        uint256 balBeforeFreeze = strategy.balanceOf();

        // Freeze market
        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        // Allocate to frozen market should revert
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.DepositsFrozen.selector);
        strategy.allocate(midA, 1e6);

        // Unfreeze market
        vm.prank(adminAddr);
        strategy.unfreezeMarketDeposits(midA);

        // Allocate should work again after unfreeze
        uint256 remainingIdle = IERC20(USDC).balanceOf(address(strategy));
        if (remainingIdle > 0) {
            vm.prank(keeperAddr);
            strategy.allocate(midA, remainingIdle);
        }

        uint256 balAfterUnfreeze = strategy.balanceOf();
        assertGe(balAfterUnfreeze, balBeforeFreeze - 1, "Freeze/unfreeze should not lose funds");
        assertLe(balAfterUnfreeze, balBeforeFreeze + 1, "Freeze/unfreeze should not lose funds");
    }

    // ====== Property: accrueAllInterest never reverts ======

    function testFuzz_accrueAllInterest_neverReverts(uint256 amount, uint256 daysElapsed, address caller) public {
        amount = bound(amount, 1e6, MAX_DEPOSIT);
        daysElapsed = bound(daysElapsed, 0, 730);

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        vm.prank(keeperAddr);
        strategy.allocate(midA, amount);

        // Warp random time forward
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        // Call from arbitrary address -- should never revert
        vm.prank(caller);
        strategy.accrueAllInterest();
    }
}
