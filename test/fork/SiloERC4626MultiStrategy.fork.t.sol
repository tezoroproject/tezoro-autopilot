// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Official SiloVaultsFactory ever deployed on Ethereum mainnet, listed in
// silo-core/docs/DeployedSiloVersions.md. The live USDC vaults below were
// discovered from CreateSiloVault events emitted by this factory.
address constant SILO_MAINNET_VAULTS_FACTORY = 0xB30Ee27f6e19A24Df12dba5Ab4124B6dCE9beeE5;

// Live Silo managed vaults on Ethereum mainnet as of April 3, 2026.
// Queried from the factory's CreateSiloVault event stream and validated via
// isSiloVault(asset == USDC, previewDeposit > 0, totalAssets > 0).
address constant SILO_GREENHOUSE_USDC = 0xfb1905A1f24Cd6B936c4690f234bd4F38d412452;
address constant SILO_OPTIMA_USDC = 0x5362D5086FDef73450145492a66F8EBF210c5B9C;
address constant SILO_VARLAMORE_FALCON_USDC = 0xa9b23B28621CFB32e0ebf50b572aFAC671fCc17B;

interface ISiloVaultsFactoryLike {
    function isSiloVault(address target) external view returns (bool);
}

/// @notice Fork test for live Silo managed vaults through ERC4626MultiStrategyV1_2 on Ethereum mainnet.
///         This validates the official SiloVault path, which behaves as a standard ERC-4626 vault
///         over multiple whitelisted ERC-4626 markets.
contract SiloERC4626MultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategyV1_2 strategy;
    ISiloVaultsFactoryLike factory = ISiloVaultsFactoryLike(SILO_MAINNET_VAULTS_FACTORY);

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");
    address randomUser = makeAddr("random");

    uint256 constant DEFAULT_DEPOSIT_AMOUNT = 20_000e6;
    uint256 constant IDLE_RESERVE = 1000e6;
    uint256 constant PER_VAULT_TARGET = 2000e6;
    uint256 constant ISOLATED_ALLOCATION_TARGET = 1000e6;
    uint256 constant ASSET_TOLERANCE = 3e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = _deployStrategy("Silo Managed USDC", new address[](0));

        vm.startPrank(adminAddr);
        _addSubVaults(strategy, _configuredVaults());
        vm.stopPrank();

        deal(USDC, vaultAddr, DEFAULT_DEPOSIT_AMOUNT * 3);
    }

    function test_officialFactoryAndConfiguredVaults_areCompatibleERC4626Vaults() public view {
        address[] memory vaults = _configuredVaults();
        address[] memory subVaults = strategy.getSubVaults();

        assertEq(subVaults.length, vaults.length);

        for (uint256 i = 0; i < vaults.length; i++) {
            assertTrue(factory.isSiloVault(vaults[i]));
            assertEq(IERC4626(vaults[i]).asset(), USDC);
            assertGt(IERC4626(vaults[i]).previewDeposit(1e6), 0);
            assertGt(IERC4626(vaults[i]).maxDeposit(address(strategy)), 0);
            assertGt(IERC4626(vaults[i]).totalAssets(), 0);
            assertEq(subVaults[i], vaults[i]);
        }
    }

    function test_allocate_acrossConfiguredVaults_preservesTotalAssets() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, vaults, amounts);

        assertEq(IERC20(USDC).balanceOf(address(strategy)), IDLE_RESERVE);
        _assertApproxAssets(strategy.balanceOf(), depositAmount);

        for (uint256 i = 0; i < vaults.length; i++) {
            if (amounts[i] == 0) continue;
            _assertApproxAssets(strategy.subVaultBalance(vaults[i]), amounts[i]);
        }
    }

    function test_eachConfiguredVault_supportsSmallAllocationAndFullExit_whenOpen() public {
        address[] memory vaults = _configuredVaults();
        uint256 tested;

        for (uint256 i = 0; i < vaults.length; i++) {
            ERC4626MultiStrategyV1_2 localStrategy =
                _deployStrategy(string.concat("Silo Isolated ", vm.toString(i)), new address[](0));

            vm.prank(adminAddr);
            localStrategy.addSubVault(vaults[i]);

            uint256 maxDeposit = IERC4626(vaults[i]).maxDeposit(address(localStrategy));
            if (maxDeposit == 0) continue;

            uint256 allocationAmount = _min(maxDeposit, ISOLATED_ALLOCATION_TARGET);
            _depositIntoStrategy(localStrategy, allocationAmount);

            vm.prank(keeperAddr);
            localStrategy.allocate(vaults[i], allocationAmount);

            _assertApproxAssets(_directVaultAssets(localStrategy, vaults[i]), allocationAmount);

            uint256 deallocationAmount = IERC4626(vaults[i]).maxWithdraw(address(localStrategy));
            assertGt(deallocationAmount, 0, "vault became non-withdrawable");

            vm.prank(keeperAddr);
            localStrategy.deallocate(vaults[i], deallocationAmount);

            _assertApproxAssets(IERC20(USDC).balanceOf(address(localStrategy)), deallocationAmount);
            _assertApproxAssets(_directVaultAssets(localStrategy, vaults[i]), 0);
            tested++;
        }

        assertGt(tested, 0, "no Silo vault accepted live deposits");
    }

    function test_balanceOf_matchesIdlePlusDirectVaultAccounting() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, vaults, amounts);

        uint256 expected = IERC20(USDC).balanceOf(address(strategy)) + _sumDirectVaultAssets(strategy, vaults);
        assertEq(strategy.balanceOf(), expected);
    }

    function test_availableLiquidity_matchesIdlePlusLiveMaxWithdraw() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, vaults, amounts);

        uint256 expected = IERC20(USDC).balanceOf(address(strategy));
        for (uint256 i = 0; i < vaults.length; i++) {
            expected += IERC4626(vaults[i]).maxWithdraw(address(strategy));
        }

        uint256 available = strategy.availableLiquidity();
        assertEq(available, expected);
        assertLe(available, strategy.balanceOf());
    }

    function test_subVaultBalance_matchesDirectVaultAccounting() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 1500e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        assertEq(strategy.subVaultBalance(vault_), _directVaultAssets(strategy, vault_));
    }

    function test_idleWithdraw_doesNotTouchAllocatedVaultShares() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 3000e6);

        _depositIntoStrategy(allocationAmount + IDLE_RESERVE);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        uint256 sharesBefore = IERC4626(vault_).balanceOf(address(strategy));

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(IDLE_RESERVE);

        assertEq(withdrawn, IDLE_RESERVE);
        assertEq(IERC4626(vault_).balanceOf(address(strategy)), sharesBefore);
    }

    function test_withdraw_waterfallsAcrossConfiguredVaults_upToLiveAvailableLiquidity() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, vaults, amounts);

        uint256 availableBefore = strategy.availableLiquidity();
        assertGt(availableBefore, 0, "no withdrawable liquidity");

        uint256 assetsBefore = strategy.balanceOf();
        uint256 requested = availableBefore > 1 ? availableBefore / 2 : availableBefore;

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(requested);

        _assertApproxAssets(withdrawn, requested);
        _assertApproxAssets(strategy.balanceOf(), assetsBefore - withdrawn);
    }

    function test_withdraw_moreThanBalance_returnsLiveAvailableLiquidity() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, vaults, amounts);

        uint256 balanceBefore = strategy.balanceOf();
        uint256 availableBefore = strategy.availableLiquidity();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        _assertApproxAssets(withdrawn, availableBefore);
        _assertApproxAssets(strategy.balanceOf(), balanceBefore - withdrawn);
    }

    function test_emergencyWithdraw_collectsFromAllConfiguredVaults() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Silo vaults");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, vaults, amounts);

        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        _assertApproxAssets(withdrawn, totalAllocation);
        assertEq(IERC20(USDC).balanceOf(vaultAddr) - vaultBalanceBefore, withdrawn);
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);

        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(IERC4626(vaults[i]).balanceOf(address(strategy)), 0);
        }
    }

    function test_allocate_revertsIfNotKeeper() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, ISOLATED_ALLOCATION_TARGET);

        _depositIntoStrategy(allocationAmount);

        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotKeeper.selector);
        strategy.allocate(vault_, allocationAmount);
    }

    function test_allocate_revertsIfInsufficientIdle() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 1500e6);

        _depositIntoStrategy(allocationAmount - 1);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.InsufficientIdle.selector);
        strategy.allocate(vault_, allocationAmount);
    }

    function test_removeSubVault_revertsWhilePositionActive() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 2500e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultHasActivePosition.selector);
        strategy.removeSubVault(vault_);
    }

    function test_freeze_thenUnfreeze_preventsThenAllowsAllocation() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 2000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(vault_);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(vault_, allocationAmount);

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(vault_);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        _assertApproxAssets(strategy.subVaultBalance(vault_), allocationAmount);
    }

    function test_recallSubVault_redeemsAndFreezesFirstAllocatableVault() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 3000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        vm.prank(adminAddr);
        strategy.recallSubVault(vault_);

        assertTrue(strategy.depositFrozenSubVaults(vault_));
        _assertApproxAssets(IERC20(USDC).balanceOf(address(strategy)), allocationAmount);
        assertEq(IERC4626(vault_).balanceOf(address(strategy)), 0);
    }

    function test_transferAdmin_acceptAdmin_roundTrip() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);

        assertEq(strategy.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        strategy.acceptAdmin();

        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.setKeeper(randomUser);
    }

    function test_constructor_acceptsLiveInitialSiloVaults() public {
        address[] memory initialSubVaults = _configuredVaults();
        ERC4626MultiStrategyV1_2 seededStrategy = _deployStrategy("Silo Seeded", initialSubVaults);

        for (uint256 i = 0; i < initialSubVaults.length; i++) {
            assertTrue(seededStrategy.isApproved(initialSubVaults[i]));
        }
        assertEq(seededStrategy.subVaultCount(), initialSubVaults.length);
    }

    function test_sweepReward_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotVault.selector);
        strategy.sweepReward(address(0x1), vaultAddr);
    }

    function test_sweepReward_revertsOnAsset() public {
        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.CannotSweepAsset.selector);
        strategy.sweepReward(USDC, vaultAddr);
    }

    function test_sweepReward_revertsOnApprovedSubVaultShare() public {
        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.CannotSweepAsset.selector);
        strategy.sweepReward(SILO_GREENHOUSE_USDC, vaultAddr);
    }

    function test_isHealthy_withLiveSiloVaults() public view {
        assertTrue(strategy.isHealthy());
    }

    function _deployStrategy(
        string memory strategyName,
        address[] memory initialSubVaults
    )
        internal
        returns (ERC4626MultiStrategyV1_2 targetStrategy)
    {
        targetStrategy = new ERC4626MultiStrategyV1_2(USDC, vaultAddr, adminAddr, strategyName, 64, initialSubVaults);

        vm.prank(adminAddr);
        targetStrategy.setKeeper(keeperAddr);

        vm.prank(vaultAddr);
        IERC20(USDC).forceApprove(address(targetStrategy), type(uint256).max);
    }

    function _depositIntoStrategy(uint256 amount) internal {
        _depositIntoStrategy(strategy, amount);
    }

    function _depositIntoStrategy(ERC4626MultiStrategyV1_2 targetStrategy, uint256 amount) internal {
        deal(USDC, vaultAddr, amount);
        vm.prank(vaultAddr);
        targetStrategy.deposit(amount);
    }

    function _plannedAllocations(
        ERC4626MultiStrategyV1_2 targetStrategy,
        uint256 preferredPerVault
    )
        internal
        view
        returns (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount)
    {
        vaults = _configuredVaults();
        amounts = new uint256[](vaults.length);

        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 maxDeposit = IERC4626(vaults[i]).maxDeposit(address(targetStrategy));
            if (maxDeposit == 0) continue;

            uint256 amount = _min(maxDeposit, preferredPerVault);
            if (amount == 0) continue;

            amounts[i] = amount;
            totalAllocation += amount;
            activeCount++;
        }
    }

    function _firstAllocatableVault(
        ERC4626MultiStrategyV1_2 targetStrategy,
        uint256 preferredAmount
    )
        internal
        view
        returns (address vault_, uint256 allocationAmount)
    {
        address[] memory vaults = _configuredVaults();

        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 maxDeposit = IERC4626(vaults[i]).maxDeposit(address(targetStrategy));
            if (maxDeposit == 0) continue;

            allocationAmount = _min(maxDeposit, preferredAmount);
            if (allocationAmount == 0) continue;

            return (vaults[i], allocationAmount);
        }

        revert("no allocatable Silo vault");
    }

    function _allocatePlan(
        ERC4626MultiStrategyV1_2 targetStrategy,
        address[] memory vaults,
        uint256[] memory amounts
    )
        internal
    {
        vm.startPrank(keeperAddr);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (amounts[i] == 0) continue;
            targetStrategy.allocate(vaults[i], amounts[i]);
        }
        vm.stopPrank();
    }

    function _sumDirectVaultAssets(
        ERC4626MultiStrategyV1_2 targetStrategy,
        address[] memory vaults
    )
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < vaults.length; i++) {
            total += _directVaultAssets(targetStrategy, vaults[i]);
        }
    }

    function _directVaultAssets(
        ERC4626MultiStrategyV1_2 targetStrategy,
        address subVault
    )
        internal
        view
        returns (uint256)
    {
        uint256 shares = IERC4626(subVault).balanceOf(address(targetStrategy));
        if (shares == 0) return 0;
        return IERC4626(subVault).convertToAssets(shares);
    }

    function _configuredVaults() internal pure returns (address[] memory vaults) {
        vaults = new address[](3);
        vaults[0] = SILO_GREENHOUSE_USDC;
        vaults[1] = SILO_OPTIMA_USDC;
        vaults[2] = SILO_VARLAMORE_FALCON_USDC;
    }

    function _addSubVaults(ERC4626MultiStrategyV1_2 targetStrategy, address[] memory vaults) internal {
        for (uint256 i = 0; i < vaults.length; i++) {
            targetStrategy.addSubVault(vaults[i]);
        }
    }

    function _assertApproxAssets(uint256 actual, uint256 expected) internal pure {
        if (actual > expected) assertLe(actual - expected, ASSET_TOLERANCE);
        else assertLe(expected - actual, ASSET_TOLERANCE);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
