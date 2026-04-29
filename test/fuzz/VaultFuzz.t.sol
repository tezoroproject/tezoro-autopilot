// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {BaseChainForkSetup} from "../fork/shared/BaseChainForkSetup.sol";

// Ethereum mainnet addresses
address constant FUZZ_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant FUZZ_SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
address constant FUZZ_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant FUZZ_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant FUZZ_COMPOUND_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
address constant FUZZ_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
address constant FUZZ_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
bytes32 constant FUZZ_MORPHO_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
address constant FUZZ_FLUID_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
address constant FUZZ_AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
address constant FUZZ_SPARK_REWARDS = 0x4370D3b6C9588E02ce9D22e684387859c7Ff5b34;
address constant FUZZ_COMET_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
address constant FUZZ_COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

/// @title VaultFuzz — Property-based fuzz tests on Ethereum mainnet fork
/// @notice Tests vault invariants with random inputs against real lending protocols.
contract VaultFuzz is BaseChainForkSetup {
    using SafeERC20 for IERC20;

    address public charlie;

    function _configure() internal override {
        forkRpc = "ethereum";
        token = FUZZ_USDC;
        tokenSymbol = "USDC";
        aavePool = FUZZ_AAVE_POOL;
        aaveAToken = FUZZ_A_USDC;
        compoundComet = FUZZ_COMPOUND_USDC;
        sparkPool = FUZZ_SPARK_POOL;
        morpho = FUZZ_MORPHO;
        morphoMarketId = FUZZ_MORPHO_MARKET;
        fluidFToken = FUZZ_FLUID_USDC;
        aaveRewardsController = FUZZ_AAVE_REWARDS;
        sparkRewardsController = FUZZ_SPARK_REWARDS;
        cometRewards = FUZZ_COMET_REWARDS;
        compRewardToken = FUZZ_COMP;
        depositAmount = 100_000e6;
        userBalance = 10_000_000e6; // 10M USDC per user for fuzz range
    }

    function setUp() public override {
        super.setUp();

        charlie = makeAddr("charlie");
        deal(token, charlie, userBalance);
        vm.prank(charlie);
        IERC20(token).forceApprove(address(vault), type(uint256).max);
    }

    // =========================================================================
    // 1. Deposit mints correct shares
    // =========================================================================

    function testFuzz_deposit_mintCorrectShares(uint256 amount) public {
        amount = bound(amount, 1, 5_000_000e6); // 1 wei to 5M USDC

        uint256 expectedShares = vault.convertToShares(amount);
        uint256 totalBefore = vault.totalAssets();

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        assertEq(shares, expectedShares, "Shares minted should match convertToShares");
        assertEq(vault.totalAssets(), totalBefore + amount, "Total assets should increase by deposit amount");
    }

    // =========================================================================
    // 2. Deposit then redeem round-trip
    // =========================================================================

    function testFuzz_depositRedeem_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 5_000_000e6); // 1 USDC to 5M USDC

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        // Rounding loss should be at most 1 wei
        assertGe(assetsBack, amount - 1, "Redeem should return at least amount - 1");
        assertLe(assetsBack, amount, "Redeem should not return more than deposited (no yield yet)");
    }

    // =========================================================================
    // 3. Deposit then withdraw round-trip (100% idle)
    // =========================================================================

    function testFuzz_depositWithdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 5_000_000e6);

        uint256 balBefore = IERC20(token).balanceOf(alice);

        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.prank(alice);
        vault.withdraw(amount, alice, alice);

        uint256 balAfter = IERC20(token).balanceOf(alice);
        assertEq(balAfter, balBefore, "Should get back exact amount when 100% idle");
    }

    // =========================================================================
    // 4. Multi-user share price fairness
    // =========================================================================

    function testFuzz_multiUser_sharePriceFairness(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 10_000e6, 2_000_000e6); // 10k to 2M
        a2 = bound(a2, 10_000e6, 2_000_000e6);

        // Alice deposits
        vm.prank(alice);
        vault.deposit(a1, alice);

        // Bob deposits
        vm.prank(bob);
        vault.deposit(a2, bob);

        // Rebalance to send funds to strategies
        vm.prank(keeper);
        vault.rebalance();

        // Warp 7 days — real yield accrues in protocols
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400); // ~7 days of blocks

        // Reconcile to recognize yield
        vm.prank(keeper);
        vault.reconcile();

        // Share price should be the same for both before any redemptions
        // (both deposited at the same price, same yield accrual)
        uint256 sharePriceBefore = vault.convertToAssets(1e12);

        // Both redeem all (compute maxRedeem right before each to avoid state changes between reads)
        uint256 aliceShares = vault.maxRedeem(alice);
        if (aliceShares == 0) return;
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);

        uint256 bobShares = vault.maxRedeem(bob);
        if (bobShares == 0) return;
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        // Both should get back at least what they deposited (yield > 0 over 7 days)
        assertGe(aliceAssets, a1 - 1, "Alice should get back at least her deposit");
        assertGe(bobAssets, a2 - 1, "Bob should get back at least his deposit");

        // Neither user should extract more than their deposit + total vault yield
        // (prevents rounding exploits giving free money)
        uint256 totalYield = (aliceAssets + bobAssets) > (a1 + a2)
            ? (aliceAssets + bobAssets) - (a1 + a2)
            : 0;
        assertLe(aliceAssets, a1 + totalYield, "Alice should not get more than deposit + total yield");
        assertLe(bobAssets, a2 + totalYield, "Bob should not get more than deposit + total yield");

        // Share price before redemptions should be at least ~1:1 (1 share = 1e12, 1 USDC = 1e6)
        assertGe(sharePriceBefore, 1e6 - 1, "Share price should be at least ~1:1");
    }

    // =========================================================================
    // 5. Share price never decreases after yield + reconcile
    // =========================================================================

    function testFuzz_sharePrice_neverDecreasesAfterYield(uint256 deposit_, uint256 daysElapsed) public {
        deposit_ = bound(deposit_, 10_000e6, 5_000_000e6);
        daysElapsed = bound(daysElapsed, 1, 90);

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 sharePriceBefore = vault.convertToAssets(1e12); // 1e12 = 1 share (6 + 6 decimals)

        // Warp time — yield accrues in real protocols
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        // Reconcile to recognize yield
        vm.prank(keeper);
        vault.reconcile();

        uint256 sharePriceAfter = vault.convertToAssets(1e12);

        assertGe(sharePriceAfter, sharePriceBefore, "Share price should not decrease after yield accrual");
    }

    // =========================================================================
    // 6. Withdrawal waterfall: idle first, then strategies
    // =========================================================================

    function testFuzz_withdrawal_waterfall(uint256 deposit_, uint256 withdrawPct) public {
        deposit_ = bound(deposit_, 100_000e6, 5_000_000e6);
        withdrawPct = bound(withdrawPct, 1, 100); // 1-100%

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        // Rebalance — ~97% goes to strategies, ~3% stays idle
        vm.prank(keeper);
        vault.rebalance();

        uint256 idleBefore = IERC20(token).balanceOf(address(vault));
        uint256 withdrawAmount = (deposit_ * withdrawPct) / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        // Cap at maxWithdraw
        uint256 maxW = vault.maxWithdraw(alice);
        if (withdrawAmount > maxW) withdrawAmount = maxW;
        if (withdrawAmount == 0) return;

        uint256 aliceBefore = IERC20(token).balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        uint256 aliceAfter = IERC20(token).balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, withdrawAmount, "Should receive exact withdrawal amount");

        // If withdrawal <= idle, strategies should be untouched
        if (withdrawAmount <= idleBefore) {
            // Sum tracked balances — they should not decrease
            uint256 count = vault.strategiesCount();
            for (uint256 i = 0; i < count; i++) {
                assertGt(vault.trackedBalance(vault.strategies(i)), 0, "Strategies should retain funds");
            }
        }
    }

    // =========================================================================
    // 7. Performance fee only above HWM
    // =========================================================================

    function testFuzz_fees_performanceOnlyAboveHWM(uint256 deposit_, uint256 daysElapsed) public {
        deposit_ = bound(deposit_, 100_000e6, 5_000_000e6);
        daysElapsed = bound(daysElapsed, 7, 90); // Need enough time for meaningful yield

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 hwmBefore = vault.highWaterMark();

        // Warp time for yield
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        vm.prank(keeper);
        vault.reconcile();

        uint256 sharePriceNow = vault.convertToAssets(1e12);

        vm.prank(keeper);
        vault.collectFees();

        uint256 hwmAfter = vault.highWaterMark();

        // If share price exceeded HWM, HWM should be updated
        if (sharePriceNow > hwmBefore) {
            assertGe(hwmAfter, hwmBefore, "HWM should not decrease");
        }
    }

    // =========================================================================
    // 9. convertToShares rounds down (no profit from rounding)
    // =========================================================================

    function testFuzz_convertToShares_roundsDown(uint256 assets) public {
        assets = bound(assets, 1, 10_000_000e6);

        // Seed the vault with some assets first (so share price != 1:1 trivially)
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        uint256 shares = vault.convertToShares(assets);
        uint256 assetsBack = vault.convertToAssets(shares);

        assertLe(assetsBack, assets, "convertToAssets(convertToShares(x)) <= x (rounds in vault's favor)");
    }

    // =========================================================================
    // 10. Deposit cap enforced
    // =========================================================================

    function testFuzz_depositCap_enforced(uint256 cap, uint256 deposit_) public {
        cap = bound(cap, 1_000e6, 1_000_000e6);
        deposit_ = bound(deposit_, 1e6, 5_000_000e6);

        vm.prank(admin);
        vault.setDepositCap(cap);

        if (deposit_ <= cap) {
            vm.prank(alice);
            vault.deposit(deposit_, alice);
            assertLe(vault.totalAssets(), cap, "Total assets should not exceed cap");
        } else {
            // Should only accept up to cap
            uint256 maxDep = vault.maxDeposit(alice);
            assertLe(maxDep, cap, "maxDeposit should not exceed cap");

            if (maxDep > 0) {
                vm.prank(alice);
                vault.deposit(maxDep, alice);
            }

            // Further deposit should revert with ERC4626ExceededMaxDeposit(receiver, assets, max).
            // Exact args depend on fuzzed state, so we keep a bare expectRevert here.
            vm.prank(bob);
            vm.expectRevert();
            vault.deposit(cap + 1, bob);
        }
    }

    // =========================================================================
    // 11. Asset conservation during rebalance
    // =========================================================================

    function testFuzz_rebalance_conservesAssets(uint256 deposit_) public {
        deposit_ = bound(deposit_, 10_000e6, 5_000_000e6);

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.rebalance();

        uint256 totalAfter = vault.totalAssets();

        // totalAssets should be unchanged (within 2 wei for rounding)
        assertApproxEqAbs(totalAfter, totalBefore, 2, "Rebalance should conserve total assets");
    }

    // =========================================================================
    // 12. totalAssets == idle + sum(trackedBalance)
    // =========================================================================

    function testFuzz_totalAssets_invariant(uint256 deposit_) public {
        deposit_ = bound(deposit_, 10_000e6, 5_000_000e6);

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(token).balanceOf(address(vault));
        uint256 sumTracked = 0;
        uint256 count = vault.strategiesCount();
        for (uint256 i = 0; i < count; i++) {
            sumTracked += vault.trackedBalance(vault.strategies(i));
        }

        assertEq(idle + sumTracked, vault.totalAssets(), "idle + sum(tracked) should equal totalAssets");
    }

    // =========================================================================
    // 13. Multiple deposits + single large withdrawal
    // =========================================================================

    function testFuzz_multiDeposit_largeWithdrawal(uint256 a1, uint256 a2, uint256 a3) public {
        a1 = bound(a1, 10_000e6, 1_000_000e6);
        a2 = bound(a2, 10_000e6, 1_000_000e6);
        a3 = bound(a3, 10_000e6, 1_000_000e6);

        vm.prank(alice);
        vault.deposit(a1, alice);
        vm.prank(bob);
        vault.deposit(a2, bob);
        vm.prank(charlie);
        vault.deposit(a3, charlie);

        vm.prank(keeper);
        vault.rebalance();

        // Alice withdraws everything she can
        uint256 maxW = vault.maxWithdraw(alice);
        if (maxW == 0) return;

        uint256 aliceBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
        uint256 aliceAfter = IERC20(token).balanceOf(alice);

        assertEq(aliceAfter - aliceBefore, maxW, "Should receive maxWithdraw amount");

        // Vault should still be solvent for remaining users
        uint256 totalRemaining = vault.totalAssets();
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        uint256 charlieValue = vault.convertToAssets(vault.balanceOf(charlie));
        assertGe(totalRemaining + 2, bobValue + charlieValue, "Vault should remain solvent for all users");
    }

    // =========================================================================
    // 14. Deposit-rebalance-warp-reconcile-withdraw cycle
    // =========================================================================

    function testFuzz_fullCycle(uint256 deposit_, uint256 daysElapsed, uint256 withdrawPct) public {
        deposit_ = bound(deposit_, 50_000e6, 3_000_000e6);
        daysElapsed = bound(daysElapsed, 1, 60);
        withdrawPct = bound(withdrawPct, 10, 100);

        // 1. Deposit
        vm.prank(alice);
        vault.deposit(deposit_, alice);

        // 2. Rebalance
        vm.prank(keeper);
        vault.rebalance();

        // 3. Time passes
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        // 4. Reconcile
        vm.prank(keeper);
        vault.reconcile();

        // 5. Collect fees
        vm.prank(keeper);
        vault.collectFees();

        // 6. Withdraw portion
        uint256 maxW = vault.maxWithdraw(alice);
        uint256 withdrawAmount = (maxW * withdrawPct) / 100;
        if (withdrawAmount == 0) return;

        uint256 balBefore = IERC20(token).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        uint256 balAfter = IERC20(token).balanceOf(alice);

        assertEq(balAfter - balBefore, withdrawAmount, "Should receive exact amount requested");

        // 7. totalAssets invariant still holds
        uint256 idle = IERC20(token).balanceOf(address(vault));
        uint256 sumTracked = 0;
        uint256 count = vault.strategiesCount();
        for (uint256 i = 0; i < count; i++) {
            sumTracked += vault.trackedBalance(vault.strategies(i));
        }
        assertEq(idle + sumTracked, vault.totalAssets(), "Invariant: idle + tracked == totalAssets");
    }

    // =========================================================================
    // 15. forceRedeem always succeeds for deposited user
    // =========================================================================

    function testFuzz_forceRedeem_alwaysSucceeds(uint256 amount) public {
        amount = bound(amount, 10_000e6, 2_000_000e6);

        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 aliceBalBefore = IERC20(token).balanceOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "Alice should have shares before forceRedeem");

        vm.prank(admin);
        vault.forceRedeem(alice);

        assertEq(vault.balanceOf(alice), 0, "Alice should have zero shares after forceRedeem");

        uint256 aliceBalAfter = IERC20(token).balanceOf(alice);
        assertGt(aliceBalAfter, aliceBalBefore, "Alice should have received funds from forceRedeem");

        // She should get back at least her deposit minus dust tolerance
        uint256 received = aliceBalAfter - aliceBalBefore;
        uint256 dustTolerance = amount / 10_000; // 1 bps
        uint256 perStrategyDust = 2 * vault.strategiesCount();
        uint256 tolerance = dustTolerance > perStrategyDust ? dustTolerance : perStrategyDust;
        assertGe(received + tolerance, amount, "Alice should receive approximately her deposit");
    }

    // =========================================================================
    // 16. Performance fee accrual after yield
    // =========================================================================

    function testFuzz_setPerformanceFee_feeAccrual(uint256 deposit_, uint256 daysElapsed) public {
        deposit_ = bound(deposit_, 100_000e6, 5_000_000e6);
        daysElapsed = bound(daysElapsed, 7, 90);

        uint256 hwmInitial = vault.highWaterMark();

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        // Warp time for yield accrual
        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        vm.prank(keeper);
        vault.reconcile();

        uint256 sharePriceAfterYield = vault.convertToAssets(1e12);
        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(keeper);
        vault.collectFees();

        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);

        // If yield was generated (share price above initial HWM), feeRecipient should get shares
        if (sharePriceAfterYield > hwmInitial) {
            assertGt(feeRecipientSharesAfter, feeRecipientSharesBefore, "Fee recipient should receive shares when yield > 0");
        }

        // HWM should never decrease below initial
        assertGe(vault.highWaterMark(), hwmInitial, "HWM should not decrease below initial value");
    }

    // =========================================================================
    // 17. Pausing a strategy reduces totalAssets, unpausing restores
    // =========================================================================

    function testFuzz_pauseStrategy_reducesTotalAssets(uint256 deposit_) public {
        deposit_ = bound(deposit_, 100_000e6, 5_000_000e6);

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 totalBefore = vault.totalAssets();

        // Pause the first strategy
        IStrategy firstStrategy = IStrategy(vault.strategies(0));
        uint256 firstTracked = vault.trackedBalance(firstStrategy);

        vm.prank(admin);
        vault.pauseStrategy(firstStrategy);

        uint256 totalAfterPause = vault.totalAssets();
        assertLt(totalAfterPause, totalBefore, "totalAssets should decrease after pausing a strategy");
        assertApproxEqAbs(totalAfterPause, totalBefore - firstTracked, 1, "totalAssets should decrease by paused strategy tracked balance");

        // Unpause
        vm.prank(admin);
        vault.unpauseStrategy(firstStrategy);

        uint256 totalAfterUnpause = vault.totalAssets();
        assertApproxEqAbs(totalAfterUnpause, totalBefore, 1, "totalAssets should be restored after unpausing");
    }

    // =========================================================================
    // 18. Reconcile never decreases share price
    // =========================================================================

    function testFuzz_reconcile_neverDecreasesSharePrice(uint256 deposit_, uint256 daysElapsed) public {
        deposit_ = bound(deposit_, 10_000e6, 5_000_000e6);
        daysElapsed = bound(daysElapsed, 1, 90);

        vm.prank(alice);
        vault.deposit(deposit_, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 sharePriceBefore = vault.convertToAssets(1e12);

        vm.warp(block.timestamp + daysElapsed * 1 days);
        vm.roll(block.number + daysElapsed * 7200);

        vm.prank(keeper);
        vault.reconcile();

        uint256 sharePriceAfter = vault.convertToAssets(1e12);
        assertGe(sharePriceAfter, sharePriceBefore, "Share price must not decrease after reconcile");
    }

    // =========================================================================
    // 19. Multi-deposit multi-withdraw solvency
    // =========================================================================

    function testFuzz_multiDeposit_multiWithdraw_solvency(
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 w1Pct,
        uint256 w2Pct,
        uint256 w3Pct
    ) public {
        a1 = bound(a1, 10_000e6, 500_000e6);
        a2 = bound(a2, 10_000e6, 500_000e6);
        a3 = bound(a3, 10_000e6, 500_000e6);
        w1Pct = bound(w1Pct, 1, 100);
        w2Pct = bound(w2Pct, 1, 100);
        w3Pct = bound(w3Pct, 1, 100);

        // Three users deposit
        vm.prank(alice);
        vault.deposit(a1, alice);
        vm.prank(bob);
        vault.deposit(a2, bob);
        vm.prank(charlie);
        vault.deposit(a3, charlie);

        vm.prank(keeper);
        vault.rebalance();

        // Each withdraws a random percentage
        _withdrawPct(alice, w1Pct);
        _withdrawPct(bob, w2Pct);
        _withdrawPct(charlie, w3Pct);

        // Vault must remain solvent: totalAssets >= value of all remaining shares
        uint256 totalRemaining = vault.totalAssets();
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        uint256 charlieValue = vault.convertToAssets(vault.balanceOf(charlie));
        uint256 sumValues = aliceValue + bobValue + charlieValue;

        // Allow 1 wei rounding per user
        assertGe(totalRemaining + 3, sumValues, "Vault must remain solvent: totalAssets >= sum of share values");
    }

    function _withdrawPct(address user, uint256 pct) internal {
        uint256 maxW = vault.maxWithdraw(user);
        uint256 withdrawAmount = (maxW * pct) / 100;
        if (withdrawAmount == 0) return;

        vm.prank(user);
        vault.withdraw(withdrawAmount, user, user);
    }
}
