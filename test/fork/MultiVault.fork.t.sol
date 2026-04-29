// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {AaveV3StrategyV1_2} from "../../src/strategies/AaveV3StrategyV1_2.sol";
import {CompoundV3StrategyV1_2} from "../../src/strategies/CompoundV3StrategyV1_2.sol";
import {FluidStrategyV1_2} from "../../src/strategies/FluidStrategyV1_2.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IMorpho, MarketParams, Id} from "../../src/interfaces/IMorpho.sol";

/// @title MultiVaultForkTest — deploy 3 vaults (A, B, C) on Ethereum fork, test them all
/// @notice Validates that multiple vaults coexist correctly:
///         - Independent deposits/withdrawals per vault
///         - Each vault's keeper operations work
///         - No cross-vault interference
///         - Different strategy compositions all function
contract MultiVaultForkTest is Test {
    // --- Ethereum mainnet addresses ---
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Aave V3
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AAVE_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;

    // Compound V3
    address constant COMPOUND_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address constant COMET_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
    address constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

    // Spark
    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant SPARK_REWARDS = 0x4370D3b6C9588E02ce9D22e684387859c7Ff5b34;

    // Fluid
    address constant FLUID_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;

    // Morpho Blue
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 constant MORPHO_CBBTC_USDC = 0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64;
    bytes32 constant MORPHO_PAXG_USDC = 0x8eaf7b29f02ba8d8c1d7aeb587403dcb16e2e943e4e2f5f94b0963c2386406c9;
    bytes32 constant MORPHO_WBTC_USDC = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;

    // MetaMorpho USDC vaults
    address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    address constant GAUNTLET_USDC_FRONTIER = 0xc582F04d8a82795aa2Ff9c8bb4c1c889fe7b754e;

    // --- Config ---
    uint256 constant PERFORMANCE_FEE_BPS = 1_500;
    uint256 constant IDLE_BUFFER_BPS = 300;
    uint256 constant DEPOSIT_AMOUNT = 50_000e6; // 50k USDC per vault
    uint256 constant USER_BALANCE = 500_000e6;

    // --- Deployed state ---
    TezoroV1_2 vaultA;
    TezoroV1_2 vaultB;
    TezoroV1_2 vaultC;
    RewardsModuleV1_2 rewardsA;
    RewardsModuleV1_2 rewardsB;
    RewardsModuleV1_2 rewardsC;

    address admin;
    address keeper;
    address feeRecipient;
    address alice;
    address bob;

    function setUp() public {
        vm.createSelectFork("ethereum");

        admin = makeAddr("admin");
        keeper = makeAddr("keeper");
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        deal(address(USDC), alice, USER_BALANCE);
        deal(address(USDC), bob, USER_BALANCE);

        vm.startPrank(admin);
        _deployVaultA();
        _deployVaultB();
        _deployVaultC();
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Deployment helpers
    // -----------------------------------------------------------------------

    function _deployVaultA() internal {
        vaultA = new TezoroV1_2(USDC, "Tezoro USDC-A", "tUSDC-A", admin, feeRecipient, PERFORMANCE_FEE_BPS, IDLE_BUFFER_BPS);

        AaveV3StrategyV1_2 aave = new AaveV3StrategyV1_2(address(USDC), AAVE_POOL, AAVE_A_USDC, address(vaultA), AAVE_REWARDS);
        CompoundV3StrategyV1_2 compound = new CompoundV3StrategyV1_2(address(USDC), COMPOUND_USDC, address(vaultA), COMET_REWARDS, COMP);

        address sparkAToken = _getAToken(SPARK_POOL, address(USDC));
        AaveV3StrategyV1_2 spark = new AaveV3StrategyV1_2(address(USDC), SPARK_POOL, sparkAToken, address(vaultA), SPARK_REWARDS);

        vaultA.addStrategy(IStrategy(address(aave)));
        vaultA.addStrategy(IStrategy(address(compound)));
        vaultA.addStrategy(IStrategy(address(spark)));

        rewardsA = new RewardsModuleV1_2(address(vaultA), admin);
        vaultA.setRewardsModule(address(rewardsA));
        vaultA.setKeeper(keeper);
    }

    function _deployVaultB() internal {
        vaultB = new TezoroV1_2(USDC, "Tezoro USDC-B", "tUSDC-B", admin, feeRecipient, PERFORMANCE_FEE_BPS, IDLE_BUFFER_BPS);

        AaveV3StrategyV1_2 aave = new AaveV3StrategyV1_2(address(USDC), AAVE_POOL, AAVE_A_USDC, address(vaultB), AAVE_REWARDS);
        CompoundV3StrategyV1_2 compound = new CompoundV3StrategyV1_2(address(USDC), COMPOUND_USDC, address(vaultB), COMET_REWARDS, COMP);
        FluidStrategyV1_2 fluid = new FluidStrategyV1_2(address(USDC), FLUID_USDC, address(vaultB));

        ERC4626MultiStrategyV1_2 erc4626Multi = new ERC4626MultiStrategyV1_2(address(USDC), address(vaultB), admin, "MetaMorpho Multi", 64, new address[](0));
        erc4626Multi.addSubVault(STEAKHOUSE_USDC);
        erc4626Multi.addSubVault(GAUNTLET_USDC_PRIME);
        erc4626Multi.addSubVault(GAUNTLET_USDC_FRONTIER);
        erc4626Multi.setKeeper(admin);

        MarketParams memory mpCbBTC = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_CBBTC_USDC));
        MarketParams memory mpPAXG = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_PAXG_USDC));
        MarketParams memory mpWBTC = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_WBTC_USDC));
        MorphoBlueMultiStrategyV1_2 morphoMulti = new MorphoBlueMultiStrategyV1_2(address(USDC), MORPHO, address(vaultB), admin, "Morpho Multi", 64, new MarketParams[](0));
        morphoMulti.addMarket(mpCbBTC);
        morphoMulti.addMarket(mpPAXG);
        morphoMulti.addMarket(mpWBTC);
        morphoMulti.setKeeper(admin);

        vaultB.addStrategy(IStrategy(address(aave)));
        vaultB.addStrategy(IStrategy(address(compound)));
        vaultB.addStrategy(IStrategy(address(fluid)));
        vaultB.addStrategy(IStrategy(address(erc4626Multi)));
        vaultB.addStrategy(IStrategy(address(morphoMulti)));

        rewardsB = new RewardsModuleV1_2(address(vaultB), admin);
        vaultB.setRewardsModule(address(rewardsB));
        vaultB.setKeeper(keeper);
    }

    function _deployVaultC() internal {
        vaultC = new TezoroV1_2(USDC, "Tezoro USDC", "tUSDC", admin, feeRecipient, PERFORMANCE_FEE_BPS, IDLE_BUFFER_BPS);

        AaveV3StrategyV1_2 aave = new AaveV3StrategyV1_2(address(USDC), AAVE_POOL, AAVE_A_USDC, address(vaultC), AAVE_REWARDS);
        CompoundV3StrategyV1_2 compound = new CompoundV3StrategyV1_2(address(USDC), COMPOUND_USDC, address(vaultC), COMET_REWARDS, COMP);

        address sparkAToken = _getAToken(SPARK_POOL, address(USDC));
        AaveV3StrategyV1_2 spark = new AaveV3StrategyV1_2(address(USDC), SPARK_POOL, sparkAToken, address(vaultC), SPARK_REWARDS);
        FluidStrategyV1_2 fluid = new FluidStrategyV1_2(address(USDC), FLUID_USDC, address(vaultC));

        // MetaMorpho multi with same 3 sub-vaults as B (enough for integration test)
        ERC4626MultiStrategyV1_2 erc4626Multi = new ERC4626MultiStrategyV1_2(address(USDC), address(vaultC), admin, "MetaMorpho Multi", 64, new address[](0));
        erc4626Multi.addSubVault(STEAKHOUSE_USDC);
        erc4626Multi.addSubVault(GAUNTLET_USDC_PRIME);
        erc4626Multi.addSubVault(GAUNTLET_USDC_FRONTIER);
        erc4626Multi.setKeeper(admin);

        // Morpho multi with same 3 markets as B (enough for integration test)
        MarketParams memory mpCbBTC = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_CBBTC_USDC));
        MarketParams memory mpPAXG = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_PAXG_USDC));
        MarketParams memory mpWBTC = IMorpho(MORPHO).idToMarketParams(Id.wrap(MORPHO_WBTC_USDC));
        MorphoBlueMultiStrategyV1_2 morphoMulti = new MorphoBlueMultiStrategyV1_2(address(USDC), MORPHO, address(vaultC), admin, "Morpho Multi", 64, new MarketParams[](0));
        morphoMulti.addMarket(mpCbBTC);
        morphoMulti.addMarket(mpPAXG);
        morphoMulti.addMarket(mpWBTC);
        morphoMulti.setKeeper(admin);

        vaultC.addStrategy(IStrategy(address(aave)));
        vaultC.addStrategy(IStrategy(address(compound)));
        vaultC.addStrategy(IStrategy(address(spark)));
        vaultC.addStrategy(IStrategy(address(fluid)));
        vaultC.addStrategy(IStrategy(address(erc4626Multi)));
        vaultC.addStrategy(IStrategy(address(morphoMulti)));

        rewardsC = new RewardsModuleV1_2(address(vaultC), admin);
        vaultC.setRewardsModule(address(rewardsC));
        vaultC.setKeeper(keeper);
    }

    function _getAToken(address pool, address asset_) internal view returns (address aToken) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("getReserveData(address)", asset_));
        require(success, "getReserveData failed");
        assembly {
            aToken := mload(add(data, 288))
        }
    }

    // -----------------------------------------------------------------------
    // Deployment verification
    // -----------------------------------------------------------------------

    function test_all_vaults_deployed() public view {
        assertTrue(address(vaultA) != address(0), "Vault A deployed");
        assertTrue(address(vaultB) != address(0), "Vault B deployed");
        assertTrue(address(vaultC) != address(0), "Vault C deployed");
        assertTrue(address(vaultA) != address(vaultB), "A != B");
        assertTrue(address(vaultB) != address(vaultC), "B != C");
    }

    function test_vault_names() public view {
        assertEq(vaultA.name(), "Tezoro USDC-A");
        assertEq(vaultA.symbol(), "tUSDC-A");
        assertEq(vaultB.name(), "Tezoro USDC-B");
        assertEq(vaultB.symbol(), "tUSDC-B");
        assertEq(vaultC.name(), "Tezoro USDC");
        assertEq(vaultC.symbol(), "tUSDC");
    }

    function test_strategy_counts() public view {
        assertEq(vaultA.getStrategies().length, 3, "A: 3 strategies");
        assertEq(vaultB.getStrategies().length, 5, "B: 5 strategies");
        assertEq(vaultC.getStrategies().length, 6, "C: 6 strategies");
    }

    function test_all_strategies_healthy() public view {
        _assertAllHealthy(vaultA, "A");
        _assertAllHealthy(vaultB, "B");
        _assertAllHealthy(vaultC, "C");
    }

    function test_fee_config_identical() public view {
        assertEq(vaultA.performanceFeeBps(), PERFORMANCE_FEE_BPS);
        assertEq(vaultB.performanceFeeBps(), PERFORMANCE_FEE_BPS);
        assertEq(vaultC.performanceFeeBps(), PERFORMANCE_FEE_BPS);
        assertEq(vaultA.idleBufferBps(), IDLE_BUFFER_BPS);
        assertEq(vaultB.idleBufferBps(), IDLE_BUFFER_BPS);
        assertEq(vaultC.idleBufferBps(), IDLE_BUFFER_BPS);
    }

    function test_roles_set() public view {
        assertEq(vaultA.keeper(), keeper);
        assertEq(vaultB.keeper(), keeper);
        assertEq(vaultC.keeper(), keeper);
        assertEq(vaultA.admin(), admin);
        assertEq(vaultB.admin(), admin);
        assertEq(vaultC.admin(), admin);
    }

    function test_rewards_modules_set() public view {
        assertEq(vaultA.rewardsModule(), address(rewardsA));
        assertEq(vaultB.rewardsModule(), address(rewardsB));
        assertEq(vaultC.rewardsModule(), address(rewardsC));
    }

    // -----------------------------------------------------------------------
    // Independent deposits
    // -----------------------------------------------------------------------

    function test_deposit_to_all_vaults() public {
        // Alice deposits to A
        vm.startPrank(alice);
        USDC.approve(address(vaultA), DEPOSIT_AMOUNT);
        uint256 sharesA = vaultA.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Bob deposits to B
        vm.startPrank(bob);
        USDC.approve(address(vaultB), DEPOSIT_AMOUNT);
        uint256 sharesB = vaultB.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Alice also deposits to C
        vm.startPrank(alice);
        USDC.approve(address(vaultC), DEPOSIT_AMOUNT);
        uint256 sharesC = vaultC.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(sharesA, 0, "Alice got shares in A");
        assertGt(sharesB, 0, "Bob got shares in B");
        assertGt(sharesC, 0, "Alice got shares in C");

        // Verify cross-vault isolation
        assertEq(vaultA.balanceOf(bob), 0, "Bob has 0 shares in A");
        assertEq(vaultB.balanceOf(alice), 0, "Alice has 0 shares in B");
        assertEq(vaultC.balanceOf(bob), 0, "Bob has 0 shares in C");
    }

    function test_same_user_deposits_to_all_vaults() public {
        vm.startPrank(alice);
        USDC.approve(address(vaultA), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultB), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultC), DEPOSIT_AMOUNT);
        vaultA.deposit(DEPOSIT_AMOUNT, alice);
        vaultB.deposit(DEPOSIT_AMOUNT, alice);
        vaultC.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertGt(vaultA.balanceOf(alice), 0, "Alice has A shares");
        assertGt(vaultB.balanceOf(alice), 0, "Alice has B shares");
        assertGt(vaultC.balanceOf(alice), 0, "Alice has C shares");
    }

    // -----------------------------------------------------------------------
    // Independent rebalance
    // -----------------------------------------------------------------------

    function test_rebalance_all_vaults() public {
        _depositToAll(alice);

        uint256 idleA = vaultA.idleBalance();
        uint256 idleB = vaultB.idleBalance();
        uint256 idleC = vaultC.idleBalance();

        vm.startPrank(keeper);
        _rebalanceWithEqualAlloc(vaultA);
        _rebalanceWithEqualAlloc(vaultB);
        _rebalanceWithEqualAlloc(vaultC);
        vm.stopPrank();

        assertLt(vaultA.idleBalance(), idleA, "A: idle decreased");
        assertLt(vaultB.idleBalance(), idleB, "B: idle decreased");
        assertLt(vaultC.idleBalance(), idleC, "C: idle decreased");
    }

    // -----------------------------------------------------------------------
    // Independent reconcile
    // -----------------------------------------------------------------------

    function test_reconcile_all_vaults() public {
        _depositToAll(alice);

        vm.startPrank(keeper);
        _rebalanceWithEqualAlloc(vaultA);
        _rebalanceWithEqualAlloc(vaultB);
        _rebalanceWithEqualAlloc(vaultC);
        vm.stopPrank();

        uint256 totalA = vaultA.totalAssets();
        uint256 totalB = vaultB.totalAssets();
        uint256 totalC = vaultC.totalAssets();

        vm.startPrank(keeper);
        vaultA.reconcile();
        vaultB.reconcile();
        vaultC.reconcile();
        vm.stopPrank();

        // After reconcile, totals should be similar (maybe slightly different due to yield/rounding)
        assertGe(vaultA.totalAssets(), (totalA * 99) / 100, "A: totalAssets stable");
        assertGe(vaultB.totalAssets(), (totalB * 99) / 100, "B: totalAssets stable");
        assertGe(vaultC.totalAssets(), (totalC * 99) / 100, "C: totalAssets stable");
    }

    // -----------------------------------------------------------------------
    // Independent withdrawals
    // -----------------------------------------------------------------------

    function test_withdraw_from_all_vaults() public {
        _depositToAll(alice);

        vm.startPrank(keeper);
        _rebalanceWithEqualAlloc(vaultA);
        _rebalanceWithEqualAlloc(vaultB);
        _rebalanceWithEqualAlloc(vaultC);
        vm.stopPrank();

        vm.startPrank(alice);
        // Use maxRedeem to handle rounding after strategy deployment
        uint256 assetsA = vaultA.redeem(vaultA.maxRedeem(alice), alice, alice);
        uint256 assetsB = vaultB.redeem(vaultB.maxRedeem(alice), alice, alice);
        uint256 assetsC = vaultC.redeem(vaultC.maxRedeem(alice), alice, alice);
        vm.stopPrank();

        assertGt(assetsA, 0, "Redeemed from A");
        assertGt(assetsB, 0, "Redeemed from B");
        assertGt(assetsC, 0, "Redeemed from C");
    }

    // -----------------------------------------------------------------------
    // Cross-vault isolation under pause
    // -----------------------------------------------------------------------

    function test_pause_one_vault_others_work() public {
        _depositToAll(alice);

        // Pause vault B
        vm.prank(admin);
        vaultB.pauseVault();

        // A and C still accept deposits
        vm.startPrank(bob);
        USDC.approve(address(vaultA), DEPOSIT_AMOUNT);
        uint256 sharesA = vaultA.deposit(DEPOSIT_AMOUNT, bob);
        assertGt(sharesA, 0, "A accepts deposit while B paused");

        USDC.approve(address(vaultC), DEPOSIT_AMOUNT);
        uint256 sharesC = vaultC.deposit(DEPOSIT_AMOUNT, bob);
        assertGt(sharesC, 0, "C accepts deposit while B paused");

        // B reverts
        USDC.approve(address(vaultB), DEPOSIT_AMOUNT);
        vm.expectRevert();
        vaultB.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Cleanup
        vm.prank(admin);
        vaultB.unpauseVault();
    }

    // -----------------------------------------------------------------------
    // Full lifecycle across all vaults
    // -----------------------------------------------------------------------

    function test_full_lifecycle_all_vaults() public {
        // 1. Deposit to all
        _depositToAll(alice);

        vm.startPrank(bob);
        USDC.approve(address(vaultA), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultB), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultC), DEPOSIT_AMOUNT);
        vaultA.deposit(DEPOSIT_AMOUNT, bob);
        vaultB.deposit(DEPOSIT_AMOUNT, bob);
        vaultC.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // 2. Rebalance all
        vm.startPrank(keeper);
        _rebalanceWithEqualAlloc(vaultA);
        _rebalanceWithEqualAlloc(vaultB);
        _rebalanceWithEqualAlloc(vaultC);
        vm.stopPrank();

        // 3. Time warp for yield
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile all
        vm.startPrank(keeper);
        vaultA.reconcile();
        vaultB.reconcile();
        vaultC.reconcile();
        vm.stopPrank();

        // 5. Collect fees all
        vm.startPrank(keeper);
        vaultA.collectFees();
        vaultB.collectFees();
        vaultC.collectFees();
        vm.stopPrank();

        // 6. Harvest all
        vm.startPrank(keeper);
        vaultA.harvestAll();
        vaultB.harvestAll();
        vaultC.harvestAll();
        vm.stopPrank();

        // 7. Alice redeems everything
        vm.startPrank(alice);
        uint256 redeemedA = vaultA.redeem(vaultA.maxRedeem(alice), alice, alice);
        uint256 redeemedB = vaultB.redeem(vaultB.maxRedeem(alice), alice, alice);
        uint256 redeemedC = vaultC.redeem(vaultC.maxRedeem(alice), alice, alice);
        vm.stopPrank();

        // Should get back at least the deposit (yield accrued)
        assertGe(redeemedA, DEPOSIT_AMOUNT, "A: alice got back at least deposited");
        assertGe(redeemedB, DEPOSIT_AMOUNT, "B: alice got back at least deposited");
        assertGe(redeemedC, DEPOSIT_AMOUNT, "C: alice got back at least deposited");

        // 8. Bob still has shares, can redeem
        vm.startPrank(bob);
        uint256 bobA = vaultA.redeem(vaultA.maxRedeem(bob), bob, bob);
        uint256 bobB = vaultB.redeem(vaultB.maxRedeem(bob), bob, bob);
        uint256 bobC = vaultC.redeem(vaultC.maxRedeem(bob), bob, bob);
        vm.stopPrank();

        assertGe(bobA, DEPOSIT_AMOUNT, "A: bob got back at least deposited");
        assertGe(bobB, DEPOSIT_AMOUNT, "B: bob got back at least deposited");
        assertGe(bobC, DEPOSIT_AMOUNT, "C: bob got back at least deposited");

        // All vaults should have 0 user shares
        assertEq(vaultA.balanceOf(alice), 0);
        assertEq(vaultA.balanceOf(bob), 0);
        assertEq(vaultB.balanceOf(alice), 0);
        assertEq(vaultB.balanceOf(bob), 0);
        assertEq(vaultC.balanceOf(alice), 0);
        assertEq(vaultC.balanceOf(bob), 0);
    }

    // -----------------------------------------------------------------------
    // Keeper operates sequentially on all vaults (simulates keeper loop)
    // -----------------------------------------------------------------------

    function test_keeper_sequential_operations() public {
        _depositToAll(alice);

        // Keeper runs pipeline for all 3 vaults sequentially (like the keeper loop)
        vm.startPrank(keeper);

        // Pipeline: vault A
        vaultA.reconcile();
        _rebalanceWithEqualAlloc(vaultA);

        // Pipeline: vault B
        vaultB.reconcile();
        _rebalanceWithEqualAlloc(vaultB);

        // Pipeline: vault C
        vaultC.reconcile();
        _rebalanceWithEqualAlloc(vaultC);

        vm.stopPrank();

        // All vaults should have funds deployed
        assertLt(vaultA.idleBalance(), DEPOSIT_AMOUNT, "A: funds deployed");
        assertLt(vaultB.idleBalance(), DEPOSIT_AMOUNT, "B: funds deployed");
        assertLt(vaultC.idleBalance(), DEPOSIT_AMOUNT, "C: funds deployed");

        // Total assets should be close to deposit amount
        assertGe(vaultA.totalAssets(), (DEPOSIT_AMOUNT * 99) / 100, "A: totalAssets ~= deposit");
        assertGe(vaultB.totalAssets(), (DEPOSIT_AMOUNT * 99) / 100, "B: totalAssets ~= deposit");
        assertGe(vaultC.totalAssets(), (DEPOSIT_AMOUNT * 99) / 100, "C: totalAssets ~= deposit");
    }

    // -----------------------------------------------------------------------
    // Force redeem isolation
    // -----------------------------------------------------------------------

    function test_force_redeem_one_vault_no_effect_on_others() public {
        _depositToAll(alice);

        uint256 sharesB = vaultB.balanceOf(alice);
        uint256 sharesC = vaultC.balanceOf(alice);

        // Force redeem alice from vault A only
        vm.prank(admin);
        vaultA.forceRedeem(alice);

        assertEq(vaultA.balanceOf(alice), 0, "A: force redeemed");
        assertEq(vaultB.balanceOf(alice), sharesB, "B: untouched");
        assertEq(vaultC.balanceOf(alice), sharesC, "C: untouched");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _depositToAll(address user) internal {
        vm.startPrank(user);
        USDC.approve(address(vaultA), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultB), DEPOSIT_AMOUNT);
        USDC.approve(address(vaultC), DEPOSIT_AMOUNT);
        vaultA.deposit(DEPOSIT_AMOUNT, user);
        vaultB.deposit(DEPOSIT_AMOUNT, user);
        vaultC.deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    /// @dev Set equal allocation across all strategies (excluding idle buffer)
    function _rebalanceWithEqualAlloc(TezoroV1_2 vault) internal {
        IStrategy[] memory strats = vault.getStrategies();
        uint256 perStrategy = (10_000 - IDLE_BUFFER_BPS) / strats.length;
        uint256[] memory bps = new uint256[](strats.length);
        for (uint256 i = 0; i < strats.length; i++) {
            bps[i] = perStrategy;
        }
        vault.rebalance(strats, bps);
    }

    function _assertAllHealthy(TezoroV1_2 vault, string memory label) internal view {
        IStrategy[] memory strats = vault.getStrategies();
        for (uint256 i = 0; i < strats.length; i++) {
            assertTrue(strats[i].isHealthy(), string.concat(label, ": strategy ", vm.toString(i), " healthy"));
        }
    }
}
