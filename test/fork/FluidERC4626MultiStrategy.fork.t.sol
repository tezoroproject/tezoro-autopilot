// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategy} from "../../src/strategies/ERC4626MultiStrategy.sol";

// Ethereum mainnet assets
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

// Fluid Lending fTokens (official ERC-4626 supply vaults)
address constant FLUID_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
address constant FLUID_USDT = 0x5C20B550819128074FD538Edf79791733ccEdd18;
address constant FLUID_WETH = 0x90551c1795392094FE6D29B758EcCD233cFAa260;

/// @notice Fork test for Fluid Lending fTokens through ERC4626MultiStrategy on Ethereum mainnet.
///         Fluid is a single-market-per-asset fit here, so the suite focuses on
///         same-asset ERC-4626 compatibility, live maxWithdraw semantics, and
///         asset-specific quirks like USDT approvals and WETH 18-decimal accounting.
contract FluidERC4626MultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    struct AssetConfig {
        address asset;
        address fToken;
        uint8 decimals;
        uint256 probeAmount;
        uint256 depositAmount;
        uint256 idleReserve;
        uint256 tolerance;
    }

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");
    address randomUser = makeAddr("random");

    function setUp() public {
        vm.createSelectFork("ethereum");
    }

    function test_liveFluidFTokens_areCompatibleERC4626Vaults() public view {
        _assertCompatible(_usdcConfig());
        _assertCompatible(_usdtConfig());
        _assertCompatible(_wethConfig());
    }

    function test_constructor_acceptsLiveInitialFluidFTokens() public {
        _assertSeededConstructor(_usdcConfig(), "Fluid USDC Seeded");
        _assertSeededConstructor(_usdtConfig(), "Fluid USDT Seeded");
        _assertSeededConstructor(_wethConfig(), "Fluid WETH Seeded");
    }

    function test_usdc_singleMarketLifecycle_matchesDirectAccountingAndLiveLiquidity() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC", true);

        uint256 allocationAmount = cfg.depositAmount - cfg.idleReserve;
        _depositIntoStrategy(strategy, cfg, cfg.depositAmount);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, allocationAmount);

        assertEq(IERC20(cfg.asset).balanceOf(address(strategy)), cfg.idleReserve);
        assertEq(strategy.subVaultBalance(cfg.fToken), _directVaultAssets(strategy, cfg.fToken));
        _assertApproxAssets(strategy.subVaultBalance(cfg.fToken), allocationAmount, cfg.tolerance);
        _assertApproxAssets(strategy.balanceOf(), cfg.depositAmount, cfg.tolerance);

        uint256 expectedLiquidity =
            IERC20(cfg.asset).balanceOf(address(strategy)) + IERC4626(cfg.fToken).maxWithdraw(address(strategy));
        assertEq(strategy.availableLiquidity(), expectedLiquidity);
        assertLe(strategy.availableLiquidity(), strategy.balanceOf());

        uint256 sharesBefore = IERC4626(cfg.fToken).balanceOf(address(strategy));
        vm.prank(vaultAddr);
        uint256 idleWithdrawn = strategy.withdraw(cfg.idleReserve);

        assertEq(idleWithdrawn, cfg.idleReserve);
        assertEq(IERC4626(cfg.fToken).balanceOf(address(strategy)), sharesBefore);

        uint256 assetsBefore = strategy.balanceOf();
        uint256 requested = allocationAmount / 2;

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(requested);

        _assertApproxAssets(withdrawn, requested, cfg.tolerance);
        _assertApproxAssets(strategy.balanceOf(), assetsBefore - withdrawn, cfg.tolerance);
    }

    function test_usdt_nonStandardApprove_partialDeallocateAndEmergencyWithdraw() public {
        AssetConfig memory cfg = _usdtConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDT", false);

        assertEq(IERC20(cfg.asset).allowance(vaultAddr, address(strategy)), type(uint256).max);
        assertEq(IERC20(cfg.asset).allowance(address(strategy), cfg.fToken), type(uint256).max);

        uint256 allocationAmount = cfg.depositAmount - cfg.idleReserve;
        _depositIntoStrategy(strategy, cfg, cfg.depositAmount);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, allocationAmount);

        uint256 amountToDeallocate = allocationAmount / 3;
        vm.prank(keeperAddr);
        strategy.deallocate(cfg.fToken, amountToDeallocate);

        _assertApproxAssets(
            IERC20(cfg.asset).balanceOf(address(strategy)), cfg.idleReserve + amountToDeallocate, cfg.tolerance
        );

        uint256 remainingBeforeEmergency = strategy.balanceOf();
        uint256 vaultBalanceBefore = IERC20(cfg.asset).balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        _assertApproxAssets(withdrawn, remainingBeforeEmergency, cfg.tolerance);
        assertEq(IERC20(cfg.asset).balanceOf(vaultAddr) - vaultBalanceBefore, withdrawn);
        assertEq(IERC20(cfg.asset).balanceOf(address(strategy)), 0);
        assertEq(IERC4626(cfg.fToken).balanceOf(address(strategy)), 0);
    }

    function test_weth_18Decimals_supportsCappedWithdrawAndHealthyState() public {
        AssetConfig memory cfg = _wethConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid WETH", false);

        assertTrue(strategy.isHealthy());

        uint256 allocationAmount = cfg.depositAmount - cfg.idleReserve;
        _depositIntoStrategy(strategy, cfg, cfg.depositAmount);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, allocationAmount);

        uint256 balanceBefore = strategy.balanceOf();
        assertGt(balanceBefore, 0);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        _assertApproxAssets(withdrawn, balanceBefore, cfg.tolerance);
        assertLe(strategy.balanceOf(), cfg.tolerance);
    }

    function test_allocate_revertsIfNotKeeper() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC ACL", false);

        _depositIntoStrategy(strategy, cfg, cfg.depositAmount / 2);

        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategy.NotKeeper.selector);
        strategy.allocate(cfg.fToken, cfg.depositAmount / 4);
    }

    function test_allocate_revertsIfInsufficientIdle() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Idle Check", false);

        uint256 idle = cfg.depositAmount / 2;
        _depositIntoStrategy(strategy, cfg, idle);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategy.InsufficientIdle.selector);
        strategy.allocate(cfg.fToken, idle + 1);
    }

    function test_removeSubVault_revertsWhilePositionActive() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Active Remove", false);

        _depositIntoStrategy(strategy, cfg, cfg.depositAmount / 2);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, cfg.depositAmount / 2);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategy.SubVaultHasActivePosition.selector);
        strategy.removeSubVault(cfg.fToken);
    }

    function test_freeze_thenUnfreeze_preventsThenAllowsAllocation_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Freeze", false);

        uint256 allocationAmount = cfg.depositAmount / 2;
        _depositIntoStrategy(strategy, cfg, allocationAmount);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(cfg.fToken);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategy.DepositsFrozen.selector);
        strategy.allocate(cfg.fToken, allocationAmount);

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(cfg.fToken);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, allocationAmount);

        _assertApproxAssets(strategy.subVaultBalance(cfg.fToken), allocationAmount, cfg.tolerance);
    }

    function test_recallFreezeUnfreezeAndRemoveFlow_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Recall", false);

        uint256 allocationAmount = cfg.depositAmount - cfg.idleReserve;
        _depositIntoStrategy(strategy, cfg, cfg.depositAmount);

        vm.prank(keeperAddr);
        strategy.allocate(cfg.fToken, allocationAmount);

        vm.prank(adminAddr);
        strategy.recallSubVault(cfg.fToken);

        assertTrue(strategy.depositFrozenSubVaults(cfg.fToken));
        _assertApproxAssets(IERC20(cfg.asset).balanceOf(address(strategy)), cfg.depositAmount, cfg.tolerance);
        assertEq(IERC4626(cfg.fToken).balanceOf(address(strategy)), 0);

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(cfg.fToken);
        assertFalse(strategy.depositFrozenSubVaults(cfg.fToken));

        vm.prank(adminAddr);
        strategy.removeSubVault(cfg.fToken);

        assertFalse(strategy.isApproved(cfg.fToken));
        assertEq(strategy.subVaultCount(), 0);
        assertEq(IERC20(cfg.asset).allowance(address(strategy), cfg.fToken), 0);
    }

    function test_transferAdmin_acceptAdmin_roundTrip_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Admin", true);
        address newAdmin = makeAddr("newAdmin");

        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);

        assertEq(strategy.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        strategy.acceptAdmin();

        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategy.NotAdmin.selector);
        strategy.setKeeper(randomUser);
    }

    function test_addSubVault_revertsOnCrossAssetFluidFToken() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Asset Check", false);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategy.AssetMismatch.selector);
        strategy.addSubVault(FLUID_WETH);
    }

    function test_sweepReward_revertsIfNotVault_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Sweep ACL", true);

        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategy.NotVault.selector);
        strategy.sweepReward(address(0x1), vaultAddr);
    }

    function test_sweepReward_revertsOnAsset_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Sweep Asset", true);

        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategy.CannotSweepAsset.selector);
        strategy.sweepReward(cfg.asset, vaultAddr);
    }

    function test_sweepReward_revertsOnApprovedSubVaultShare_onFluidUSDC() public {
        AssetConfig memory cfg = _usdcConfig();
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, "Fluid USDC Sweep Share", true);

        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategy.CannotSweepAsset.selector);
        strategy.sweepReward(cfg.fToken, vaultAddr);
    }

    function test_isHealthy_withLiveFluidFTokens() public {
        assertTrue(_deployStrategy(_usdcConfig(), "Fluid USDC Healthy", true).isHealthy());
        assertTrue(_deployStrategy(_usdtConfig(), "Fluid USDT Healthy", true).isHealthy());
        assertTrue(_deployStrategy(_wethConfig(), "Fluid WETH Healthy", true).isHealthy());
    }

    function _deployStrategy(
        AssetConfig memory cfg,
        string memory strategyName,
        bool seedInitial
    )
        internal
        returns (ERC4626MultiStrategy strategy)
    {
        address[] memory initialSubVaults = new address[](seedInitial ? 1 : 0);
        if (seedInitial) initialSubVaults[0] = cfg.fToken;

        strategy = new ERC4626MultiStrategy(cfg.asset, vaultAddr, adminAddr, strategyName, 16, initialSubVaults);

        vm.prank(adminAddr);
        strategy.setKeeper(keeperAddr);

        if (!seedInitial) {
            vm.prank(adminAddr);
            strategy.addSubVault(cfg.fToken);
        }

        vm.prank(vaultAddr);
        IERC20(cfg.asset).forceApprove(address(strategy), type(uint256).max);
    }

    function _depositIntoStrategy(ERC4626MultiStrategy strategy, AssetConfig memory cfg, uint256 amount) internal {
        deal(cfg.asset, vaultAddr, amount);
        vm.prank(vaultAddr);
        strategy.deposit(amount);
    }

    function _assertCompatible(AssetConfig memory cfg) internal view {
        assertEq(IERC4626(cfg.fToken).asset(), cfg.asset);
        assertEq(IERC4626(cfg.fToken).decimals(), cfg.decimals);
        assertGt(IERC4626(cfg.fToken).previewDeposit(cfg.probeAmount), 0);
        assertGt(IERC4626(cfg.fToken).maxDeposit(address(1)), 0);
        assertGt(IERC4626(cfg.fToken).totalAssets(), 0);
    }

    function _assertSeededConstructor(AssetConfig memory cfg, string memory strategyName) internal {
        ERC4626MultiStrategy strategy = _deployStrategy(cfg, strategyName, true);

        assertTrue(strategy.isApproved(cfg.fToken));
        assertEq(strategy.subVaultCount(), 1);
        assertEq(strategy.getSubVaults()[0], cfg.fToken);
        assertEq(IERC20(cfg.asset).allowance(address(strategy), cfg.fToken), type(uint256).max);
    }

    function _directVaultAssets(ERC4626MultiStrategy strategy, address subVault) internal view returns (uint256) {
        uint256 shares = IERC4626(subVault).balanceOf(address(strategy));
        if (shares == 0) return 0;
        return IERC4626(subVault).convertToAssets(shares);
    }

    function _usdcConfig() internal pure returns (AssetConfig memory cfg) {
        cfg = AssetConfig({
            asset: USDC,
            fToken: FLUID_USDC,
            decimals: 6,
            probeAmount: 1e6,
            depositAmount: 50_000e6,
            idleReserve: 5000e6,
            tolerance: 1e6
        });
    }

    function _usdtConfig() internal pure returns (AssetConfig memory cfg) {
        cfg = AssetConfig({
            asset: USDT,
            fToken: FLUID_USDT,
            decimals: 6,
            probeAmount: 1e6,
            depositAmount: 50_000e6,
            idleReserve: 5000e6,
            tolerance: 1e6
        });
    }

    function _wethConfig() internal pure returns (AssetConfig memory cfg) {
        cfg = AssetConfig({
            asset: WETH,
            fToken: FLUID_WETH,
            decimals: 18,
            probeAmount: 1e18,
            depositAmount: 12e18,
            idleReserve: 2e18,
            tolerance: 5e14
        });
    }

    function _assertApproxAssets(uint256 actual, uint256 expected, uint256 tolerance) internal pure {
        if (actual > expected) assertLe(actual - expected, tolerance);
        else assertLe(expected - actual, tolerance);
    }
}
