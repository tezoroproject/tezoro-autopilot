// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IMorpho, MarketParams, Id} from "../../src/interfaces/IMorpho.sol";

// -- Real Ethereum mainnet addresses --
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

// MetaMorpho USDC vaults (ERC-4626)
address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
address constant GAUNTLET_USDC_CORE = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

// Morpho Blue USDC lending market IDs
bytes32 constant USDC_WSTETH_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
bytes32 constant USDC_WBTC_MARKET = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;

// ============================================================================
// ERC4626 Multi-Strategy Integration Tests
// ============================================================================

/// @notice Integration tests: TezoroV1_2 + ERC4626MultiStrategyV1_2 + real MetaMorpho vaults.
contract ERC4626MultiIntegrationTest is Test {
    using SafeERC20 for IERC20;

    TezoroV1_2 vault;
    ERC4626MultiStrategyV1_2 multiStrategy;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant USER_BAL = 500_000e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        // Deploy vault
        vault = new TezoroV1_2(
            IERC20(USDC),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            1_500, // 15% performance fee
            300    // 3% idle buffer
        );

        // Deploy multi-strategy with vault as the caller
        multiStrategy = new ERC4626MultiStrategyV1_2(USDC, address(vault), admin, "MetaMorpho Multi", 64, new address[](0));

        // Admin setup: sub-vaults, keeper, register with vault
        vm.startPrank(admin);
        multiStrategy.setKeeper(keeper);
        multiStrategy.addSubVault(STEAKHOUSE_USDC);
        multiStrategy.addSubVault(GAUNTLET_USDC_CORE);

        vault.addStrategy(IStrategy(address(multiStrategy)));

        // 97% to multi-strategy (3% idle buffer)
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(multiStrategy));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9_700;
        vault.rebalance(strats, bps);

        vault.setKeeper(keeper);
        vm.stopPrank();

        // Fund users
        deal(USDC, alice, USER_BAL);
        deal(USDC, bob, USER_BAL);
        deal(USDC, charlie, USER_BAL);
        vm.prank(alice);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
        vm.prank(charlie);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
    }

    // ====== Full lifecycle ======

    function test_fullLifecycle() public {
        // 1. Alice deposits
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        assertGt(shares, 0);

        // 2. Keeper rebalances -> funds flow to multi-strategy as idle
        vm.prank(keeper);
        vault.rebalance();

        uint256 stratBalance = multiStrategy.balanceOf();
        assertGt(stratBalance, 0, "Strategy should have funds after rebalance");

        // 3. Keeper sub-allocates across MetaMorpho vaults
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        uint256 perVault = idle / 2;

        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, perVault);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - perVault);
        vm.stopPrank();

        // Verify funds are deployed
        assertGt(multiStrategy.subVaultBalance(STEAKHOUSE_USDC), 0);
        assertGt(multiStrategy.subVaultBalance(GAUNTLET_USDC_CORE), 0);

        // 4. Warp 30 days for yield
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 5. Reconcile picks up yield
        uint256 totalBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.reconcile();
        assertGe(vault.totalAssets(), totalBefore, "Assets should grow after reconcile");

        // 6. Alice withdraws
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 redeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);

        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        assertGe(received, DEPOSIT * 99 / 100, "Should get back >99% of deposit");
    }

    // ====== Rebalance ======

    function test_rebalance_depositsIntoMultiStrategy() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        // Multi-strategy should hold ~97% of deposit as idle USDC
        uint256 stratBalance = multiStrategy.balanceOf();
        uint256 expected = DEPOSIT * 97 / 100;
        assertGe(stratBalance, expected - 1e6, "Strategy should hold ~97% of deposit");

        // Funds are idle inside the strategy (not yet sub-allocated)
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        assertEq(idle, stratBalance, "All strategy funds should be idle before sub-allocation");
    }

    // ====== Sub-allocation ======

    function test_subAllocate_afterRebalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        assertGt(idle, 0);

        // Sub-allocate 60/40 split
        uint256 toSteakhouse = idle * 60 / 100;
        uint256 toGauntlet = idle - toSteakhouse;

        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, toSteakhouse);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, toGauntlet);
        vm.stopPrank();

        // No idle left
        assertEq(IERC20(USDC).balanceOf(address(multiStrategy)), 0);

        // balanceOf still reports full amount
        assertGe(multiStrategy.balanceOf(), idle - 2e6);

        // Vault totalAssets unchanged (within rounding)
        assertGe(vault.totalAssets(), DEPOSIT - 2e6);
    }

    // ====== Withdraw waterfall through vault and sub-vaults ======

    function test_withdraw_waterfall_throughVaultAndSubVaults() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Sub-allocate all idle
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
        vm.stopPrank();

        // Withdraw 80% -- must cascade: vault idle -> strategy idle (0) -> sub-vaults
        uint256 withdrawAmt = DEPOSIT * 80 / 100;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        assertEq(received, withdrawAmt);
    }

    // ====== Reconcile picks up yield ======

    function test_reconcile_picksUpYield() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Sub-allocate into real vaults so yield accrues
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        vm.prank(keeper);
        vault.reconcile();

        assertGt(vault.totalAssets(), totalBefore, "Yield should increase totalAssets");
    }

    // ====== Emergency remove strategy ======

    function test_emergencyRecallToIdle() public {
        // removeStrategy reverts with StrategyNotFullyRecovered when
        // emergencyWithdraw cannot fully match the live tracked balance.
        // For sub-allocating strategies (Morpho multi, ERC4626 multi)
        // per-market share/asset rounding leaves a few wei behind, so the
        // operator-safe escape is recallToIdle: drain everything that
        // liquidly comes back, freeze deposits, and leave the
        // strategy in the active list until any rounding remainder settles.
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
        vm.stopPrank();

        uint256 vaultBalBefore = IERC20(USDC).balanceOf(address(vault));

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(multiStrategy)));

        uint256 vaultBalAfter = IERC20(USDC).balanceOf(address(vault));
        assertGt(vaultBalAfter, vaultBalBefore, "Funds should return to vault");
        // Strategy is frozen for new deposits but still in the active set
        // until the rounding remainder is fully reconciled and removed.
        assertTrue(vault.depositFrozenStrategies(IStrategy(address(multiStrategy))));
    }

    // ====== Multiple users fairness ======

    function test_multipleUsers_fairness() public {
        // Alice deposits first
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        // Sub-allocate
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.prank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle);

        // Warp -- yield accrues
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        vm.prank(keeper);
        vault.reconcile();

        // Bob deposits after yield -- should get fewer shares per USDC
        vm.prank(bob);
        uint256 bobShares = vault.deposit(DEPOSIT, bob);

        uint256 aliceSPU = aliceShares * 1e18 / DEPOSIT;
        uint256 bobSPU = bobShares * 1e18 / DEPOSIT;
        assertLt(bobSPU, aliceSPU, "Bob should get fewer shares (higher share price)");

        // Both can withdraw
        uint256 aliceRedeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceRedeemable, alice, alice);

        uint256 bobRedeemable = vault.maxRedeem(bob);
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobRedeemable, bob, bob);

        assertGe(aliceOut, DEPOSIT, "Alice should profit from yield");
        assertGe(bobOut, DEPOSIT * 99 / 100, "Bob should get back >99%");
    }

    // ====== Partial sub-allocation ======

    function test_partialSubAllocation() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Only allocate to one sub-vault, leave rest as idle
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.prank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);

        // Withdraw should still work (uses idle first, then sub-vault)
        uint256 withdrawAmt = DEPOSIT * 80 / 100;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, withdrawAmt);
    }

    // ====== Deallocate then withdraw ======

    function test_deallocate_thenWithdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        // Sub-allocate all
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle);
        vm.stopPrank();

        // Keeper deallocates half back to idle
        vm.prank(keeper);
        multiStrategy.deallocate(STEAKHOUSE_USDC, idle / 2);

        uint256 stratIdle = IERC20(USDC).balanceOf(address(multiStrategy));
        assertGe(stratIdle, idle / 2 - 1e6, "Half should be back as idle");

        // User withdraw should succeed pulling from strategy idle
        uint256 withdrawAmt = DEPOSIT / 4;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, withdrawAmt);
    }

    // ====== Temporal multi-user lifecycle ======

    /// @notice Complex scenario: 3 users, 3 time warps, partial withdrawals, top-ups.
    /// Validates fairness and solvency across the full two-level allocation flow.
    function test_temporalMultiUser_lifecycle() public {
        // --- Phase 1: Alice deposits 100k, rebalance, sub-allocate ---
        vm.prank(alice);
        uint256 aliceShares1 = vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
        multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
        vm.stopPrank();

        // --- Phase 2: Warp 14d, reconcile ---
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);

        vm.prank(keeper);
        vault.reconcile();

        uint256 priceAfterPhase2 = vault.convertToAssets(1e18);

        // --- Phase 3: Bob deposits 50k at higher share price, rebalance, sub-allocate ---
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob);

        uint256 aliceSPU = aliceShares1 * 1e18 / DEPOSIT;
        uint256 bobSPU = bobShares * 1e18 / 50_000e6;
        assertLt(bobSPU, aliceSPU, "Bob should get fewer shares (entered at higher price)");

        vm.prank(keeper);
        vault.rebalance();

        idle = IERC20(USDC).balanceOf(address(multiStrategy));
        if (idle > 0) {
            vm.startPrank(keeper);
            multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
            multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
            vm.stopPrank();
        }

        // --- Phase 4: Warp 14d, reconcile ---
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);

        vm.prank(keeper);
        vault.reconcile();

        uint256 priceAfterPhase4 = vault.convertToAssets(1e18);
        assertGt(priceAfterPhase4, priceAfterPhase2, "Share price should keep rising");

        // --- Phase 5: Charlie deposits 200k, Bob partially withdraws 25k ---
        vm.prank(charlie);
        uint256 charlieShares = vault.deposit(200_000e6, charlie);

        uint256 charlieSPU = charlieShares * 1e18 / 200_000e6;
        assertLt(charlieSPU, bobSPU, "Charlie should get even fewer shares");

        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(25_000e6, bob, bob);
        uint256 bobPartialOut = IERC20(USDC).balanceOf(bob) - bobBefore;
        assertEq(bobPartialOut, 25_000e6, "Bob should withdraw exactly 25k");

        // --- Phase 6: Alice tops up 50k ---
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // --- Phase 7: Rebalance, sub-allocate, warp 14d, reconcile ---
        vm.prank(keeper);
        vault.rebalance();

        idle = IERC20(USDC).balanceOf(address(multiStrategy));
        if (idle > 0) {
            vm.startPrank(keeper);
            multiStrategy.allocate(STEAKHOUSE_USDC, idle / 2);
            multiStrategy.allocate(GAUNTLET_USDC_CORE, idle - idle / 2);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);

        vm.prank(keeper);
        vault.reconcile();

        // --- Phase 8: Everyone redeems all ---
        uint256 aliceBalBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceRedeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(aliceRedeemable, alice, alice);
        uint256 aliceOut = IERC20(USDC).balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = IERC20(USDC).balanceOf(bob);
        uint256 bobRedeemable = vault.maxRedeem(bob);
        vm.prank(bob);
        vault.redeem(bobRedeemable, bob, bob);
        uint256 bobFinalOut = IERC20(USDC).balanceOf(bob) - bobBalBefore;
        uint256 bobTotalOut = bobPartialOut + bobFinalOut;

        uint256 charlieBalBefore = IERC20(USDC).balanceOf(charlie);
        uint256 charlieRedeemable = vault.maxRedeem(charlie);
        vm.prank(charlie);
        vault.redeem(charlieRedeemable, charlie, charlie);
        uint256 charlieOut = IERC20(USDC).balanceOf(charlie) - charlieBalBefore;

        // --- Assertions ---
        uint256 aliceNetIn = DEPOSIT + 50_000e6; // 150k
        assertGe(aliceOut, aliceNetIn * 99 / 100, "Alice should get back >= 99% of 150k");

        assertGe(bobTotalOut, 50_000e6 * 99 / 100, "Bob total out should be >= 99% of 50k");

        assertGe(charlieOut, 200_000e6 * 99 / 100, "Charlie should get back >= 99% of 200k");

        // Solvency: total out >= total in
        uint256 totalIn = aliceNetIn + 50_000e6 + 200_000e6; // 400k
        uint256 totalOut = aliceOut + bobTotalOut + charlieOut;
        assertGe(totalOut, totalIn * 99 / 100, "Vault should be solvent");
    }
}

// ============================================================================
// Morpho Blue Multi-Strategy Integration Tests
// ============================================================================

/// @notice Integration tests: TezoroV1_2 + MorphoBlueMultiStrategyV1_2 + real Morpho Blue markets.
contract MorphoBlueMultiIntegrationTest is Test {
    using SafeERC20 for IERC20;

    TezoroV1_2 vault;
    MorphoBlueMultiStrategyV1_2 multiStrategy;
    IMorpho morpho = IMorpho(MORPHO);

    MarketParams mpWstETH;
    MarketParams mpWBTC;
    Id midWstETH;
    Id midWBTC;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant DEPOSIT = 100_000e6;
    uint256 constant USER_BAL = 500_000e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        // Fetch real market params
        mpWstETH = morpho.idToMarketParams(Id.wrap(USDC_WSTETH_MARKET));
        mpWBTC = morpho.idToMarketParams(Id.wrap(USDC_WBTC_MARKET));
        midWstETH = Id.wrap(USDC_WSTETH_MARKET);
        midWBTC = Id.wrap(USDC_WBTC_MARKET);

        // Deploy vault
        vault = new TezoroV1_2(
            IERC20(USDC),
            "Tezoro USDC-B",
            "tUSDC-B",
            admin,
            feeRecipient,
            1_500,
            300
        );

        // Deploy multi-strategy
        multiStrategy = new MorphoBlueMultiStrategyV1_2(USDC, MORPHO, address(vault), admin, "Morpho Multi", 64, new MarketParams[](0));

        // Admin setup
        vm.startPrank(admin);
        multiStrategy.setKeeper(keeper);
        multiStrategy.addMarket(mpWstETH);
        multiStrategy.addMarket(mpWBTC);

        vault.addStrategy(IStrategy(address(multiStrategy)));

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(multiStrategy));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9_700;
        vault.rebalance(strats, bps);

        vault.setKeeper(keeper);
        vm.stopPrank();

        // Fund users
        deal(USDC, alice, USER_BAL);
        deal(USDC, bob, USER_BAL);
        deal(USDC, charlie, USER_BAL);
        vm.prank(alice);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
        vm.prank(charlie);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
    }

    // ====== Full lifecycle ======

    function test_fullLifecycle() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        assertGt(shares, 0);

        vm.prank(keeper);
        vault.rebalance();

        uint256 stratBalance = multiStrategy.balanceOf();
        assertGt(stratBalance, 0);

        // Sub-allocate
        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        uint256 perMarket = idle / 2;
        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, perMarket);
        multiStrategy.allocate(midWBTC, idle - perMarket);
        vm.stopPrank();

        assertGt(multiStrategy.marketBalance(midWstETH), 0);
        assertGt(multiStrategy.marketBalance(midWBTC), 0);

        // Warp and accrue interest on both Morpho markets
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        uint256 totalBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.reconcile();
        assertGe(vault.totalAssets(), totalBefore);

        // Withdraw
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 redeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);

        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        assertGe(received, DEPOSIT * 99 / 100);
    }

    // ====== Rebalance ======

    function test_rebalance_depositsIntoMultiStrategy() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 stratBalance = multiStrategy.balanceOf();
        uint256 expected = DEPOSIT * 97 / 100;
        assertGe(stratBalance, expected - 1e6);

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        assertEq(idle, stratBalance, "All strategy funds should be idle before sub-allocation");
    }

    // ====== Sub-allocation ======

    function test_subAllocate_afterRebalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));

        uint256 toWstETH = idle * 60 / 100;
        uint256 toWBTC = idle - toWstETH;

        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, toWstETH);
        multiStrategy.allocate(midWBTC, toWBTC);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(multiStrategy)), 0);
        assertGe(multiStrategy.balanceOf(), idle - 2e6);
        assertGe(vault.totalAssets(), DEPOSIT - 2e6);
    }

    // ====== Withdraw waterfall ======

    function test_withdraw_waterfall_throughVaultAndMarkets() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, idle / 2);
        multiStrategy.allocate(midWBTC, idle - idle / 2);
        vm.stopPrank();

        uint256 withdrawAmt = DEPOSIT * 80 / 100;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, withdrawAmt);
    }

    // ====== Reconcile ======

    function test_reconcile_picksUpYield() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, idle / 2);
        multiStrategy.allocate(midWBTC, idle - idle / 2);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        vm.prank(keeper);
        vault.reconcile();

        assertGt(vault.totalAssets(), totalBefore, "Yield should increase totalAssets");
    }

    // ====== Emergency remove ======

    function test_emergencyRecallToIdle() public {
        // See ERC4626MultiIntegrationTest.test_emergencyRecallToIdle for why
        // recallToIdle is the correct exit primitive for sub-allocating
        // strategies.
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, idle / 2);
        multiStrategy.allocate(midWBTC, idle - idle / 2);
        vm.stopPrank();

        uint256 vaultBalBefore = IERC20(USDC).balanceOf(address(vault));

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(multiStrategy)));

        uint256 vaultBalAfter = IERC20(USDC).balanceOf(address(vault));
        assertGt(vaultBalAfter, vaultBalBefore, "Funds should return to vault");
        assertTrue(vault.depositFrozenStrategies(IStrategy(address(multiStrategy))));
    }

    // ====== Multiple users fairness ======

    function test_multipleUsers_fairness() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.prank(keeper);
        multiStrategy.allocate(midWstETH, idle);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);
        morpho.accrueInterest(mpWstETH);

        vm.prank(keeper);
        vault.reconcile();

        vm.prank(bob);
        uint256 bobShares = vault.deposit(DEPOSIT, bob);

        uint256 aliceSPU = aliceShares * 1e18 / DEPOSIT;
        uint256 bobSPU = bobShares * 1e18 / DEPOSIT;
        assertLt(bobSPU, aliceSPU, "Bob should get fewer shares (higher share price)");

        uint256 aliceRedeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceRedeemable, alice, alice);

        uint256 bobRedeemable = vault.maxRedeem(bob);
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobRedeemable, bob, bob);

        assertGe(aliceOut, DEPOSIT, "Alice should profit from yield");
        assertGe(bobOut, DEPOSIT * 99 / 100, "Bob should get back >99%");
    }

    // ====== Partial sub-allocation ======

    function test_partialSubAllocation() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.prank(keeper);
        multiStrategy.allocate(midWstETH, idle / 2);

        uint256 withdrawAmt = DEPOSIT * 80 / 100;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, withdrawAmt);
    }

    // ====== Deallocate then withdraw ======

    function test_deallocate_thenWithdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.prank(keeper);
        multiStrategy.allocate(midWstETH, idle);

        vm.prank(keeper);
        multiStrategy.deallocate(midWstETH, idle / 2);

        uint256 stratIdle = IERC20(USDC).balanceOf(address(multiStrategy));
        assertGe(stratIdle, idle / 2 - 1e6);

        uint256 withdrawAmt = DEPOSIT / 4;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmt, alice, alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, withdrawAmt);
    }

    // ====== Temporal multi-user lifecycle ======

    /// @notice Complex scenario: 3 users, 3 time warps, partial withdrawals, top-ups.
    /// Validates fairness and solvency across the full two-level allocation flow.
    function test_temporalMultiUser_lifecycle() public {
        // --- Phase 1: Alice deposits 100k, rebalance, sub-allocate ---
        vm.prank(alice);
        uint256 aliceShares1 = vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = IERC20(USDC).balanceOf(address(multiStrategy));
        vm.startPrank(keeper);
        multiStrategy.allocate(midWstETH, idle / 2);
        multiStrategy.allocate(midWBTC, idle - idle / 2);
        vm.stopPrank();

        // --- Phase 2: Warp 14d, accrue interest, reconcile ---
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        vm.prank(keeper);
        vault.reconcile();

        uint256 priceAfterPhase2 = vault.convertToAssets(1e18);

        // --- Phase 3: Bob deposits 50k at higher share price, rebalance, sub-allocate ---
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob);

        uint256 aliceSPU = aliceShares1 * 1e18 / DEPOSIT;
        uint256 bobSPU = bobShares * 1e18 / 50_000e6;
        assertLt(bobSPU, aliceSPU, "Bob should get fewer shares (entered at higher price)");

        vm.prank(keeper);
        vault.rebalance();

        idle = IERC20(USDC).balanceOf(address(multiStrategy));
        if (idle > 0) {
            vm.startPrank(keeper);
            multiStrategy.allocate(midWstETH, idle / 2);
            multiStrategy.allocate(midWBTC, idle - idle / 2);
            vm.stopPrank();
        }

        // --- Phase 4: Warp 14d, accrue interest, reconcile ---
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        vm.prank(keeper);
        vault.reconcile();

        uint256 priceAfterPhase4 = vault.convertToAssets(1e18);
        assertGt(priceAfterPhase4, priceAfterPhase2, "Share price should keep rising");

        // --- Phase 5: Charlie deposits 200k, Bob partially withdraws 25k ---
        vm.prank(charlie);
        uint256 charlieShares = vault.deposit(200_000e6, charlie);

        uint256 charlieSPU = charlieShares * 1e18 / 200_000e6;
        assertLt(charlieSPU, bobSPU, "Charlie should get even fewer shares");

        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(25_000e6, bob, bob);
        uint256 bobPartialOut = IERC20(USDC).balanceOf(bob) - bobBefore;
        assertEq(bobPartialOut, 25_000e6, "Bob should withdraw exactly 25k");

        // --- Phase 6: Alice tops up 50k ---
        vm.prank(alice);
        vault.deposit(50_000e6, alice);

        // --- Phase 7: Rebalance, sub-allocate, warp 14d, reconcile ---
        vm.prank(keeper);
        vault.rebalance();

        idle = IERC20(USDC).balanceOf(address(multiStrategy));
        if (idle > 0) {
            vm.startPrank(keeper);
            multiStrategy.allocate(midWstETH, idle / 2);
            multiStrategy.allocate(midWBTC, idle - idle / 2);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + 100_800);
        morpho.accrueInterest(mpWstETH);
        morpho.accrueInterest(mpWBTC);

        vm.prank(keeper);
        vault.reconcile();

        // --- Phase 8: Everyone redeems all ---
        uint256 aliceBalBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceRedeemable = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(aliceRedeemable, alice, alice);
        uint256 aliceOut = IERC20(USDC).balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = IERC20(USDC).balanceOf(bob);
        uint256 bobRedeemable = vault.maxRedeem(bob);
        vm.prank(bob);
        vault.redeem(bobRedeemable, bob, bob);
        uint256 bobFinalOut = IERC20(USDC).balanceOf(bob) - bobBalBefore;
        uint256 bobTotalOut = bobPartialOut + bobFinalOut;

        uint256 charlieBalBefore = IERC20(USDC).balanceOf(charlie);
        uint256 charlieRedeemable = vault.maxRedeem(charlie);
        vm.prank(charlie);
        vault.redeem(charlieRedeemable, charlie, charlie);
        uint256 charlieOut = IERC20(USDC).balanceOf(charlie) - charlieBalBefore;

        // --- Assertions ---
        uint256 aliceNetIn = DEPOSIT + 50_000e6; // 150k
        assertGe(aliceOut, aliceNetIn * 99 / 100, "Alice should get back >= 99% of 150k");

        assertGe(bobTotalOut, 50_000e6 * 99 / 100, "Bob total out should be >= 99% of 50k");

        assertGe(charlieOut, 200_000e6 * 99 / 100, "Charlie should get back >= 99% of 200k");

        // Solvency: total out >= total in
        uint256 totalIn = aliceNetIn + 50_000e6 + 200_000e6; // 400k
        uint256 totalOut = aliceOut + bobTotalOut + charlieOut;
        assertGe(totalOut, totalIn * 99 / 100, "Vault should be solvent");
    }
}
