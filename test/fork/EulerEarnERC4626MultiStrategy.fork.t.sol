// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Official Euler Earn Ethereum factory from euler-interfaces/addresses/1/CoreAddresses.json.
// supportedPerspective() is governance-updatable, so the test only checks that it is non-zero live on-chain.
address constant EULER_EARN_FACTORY = 0x59709B029B140C853FE28d277f83C3a65e308aF4;

// Official Ethereum Euler Earn USDC vaults returned by the live factory on April 2, 2026.
address constant EE_USDC = 0x3B4802FDb0E5d74aA37d58FD77d63e93d4f9A4AF;
address constant HYPERITHM_EULER_USDC = 0x3cd3718f8f047aA32F775E2cb4245A164E1C99fB;
address constant SENTORA_EARN_USDC = 0x59E03c1Db4F35BFfbA06B0451e199b17eFBC4A86;
address constant TID_CAPITAL_USDC = 0x9B5aac9c6C70d5a583f44DDd13DF25AcC431fca4;
address constant KPK_RWA_EULER_USDC = 0x2B47c128b35DDDcB66Ce2FA5B33c95314a7de245;

interface IEulerEarnFactoryLike {
    function getVaultListLength() external view returns (uint256);
    function supportedPerspective() external view returns (address);
    function isVault(address target) external view returns (bool);
}

/// @notice Fork test for live Euler Earn vaults through ERC4626MultiStrategyV1_2 on Ethereum mainnet.
///         This validates compatibility with Euler Earn proper, not raw EVK credit vaults.
contract EulerEarnERC4626MultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategyV1_2 strategy;
    IEulerEarnFactoryLike factory = IEulerEarnFactoryLike(EULER_EARN_FACTORY);

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");
    address randomUser = makeAddr("random");

    uint256 constant DEFAULT_DEPOSIT_AMOUNT = 200_000e6;
    uint256 constant IDLE_RESERVE = 10_000e6;
    uint256 constant PER_VAULT_TARGET = 25_000e6;
    uint256 constant ISOLATED_ALLOCATION_TARGET = 10_000e6;
    uint256 constant ASSET_TOLERANCE = 5e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = _deployStrategy("Euler Earn USDC", new address[](0));

        vm.startPrank(adminAddr);
        _addSubVaults(strategy, _configuredVaults());
        vm.stopPrank();

        deal(USDC, vaultAddr, DEFAULT_DEPOSIT_AMOUNT * 3);
    }

    function test_officialFactoryAndConfiguredVaults_areCompatibleERC4626Vaults() public view {
        address[] memory vaults = _configuredVaults();
        address[] memory subVaults = strategy.getSubVaults();

        assertGt(factory.getVaultListLength(), 0);
        assertTrue(factory.supportedPerspective() != address(0));
        assertEq(subVaults.length, vaults.length);

        for (uint256 i = 0; i < vaults.length; i++) {
            assertTrue(factory.isVault(vaults[i]));
            assertEq(IERC4626(vaults[i]).asset(), USDC);
            assertEq(IERC4626(vaults[i]).decimals(), 6);
            assertEq(subVaults[i], vaults[i]);
            assertGt(IERC4626(vaults[i]).previewDeposit(1e6), 0);
        }
    }

    function test_allocate_acrossConfiguredVaults_preservesTotalAssets() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

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
                _deployStrategy(string.concat("Euler Earn Isolated ", vm.toString(i)), new address[](0));

            vm.prank(adminAddr);
            localStrategy.addSubVault(vaults[i]);

            uint256 maxDeposit = IERC4626(vaults[i]).maxDeposit(address(localStrategy));
            if (maxDeposit == 0) continue;

            uint256 allocationAmount = _min(maxDeposit, ISOLATED_ALLOCATION_TARGET);
            _depositIntoStrategy(localStrategy, allocationAmount);

            vm.prank(keeperAddr);
            localStrategy.allocate(vaults[i], allocationAmount);

            _assertApproxAssets(_directVaultAssets(localStrategy, vaults[i]), allocationAmount);

            vm.prank(keeperAddr);
            localStrategy.deallocate(vaults[i], allocationAmount);

            _assertApproxAssets(IERC20(USDC).balanceOf(address(localStrategy)), allocationAmount);
            assertEq(IERC4626(vaults[i]).balanceOf(address(localStrategy)), 0);
            tested++;
        }

        assertGt(tested, 0, "no Euler Earn vault accepted live deposits");
    }

    function test_balanceOf_matchesIdlePlusDirectVaultAccounting() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, vaults, amounts);

        uint256 expected = IERC20(USDC).balanceOf(address(strategy)) + _sumDirectVaultAssets(strategy, vaults);
        assertEq(strategy.balanceOf(), expected);
    }

    function test_availableLiquidity_matchesIdlePlusLiveMaxWithdraw() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

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

    function test_idleWithdraw_doesNotTouchAllocatedVaultShares() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 70_000e6);

        _depositIntoStrategy(allocationAmount + IDLE_RESERVE);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        uint256 sharesBefore = IERC4626(vault_).balanceOf(address(strategy));

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(IDLE_RESERVE);

        assertEq(withdrawn, IDLE_RESERVE);
        assertEq(IERC4626(vault_).balanceOf(address(strategy)), sharesBefore);
    }

    function test_withdraw_waterfallsAcrossConfiguredVaults() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, vaults, amounts);

        uint256 assetsBefore = strategy.balanceOf();
        uint256 requested = totalAllocation > 1 ? totalAllocation / 2 : totalAllocation;

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(requested);

        _assertApproxAssets(withdrawn, requested);
        _assertApproxAssets(strategy.balanceOf(), assetsBefore - withdrawn);
    }

    function test_withdraw_moreThanBalance_returnsCapped() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, vaults, amounts);

        uint256 balanceBefore = strategy.balanceOf();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        _assertApproxAssets(withdrawn, balanceBefore);
        _assertApproxAssets(strategy.balanceOf(), 0);
    }

    function test_emergencyWithdraw_collectsFromAllConfiguredVaults() public {
        (address[] memory vaults, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_VAULT_TARGET);
        assertGt(activeCount, 0, "no allocatable Euler Earn vaults");

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
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 25_000e6);

        _depositIntoStrategy(allocationAmount - 1);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.InsufficientIdle.selector);
        strategy.allocate(vault_, allocationAmount);
    }

    function test_freeze_thenUnfreeze_preventsThenAllowsAllocation() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 30_000e6);

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

    function test_removeSubVault_revertsWhilePositionActive() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 25_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(vault_, allocationAmount);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultHasActivePosition.selector);
        strategy.removeSubVault(vault_);
    }

    function test_recallSubVault_redeemsAndFreezesFirstAllocatableVault() public {
        (address vault_, uint256 allocationAmount) = _firstAllocatableVault(strategy, 80_000e6);

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

    function test_constructor_acceptsLiveInitialEulerEarnSubVaults() public {
        address[] memory initialSubVaults = _configuredVaults();
        ERC4626MultiStrategyV1_2 seededStrategy = _deployStrategy("Euler Earn Seeded", initialSubVaults);

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
        strategy.sweepReward(EE_USDC, vaultAddr);
    }

    function test_isHealthy_withLiveEulerEarnVaults() public view {
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

        revert("no allocatable Euler Earn vault");
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
        vaults = new address[](5);
        vaults[0] = EE_USDC;
        vaults[1] = HYPERITHM_EULER_USDC;
        vaults[2] = SENTORA_EARN_USDC;
        vaults[3] = TID_CAPITAL_USDC;
        vaults[4] = KPK_RWA_EULER_USDC;
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
