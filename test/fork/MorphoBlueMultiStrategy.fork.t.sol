// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {IMorpho, MarketParams, Id} from "../../src/interfaces/IMorpho.sol";

// Real Ethereum mainnet addresses
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

// Morpho Blue USDC lending market IDs
bytes32 constant USDC_WSTETH_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
bytes32 constant USDC_WBTC_MARKET = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;

/// @notice Fork test for MorphoBlueMultiStrategyV1_2 against real Morpho Blue markets on Ethereum mainnet.
contract MorphoBlueMultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    MorphoBlueMultiStrategyV1_2 strategy;
    IMorpho morpho = IMorpho(MORPHO);

    MarketParams mpWstETH;
    MarketParams mpWBTC;
    Id midWstETH;
    Id midWBTC;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");
    address randomUser = makeAddr("random");

    uint256 constant DEPOSIT_AMOUNT = 100_000e6; // 100k USDC

    function setUp() public {
        vm.createSelectFork("ethereum");

        // Fetch real market params from Morpho
        mpWstETH = morpho.idToMarketParams(Id.wrap(USDC_WSTETH_MARKET));
        mpWBTC = morpho.idToMarketParams(Id.wrap(USDC_WBTC_MARKET));
        midWstETH = Id.wrap(USDC_WSTETH_MARKET);
        midWBTC = Id.wrap(USDC_WBTC_MARKET);

        strategy = new MorphoBlueMultiStrategyV1_2(USDC, MORPHO, vaultAddr, adminAddr, "Morpho Blue USDC", 64, new MarketParams[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addMarket(mpWstETH);
        strategy.addMarket(mpWBTC);
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

    function test_allocate_toRealMarket() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);

        // Idle should be ~50k
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 50_000e6);

        // Market balance should be ~50k
        uint256 bal = strategy.marketBalance(midWstETH);
        assertGe(bal, 49_999e6);
        assertLe(bal, 50_001e6);
    }

    function test_allocate_toMultipleMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 60_000e6);
        strategy.allocate(midWBTC, 30_000e6);
        vm.stopPrank();

        // 10k idle
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 10_000e6);

        // Total balance should be ~100k
        assertGe(strategy.balanceOf(), 99_999e6);
        assertLe(strategy.balanceOf(), 100_001e6);
    }

    function test_deallocate_fromRealMarket() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(midWstETH, 80_000e6);

        // Deallocate 30k back
        vm.prank(keeperAddr);
        strategy.deallocate(midWstETH, 30_000e6);

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
    }

    function test_withdraw_waterfallThroughRealMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        // Allocate everything
        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);
        strategy.allocate(midWBTC, 50_000e6);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);

        // Withdraw 70k -- must pull from markets
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(70_000e6);

        assertGe(withdrawn, 69_999e6);
    }

    function test_withdraw_idlePlusMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(midWstETH, 70_000e6);

        // Idle = 30k, market = 70k. Withdraw 60k.
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(60_000e6);

        assertGe(withdrawn, 59_999e6);
    }

    // ========== Emergency ==========

    function test_emergencyWithdraw_collectsFromAllMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 40_000e6);
        strategy.allocate(midWBTC, 40_000e6);
        vm.stopPrank();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertGe(withdrawn, 99_999e6);
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);
    }

    // ========== Views ==========

    function test_balanceOf_aggregatesMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);
        strategy.allocate(midWBTC, 30_000e6);
        vm.stopPrank();

        uint256 bal = strategy.balanceOf();
        assertGe(bal, 99_999e6);
        assertLe(bal, 100_001e6);
    }

    function test_availableLiquidity_aggregatesMarkets() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(midWstETH, 60_000e6);

        uint256 avail = strategy.availableLiquidity();
        assertGe(avail, 99_999e6);
    }

    function test_isHealthy_withRealMarkets() public view {
        // Real markets have activity
        assertTrue(strategy.isHealthy());
    }

    // ========== Admin ==========

    function test_addMarket_revertsOnLoanTokenMismatch() public {
        // USDT market -- wrong loan token for USDC strategy
        MarketParams memory mp = morpho.idToMarketParams(
            Id.wrap(0xa921ef34e2fc7a27ccc50ae7e4b154e16c9799d3387076c421423ef52ac4df99) // USDT/WBTC
        );
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.LoanTokenMismatch.selector);
        strategy.addMarket(mp);
    }

    function test_addMarket_revertsIfAlreadyApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketAlreadyApproved.selector);
        strategy.addMarket(mpWstETH);
    }

    function test_removeMarket_thenAllocateReverts() public {
        vm.prank(adminAddr);
        strategy.removeMarket(midWstETH);

        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketNotApproved.selector);
        strategy.allocate(midWstETH, 50_000e6);
    }

    function test_allocate_revertsIfNotKeeper() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.NotKeeper.selector);
        strategy.allocate(midWstETH, 100e6);
    }

    function test_allocate_revertsIfInsufficientIdle() public {
        vm.prank(vaultAddr);
        strategy.deposit(100e6);

        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.InsufficientIdle.selector);
        strategy.allocate(midWstETH, 200e6);
    }

    // ========== View helpers ==========

    function test_getMarketIds_returnsAdded() public view {
        Id[] memory ids = strategy.getMarketIds();
        assertEq(ids.length, 2);
        assertEq(Id.unwrap(ids[0]), USDC_WSTETH_MARKET);
        assertEq(Id.unwrap(ids[1]), USDC_WBTC_MARKET);
    }

    function test_marketBalance_perMarket() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 60_000e6);
        strategy.allocate(midWBTC, 20_000e6);
        vm.stopPrank();

        uint256 wstBal = strategy.marketBalance(midWstETH);
        uint256 wbtcBal = strategy.marketBalance(midWBTC);

        assertGe(wstBal, 59_999e6);
        assertLe(wstBal, 60_001e6);
        assertGe(wbtcBal, 19_999e6);
        assertLe(wbtcBal, 20_001e6);
    }

    function test_name_isSet() public view {
        assertEq(keccak256(bytes(strategy.name())), keccak256(bytes("Morpho Blue USDC")));
    }

    // ========== Hardened security tests ==========

    function test_yieldAccrual_afterTimeWarp() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);
        strategy.allocate(midWBTC, 50_000e6);
        vm.stopPrank();

        uint256 balBefore = strategy.balanceOf();

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000); // ~30 days of blocks

        // Accrue interest on both markets
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        uint256 balAfter = strategy.balanceOf();
        assertGe(balAfter, balBefore, "Balance should increase after yield accrual");
    }

    function test_withdraw_moreThanAvailable_returnsCapped() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);
        strategy.allocate(midWBTC, 50_000e6);
        vm.stopPrank();

        uint256 balBefore = strategy.balanceOf();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        assertGe(withdrawn, balBefore - 1e6, "Should return all available funds");
        assertLe(withdrawn, balBefore + 1e6, "Should not exceed balance");
    }

    function test_accrueAllInterest_callableByAnyone() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.startPrank(keeperAddr);
        strategy.allocate(midWstETH, 50_000e6);
        strategy.allocate(midWBTC, 50_000e6);
        vm.stopPrank();

        // Call from a random address -- should not revert
        vm.prank(randomUser);
        strategy.accrueAllInterest();
    }

    function test_twoStepAdminTransfer_fullFlow() public {
        address newAdmin = makeAddr("newAdmin");

        // Step 1: current admin proposes transfer
        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);

        // Pending admin is set but admin hasn't changed yet
        assertEq(strategy.admin(), adminAddr);
        assertEq(strategy.pendingAdmin(), newAdmin);

        // Step 2: new admin accepts
        vm.prank(newAdmin);
        strategy.acceptAdmin();

        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));

        // Old admin can no longer act
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.NotAdmin.selector);
        strategy.transferAdmin(adminAddr);

        // New admin can act
        vm.prank(newAdmin);
        strategy.transferAdmin(adminAddr);
        assertEq(strategy.pendingAdmin(), adminAddr);
    }

    function test_recallMarket_realMarket() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        vm.prank(keeperAddr);
        strategy.allocate(midWstETH, 60_000e6);

        uint256 idleBefore = IERC20(USDC).balanceOf(address(strategy));

        // Admin recalls the wstETH market
        vm.prank(adminAddr);
        strategy.recallMarket(midWstETH);

        // Market should be deposit-frozen
        assertTrue(strategy.depositFrozenMarkets(midWstETH), "Market should be frozen after recall");

        // Idle should have recovered the funds
        uint256 idleAfter = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idleAfter, idleBefore + 59_999e6, "Idle should recover recalled funds");

        // Market balance should be zero
        assertEq(strategy.marketBalance(midWstETH), 0, "Market balance should be zero after recall");
    }

    function test_sweepReward_revertsOnUSDC() public {
        vm.prank(vaultAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.CannotSweepAsset.selector);
        strategy.sweepReward(USDC, adminAddr);
    }

    function test_withdraw_fullAmount_afterMultipleAllocDeallocCycles() public {
        vm.prank(vaultAddr);
        strategy.deposit(DEPOSIT_AMOUNT);

        // 5 cycles of allocate/deallocate across both markets
        for (uint256 i = 0; i < 5; i++) {
            uint256 idle = IERC20(USDC).balanceOf(address(strategy));
            uint256 toWstETH = idle * 40 / 100;
            uint256 toWBTC = idle * 30 / 100;

            vm.startPrank(keeperAddr);
            strategy.allocate(midWstETH, toWstETH);
            strategy.allocate(midWBTC, toWBTC);

            // Deallocate by market balance (avoids share rounding underflow)
            uint256 wstBal = strategy.marketBalance(midWstETH);
            uint256 wbtcBal = strategy.marketBalance(midWBTC);
            if (wstBal > 1) strategy.deallocate(midWstETH, wstBal - 1);
            if (wbtcBal > 1) strategy.deallocate(midWBTC, wbtcBal - 1);
            vm.stopPrank();
        }

        uint256 totalBalance = strategy.balanceOf();

        // Withdraw everything
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        // Solvency check: withdrawn should be within 0.1% of tracked balance
        uint256 tolerance = DEPOSIT_AMOUNT / 1000; // 0.1%
        assertGe(withdrawn, totalBalance - tolerance, "Withdrawn should be within 0.1% of balance (lower)");
        assertLe(withdrawn, totalBalance + tolerance, "Withdrawn should be within 0.1% of balance (upper)");

        // Strategy should be empty
        assertLe(IERC20(USDC).balanceOf(address(strategy)), tolerance, "Strategy should be near-empty");
    }
}
