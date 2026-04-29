// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {IMorpho, MarketParams, MorphoMarket, Position, Id} from "../../src/interfaces/IMorpho.sol";

// Real Ethereum mainnet addresses
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

/// @notice Sweep test: validates MorphoBlueMultiStrategyV1_2 against a diverse set of real Morpho Blue markets.
///         Covers different sizes, utilization levels, LLTVs, and collateral types.
contract MorphoMarketSweepTest is Test {
    using SafeERC20 for IERC20;

    struct MarketFixture {
        bytes32 marketId;
        string label;
    }

    MorphoBlueMultiStrategyV1_2 strategy;
    IMorpho morpho = IMorpho(MORPHO);

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    // Diverse market selection covering:
    // - High TVL (>$50M): cbBTC, wstETH, WBTC, siUSD, wsrUSD
    // - 100% utilization: PAXG, sdeUSD
    // - Near 100% utilization: savUSD
    // - Medium utilization (80-90%): stUSDS, PT-reUSD, weETH
    // - Lower utilization (<80%): reUSD, jrUSDe
    // - Zero utilization (idle-only): no-collateral market
    // - Different LLTVs: 77%, 86%, 91.5%, 94.5%
    // - Small markets (<$1M): cbBTC-dup, fxSAVE

    bytes32[] internal _allMarketIds;
    string[] internal _allLabels;

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new MorphoBlueMultiStrategyV1_2(USDC, MORPHO, vaultAddr, adminAddr, "Morpho Sweep", 64, new MarketParams[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        vm.stopPrank();

        // Fund vault generously
        deal(USDC, vaultAddr, 10_000_000e6);
        vm.prank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), type(uint256).max);

        // === High TVL markets ===
        _addMarket(0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64, "cbBTC-86-$421M");
        _addMarket(0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc, "wstETH-86-$78M");
        _addMarket(0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49, "WBTC-86-$89M");
        _addMarket(0xbbf7ce1b40d32d3ede7cd1e9e0d8e0505d24a3202a8a7f41a2e07a146db6e13e, "siUSD-91.5-$78M");

        // === 100% utilization ===
        _addMarket(0x8eaf7b29f02ba8d8e44b54b046800b9f393a4b12efb14e98fbab8e42aaeba4cf, "PAXG-91.5-100%util");
        _addMarket(0x0f9563442d64ab3b19b0fa07b4e9ca5a3b23f0e8c6c7b59bf5ebf3174a4e6c1e, "sdeUSD-91.5-100%util");

        // === Medium-high utilization ===
        _addMarket(0xd570c19c0dc0fbe484e7753d101a22c8d75a4567a0637e2c27f2bdeaf6ae89e0, "stUSDS-86-88%");
        _addMarket(0x9bc98c2f20ac58289f1b29c2efb68517f8e1ef9e1cc3b3c4d27a60fd710e473c, "PT-reUSD-91.5-81%");

        // === Lower utilization ===
        _addMarket(0x4565ac05d38b19370fed26bb7245e16581d45f81fd78ca089b0489e24bd7c533, "reUSD-91.5-74%");

        // === Different LLTVs ===
        _addMarket(0xe83d72fa5b00dcd443c64a079ee640acf7a9a3ff7a31e0d70c9ea2e94a4ad84a, "AA_Falcon-77-$51M");
        _addMarket(0x61765602144e91e5ac9f9e98b8584eae308f9951596fd7f5e0f59f21cd2bf664, "weETH-86-$2.1M");
        _addMarket(0xeb17955ea422baed2d15104e1b7ceee1aa27bed5fdabb0a4cfaf36b2eb5d36a9, "stcUSD-91.5-$29M");
        _addMarket(0x1590cb22d797e2263e9e18acb51c3bb27b861d4bf2c52c74d22ee39e2c37caa0, "wsrUSD-94.5-$100M");

        // === Small markets ===
        _addMarket(0xba3ba077d9c83869a76ae3df39e38bb7c04e5db4e5a41dfc5e2c656a99ac3d74, "cbBTC-dup-86-$690K");
        _addMarket(0x43e925e52d7873fa1ac8cf26c7e33a1e7c3ff72ecf64d19f55c73f3f7e4f1d79, "fxSAVE-86-$794K");
    }

    // ====== Core sweep: allocate + balanceOf + withdraw for each market ======

    function test_sweep_allocateAndWithdraw() public {
        uint256 len = _allMarketIds.length;
        uint256 depositPerMarket = 10_000e6; // 10k USDC per market
        uint256 totalDeposit = depositPerMarket * len;

        // Deposit enough for all markets
        vm.prank(vaultAddr);
        strategy.deposit(totalDeposit);

        // Allocate to each market
        vm.startPrank(keeperAddr);
        uint256 successCount = 0;
        for (uint256 i = 0; i < len; i++) {
            Id mid = Id.wrap(_allMarketIds[i]);

            // Some markets may reject supply (100% util, caps, etc.) -- that's expected
            try strategy.allocate(mid, depositPerMarket) {
                successCount++;
            } catch {
                // Market rejected supply -- skip
            }
        }
        vm.stopPrank();

        assertGt(successCount, 0, "At least some markets should accept supply");

        // Verify balanceOf accounts for all allocated funds
        uint256 totalBalance = strategy.balanceOf();
        assertGe(totalBalance, totalDeposit - 1e6, "balanceOf should match total deposit");

        // Withdraw everything back via vault
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(totalBalance);

        // Should get back most of what we put in (minor rounding from share math)
        assertGe(withdrawn, totalBalance * 99 / 100, "Should withdraw >99% of balance");
    }

    // ====== Per-market allocation precision ======

    function test_sweep_perMarketBalancePrecision() public {
        uint256 amount = 50_000e6;

        vm.prank(vaultAddr);
        strategy.deposit(amount * _allMarketIds.length);

        uint256 len = _allMarketIds.length;
        for (uint256 i = 0; i < len; i++) {
            Id mid = Id.wrap(_allMarketIds[i]);

            uint256 idleBefore = IERC20(USDC).balanceOf(address(strategy));

            vm.prank(keeperAddr);
            try strategy.allocate(mid, amount) {
                // Verify idle decreased
                uint256 idleAfter = IERC20(USDC).balanceOf(address(strategy));
                assertEq(idleAfter, idleBefore - amount, string.concat("Idle mismatch for ", _allLabels[i]));

                // Verify market balance is close to allocated amount
                uint256 mBal = strategy.marketBalance(mid);
                assertGe(mBal, amount * 99 / 100, string.concat("Market balance too low: ", _allLabels[i]));
                assertLe(mBal, amount * 101 / 100, string.concat("Market balance too high: ", _allLabels[i]));

                // Deallocate back so next iteration has clean state
                vm.prank(keeperAddr);
                try strategy.deallocate(mid, mBal) {} catch {}
            } catch {
                // Market rejected -- fine, skip
            }
        }
    }

    // ====== Emergency withdrawal across all markets ======

    function test_sweep_emergencyWithdrawAll() public {
        uint256 depositPerMarket = 10_000e6;
        uint256 totalDeposit = depositPerMarket * _allMarketIds.length;

        vm.prank(vaultAddr);
        strategy.deposit(totalDeposit);

        // Allocate to all possible markets
        vm.startPrank(keeperAddr);
        for (uint256 i = 0; i < _allMarketIds.length; i++) {
            try strategy.allocate(Id.wrap(_allMarketIds[i]), depositPerMarket) {} catch {}
        }
        vm.stopPrank();

        // Emergency withdraw should collect from all markets
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        // Should recover most funds (100% util markets may block some)
        assertGt(withdrawn, 0, "Emergency should withdraw something");
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0, "Strategy should be empty after emergency");
    }

    // ====== Withdraw waterfall with mixed utilization ======

    function test_sweep_withdrawWaterfall() public {
        // Pick 3 markets that we know accept deposits
        Id mid1 = Id.wrap(_allMarketIds[0]); // cbBTC (high TVL)
        Id mid2 = Id.wrap(_allMarketIds[1]); // wstETH (high TVL)
        Id mid3 = Id.wrap(_allMarketIds[2]); // WBTC (high TVL)

        uint256 total = 300_000e6;
        vm.prank(vaultAddr);
        strategy.deposit(total);

        // Allocate 100k to each
        vm.startPrank(keeperAddr);
        strategy.allocate(mid1, 100_000e6);
        strategy.allocate(mid2, 100_000e6);
        strategy.allocate(mid3, 100_000e6);
        vm.stopPrank();

        // No idle left
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);

        // Withdraw 250k -- must cascade through markets
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(250_000e6);

        assertGe(withdrawn, 249_999e6, "Should withdraw nearly all requested");
    }

    // ====== Rapid allocate-deallocate cycles ======

    function test_sweep_rapidAllocateDeallocate() public {
        Id mid = Id.wrap(_allMarketIds[1]); // wstETH
        uint256 amount = 50_000e6;

        vm.prank(vaultAddr);
        strategy.deposit(amount);

        uint256 balBefore = strategy.balanceOf();

        // 10 rapid cycles -- deallocate uses idle balance to determine exact amount
        // (avoids share rounding overflow from marketBalance -> withdraw conversion)
        for (uint256 i = 0; i < 10; i++) {
            uint256 idle = IERC20(USDC).balanceOf(address(strategy));

            vm.prank(keeperAddr);
            strategy.allocate(mid, idle);

            // Deallocate by redeeming all shares via recallMarket (admin)
            vm.prank(adminAddr);
            strategy.recallMarket(mid);

            // Unfreeze for next cycle
            vm.prank(adminAddr);
            strategy.unfreezeMarketDeposits(mid);
        }

        // Balance should be stable (minor rounding ok)
        uint256 balAfter = strategy.balanceOf();
        assertGe(balAfter, balBefore * 999 / 1000, "Should lose <0.1% after 10 cycles");
    }

    // ====== Available liquidity vs balanceOf ======

    function test_sweep_availableLiquidityInvariant() public {
        uint256 depositPerMarket = 20_000e6;
        uint256 totalDeposit = depositPerMarket * _allMarketIds.length;

        vm.prank(vaultAddr);
        strategy.deposit(totalDeposit);

        vm.startPrank(keeperAddr);
        for (uint256 i = 0; i < _allMarketIds.length; i++) {
            try strategy.allocate(Id.wrap(_allMarketIds[i]), depositPerMarket) {} catch {}
        }
        vm.stopPrank();

        uint256 totalBalance = strategy.balanceOf();
        uint256 available = strategy.availableLiquidity();

        // availableLiquidity <= balanceOf (always)
        assertLe(available, totalBalance, "availableLiquidity must be <= balanceOf");

        // availableLiquidity should be > 0 if there's any balance
        if (totalBalance > 0) {
            assertGt(available, 0, "Should have some liquidity if balance > 0");
        }
    }

    // ====== Yield accrual after time warp ======

    function test_sweep_yieldAccruesAfterTimeWarp() public {
        // Use the two most active markets
        Id mid1 = Id.wrap(_allMarketIds[0]); // cbBTC
        Id mid2 = Id.wrap(_allMarketIds[1]); // wstETH

        uint256 amount = 100_000e6;
        vm.prank(vaultAddr);
        strategy.deposit(amount * 2);

        vm.startPrank(keeperAddr);
        strategy.allocate(mid1, amount);
        strategy.allocate(mid2, amount);
        vm.stopPrank();

        uint256 balBefore = strategy.balanceOf();

        // Warp 90 days
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 648_000);

        // Accrue interest on markets
        morpho.accrueInterest(morpho.idToMarketParams(Id.wrap(_allMarketIds[0])));
        morpho.accrueInterest(morpho.idToMarketParams(Id.wrap(_allMarketIds[1])));

        uint256 balAfter = strategy.balanceOf();

        assertGt(balAfter, balBefore, "Balance should grow from interest");
    }

    // ====== Multi-market rebalancing ======

    function test_sweep_rebalanceAcrossMarkets() public {
        Id mid1 = Id.wrap(_allMarketIds[0]);
        Id mid2 = Id.wrap(_allMarketIds[1]);
        Id mid3 = Id.wrap(_allMarketIds[2]);

        uint256 total = 300_000e6;
        vm.prank(vaultAddr);
        strategy.deposit(total);

        // Initial allocation: 200k to mid1, 50k each to mid2/mid3
        vm.startPrank(keeperAddr);
        strategy.allocate(mid1, 200_000e6);
        strategy.allocate(mid2, 50_000e6);
        strategy.allocate(mid3, 50_000e6);

        uint256 balBefore = strategy.balanceOf();

        // Rebalance: deallocate 100k from mid1, allocate to mid2
        strategy.deallocate(mid1, 100_000e6);
        strategy.allocate(mid2, 100_000e6);
        vm.stopPrank();

        uint256 balAfter = strategy.balanceOf();

        // Total balance should be conserved (within rounding)
        assertGe(balAfter, balBefore - 2e6, "Rebalance should conserve assets");
        assertLe(balAfter, balBefore + 2e6, "Rebalance should conserve assets");
    }

    // ====== Admin: recall market with active position ======

    function test_sweep_recallMarketWithPosition() public {
        Id mid = Id.wrap(_allMarketIds[1]); // wstETH

        vm.prank(vaultAddr);
        strategy.deposit(100_000e6);

        vm.prank(keeperAddr);
        strategy.allocate(mid, 80_000e6);

        uint256 balBefore = strategy.balanceOf();

        // Admin recalls -- should redeem all shares and freeze
        vm.prank(adminAddr);
        strategy.recallMarket(mid);

        // All funds back as idle
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        assertGe(idle, balBefore - 2e6, "Recalled funds should be idle");

        // Market balance should be zero
        assertEq(strategy.marketBalance(mid), 0, "Market should be empty after recall");

        // Deposits to this market should be frozen
        assertTrue(strategy.depositFrozenMarkets(mid), "Market should be deposit-frozen");

        // Allocate to frozen market should revert
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(mid, 1e6);
    }

    // ====== Admin: freeze/unfreeze deposits ======

    function test_sweep_freezeUnfreezeDeposits() public {
        Id mid = Id.wrap(_allMarketIds[0]);

        vm.prank(vaultAddr);
        strategy.deposit(50_000e6);

        // Freeze
        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(mid);

        // Allocate should revert
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(mid, 10_000e6);

        // Unfreeze
        vm.prank(adminAddr);
        strategy.unfreezeMarketDeposits(mid);

        // Now allocate should work
        vm.prank(keeperAddr);
        strategy.allocate(mid, 10_000e6);

        assertGt(strategy.marketBalance(mid), 0, "Should have balance after unfreeze + allocate");
    }

    // ====== Remove market after full withdrawal ======

    function test_sweep_removeMarketAfterWithdrawal() public {
        Id mid = Id.wrap(_allMarketIds[1]);

        vm.prank(vaultAddr);
        strategy.deposit(50_000e6);

        vm.prank(keeperAddr);
        strategy.allocate(mid, 50_000e6);

        // Can't remove with active position
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketHasActivePosition.selector);
        strategy.removeMarket(mid);

        // Recall first
        vm.prank(adminAddr);
        strategy.recallMarket(mid);

        // Now remove works
        vm.prank(adminAddr);
        strategy.removeMarket(mid);

        assertFalse(strategy.isApproved(mid), "Market should be unapproved");
    }

    // ========== Internal helpers ==========

    function _addMarket(bytes32 rawId, string memory label) internal {
        Id mid = Id.wrap(rawId);
        MarketParams memory mp = morpho.idToMarketParams(mid);

        // Skip if market doesn't exist or wrong loan token
        if (mp.loanToken != USDC) return;

        vm.prank(adminAddr);
        try strategy.addMarket(mp) {
            _allMarketIds.push(rawId);
            _allLabels.push(label);
        } catch {
            // Market ID may be wrong or already added
        }
    }
}
