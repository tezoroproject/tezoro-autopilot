// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Aave V4 tokenization spokes from the executed Ethereum mainnet activation proposal:
// https://vote.onaave.com/proposal/?proposalId=462
address constant AAVE_V4_CORE_USDC = 0x531E90a2376902DE8915789Fcc1075e3B0c153E7;
address constant AAVE_V4_PLUS_USDC = 0xc94bdd83D2c7655C280655D60954e79E88D4F949;
address constant AAVE_V4_PRIME_USDC = 0x486415fb1F8b062c89ED548f871cf64304AACb31;
bytes4 constant AAVE_V4_ADD_CAP_EXCEEDED_SELECTOR = bytes4(keccak256("AddCapExceeded(uint256)"));

/// @notice Fork test for Aave V4 tokenization spokes through ERC4626MultiStrategyV1_2 on Ethereum mainnet.
contract AaveV4ERC4626MultiStrategyForkTest is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategyV1_2 strategy;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");
    address randomUser = makeAddr("random");

    uint256 constant DEFAULT_DEPOSIT_AMOUNT = 100_000e6;
    uint256 constant IDLE_RESERVE = 10_000e6;
    uint256 constant PER_SPOKE_TARGET = 20_000e6;
    uint256 constant ISOLATED_ALLOCATION_TARGET = 10_000e6;
    uint256 constant ASSET_TOLERANCE = 1e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = _deployStrategy("Aave V4 USDC", new address[](0));

        vm.startPrank(adminAddr);
        _addSubVaults(strategy, _configuredSpokes());
        vm.stopPrank();

        deal(USDC, vaultAddr, DEFAULT_DEPOSIT_AMOUNT * 3);
    }

    function test_tokenizationSpokes_areCompatibleERC4626Vaults() public view {
        address[] memory spokes = _configuredSpokes();
        address[] memory subVaults = strategy.getSubVaults();

        assertEq(subVaults.length, spokes.length);

        for (uint256 i = 0; i < spokes.length; i++) {
            assertEq(IERC4626(spokes[i]).asset(), USDC);
            assertEq(subVaults[i], spokes[i]);
            assertGt(IERC4626(spokes[i]).previewDeposit(1e6), 0);
        }
    }

    function test_allocate_acrossAllocatableSpokes_preservesTotalAssets() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, spokes, amounts);

        assertEq(IERC20(USDC).balanceOf(address(strategy)), IDLE_RESERVE);
        _assertApproxAssets(strategy.balanceOf(), depositAmount);

        for (uint256 i = 0; i < spokes.length; i++) {
            if (amounts[i] == 0) continue;
            _assertApproxAssets(strategy.subVaultBalance(spokes[i]), amounts[i]);
        }
    }

    function test_plusSpoke_rejectsReportedCapOverflow_whenBounded() public {
        uint256 maxDeposit = IERC4626(AAVE_V4_PLUS_USDC).maxDeposit(address(strategy));
        if (maxDeposit == type(uint256).max) return;

        uint256 amount = maxDeposit == 0 ? 1 : maxDeposit + 1;
        _depositIntoStrategy(amount);

        vm.prank(keeperAddr);
        (bool success, bytes memory revertData) =
            address(strategy).call(abi.encodeCall(ERC4626MultiStrategyV1_2.allocate, (AAVE_V4_PLUS_USDC, amount)));

        assertFalse(success);
        assertEq(_revertSelector(revertData), AAVE_V4_ADD_CAP_EXCEEDED_SELECTOR);
    }

    function test_deallocate_fromFirstAllocatableSpoke_returnsIdle() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 50_000e6);

        _depositIntoStrategy(allocationAmount + IDLE_RESERVE);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        uint256 amountToDeallocate = allocationAmount / 2;
        vm.prank(keeperAddr);
        strategy.deallocate(spoke, amountToDeallocate);

        _assertApproxAssets(IERC20(USDC).balanceOf(address(strategy)), IDLE_RESERVE + amountToDeallocate);
    }

    function test_eachConfiguredSpoke_supportsSmallAllocationAndFullExit_whenCapAvailable() public {
        address[] memory spokes = _configuredSpokes();
        uint256 tested;

        for (uint256 i = 0; i < spokes.length; i++) {
            ERC4626MultiStrategyV1_2 localStrategy =
                _deployStrategy(string.concat("Aave V4 Isolated ", vm.toString(i)), new address[](0));

            vm.prank(adminAddr);
            localStrategy.addSubVault(spokes[i]);

            uint256 maxDeposit = IERC4626(spokes[i]).maxDeposit(address(localStrategy));
            if (maxDeposit == 0) continue;

            uint256 allocationAmount = _min(maxDeposit, ISOLATED_ALLOCATION_TARGET);
            _depositIntoStrategy(localStrategy, allocationAmount);

            vm.prank(keeperAddr);
            localStrategy.allocate(spokes[i], allocationAmount);

            _assertApproxAssets(_directVaultAssets(localStrategy, spokes[i]), allocationAmount);

            vm.prank(keeperAddr);
            localStrategy.deallocate(spokes[i], allocationAmount);

            _assertApproxAssets(IERC20(USDC).balanceOf(address(localStrategy)), allocationAmount);
            assertEq(IERC4626(spokes[i]).balanceOf(address(localStrategy)), 0);
            tested++;
        }

        assertGt(tested, 0, "no spoke accepted live deposits");
    }

    function test_balanceOf_matchesIdlePlusDirectVaultAccounting() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, spokes, amounts);

        uint256 expected = IERC20(USDC).balanceOf(address(strategy)) + _sumDirectVaultAssets(strategy, spokes);
        assertEq(strategy.balanceOf(), expected);
    }

    function test_availableLiquidity_matchesIdlePlusLiveMaxWithdraw() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        uint256 depositAmount = totalAllocation + IDLE_RESERVE;
        _depositIntoStrategy(depositAmount);
        _allocatePlan(strategy, spokes, amounts);

        uint256 expected = IERC20(USDC).balanceOf(address(strategy));
        for (uint256 i = 0; i < spokes.length; i++) {
            expected += IERC4626(spokes[i]).maxWithdraw(address(strategy));
        }

        uint256 available = strategy.availableLiquidity();
        assertEq(available, expected);
        assertLe(available, strategy.balanceOf());
    }

    function test_subVaultBalance_matchesDirectVaultAccounting() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 45_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        assertEq(strategy.subVaultBalance(spoke), _directVaultAssets(strategy, spoke));
    }

    function test_idleWithdraw_doesNotTouchAllocatedSpokeShares() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 70_000e6);

        _depositIntoStrategy(allocationAmount + IDLE_RESERVE);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        uint256 sharesBefore = IERC4626(spoke).balanceOf(address(strategy));

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(IDLE_RESERVE);

        assertEq(withdrawn, IDLE_RESERVE);
        assertEq(IERC4626(spoke).balanceOf(address(strategy)), sharesBefore);
    }

    function test_withdraw_waterfallsAcrossAllocatableSpokes() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, spokes, amounts);

        uint256 assetsBefore = strategy.balanceOf();
        uint256 requested = totalAllocation > 1 ? totalAllocation / 2 : totalAllocation;

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(requested);

        _assertApproxAssets(withdrawn, requested);
        _assertApproxAssets(strategy.balanceOf(), assetsBefore - withdrawn);
    }

    function test_withdraw_moreThanBalance_returnsCapped() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, spokes, amounts);

        uint256 balanceBefore = strategy.balanceOf();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(type(uint256).max);

        _assertApproxAssets(withdrawn, balanceBefore);
        _assertApproxAssets(strategy.balanceOf(), 0);
    }

    function test_emergencyWithdraw_collectsFromAllAllocatableSpokes() public {
        (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, PER_SPOKE_TARGET);
        assertGt(activeCount, 0, "no allocatable Aave v4 spokes");

        _depositIntoStrategy(totalAllocation);
        _allocatePlan(strategy, spokes, amounts);

        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        _assertApproxAssets(withdrawn, totalAllocation);
        assertEq(IERC20(USDC).balanceOf(vaultAddr) - vaultBalanceBefore, withdrawn);
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0);

        for (uint256 i = 0; i < spokes.length; i++) {
            assertEq(IERC4626(spokes[i]).balanceOf(address(strategy)), 0);
        }
    }

    function test_allocate_revertsIfNotKeeper() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, ISOLATED_ALLOCATION_TARGET);

        _depositIntoStrategy(allocationAmount);

        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotKeeper.selector);
        strategy.allocate(spoke, allocationAmount);
    }

    function test_removeSubVault_revertsWhilePositionActive() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 25_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultHasActivePosition.selector);
        strategy.removeSubVault(spoke);
    }

    function test_recallSubVault_redeemsAndFreezesFirstAllocatableSpoke() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 80_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        vm.prank(adminAddr);
        strategy.recallSubVault(spoke);

        assertTrue(strategy.depositFrozenSubVaults(spoke));
        _assertApproxAssets(IERC20(USDC).balanceOf(address(strategy)), allocationAmount);
        assertEq(IERC4626(spoke).balanceOf(address(strategy)), 0);
    }

    function test_recallSubVault_isIdempotentOnceFrozen() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 30_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        vm.prank(adminAddr);
        strategy.recallSubVault(spoke);

        vm.prank(adminAddr);
        strategy.recallSubVault(spoke);

        assertTrue(strategy.depositFrozenSubVaults(spoke));
        assertEq(IERC4626(spoke).balanceOf(address(strategy)), 0);
    }

    function test_freeze_then_unfreeze_controlsLiveAllocation() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, ISOLATED_ALLOCATION_TARGET);

        _depositIntoStrategy(allocationAmount);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(spoke);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(spoke, allocationAmount);

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(spoke);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        _assertApproxAssets(strategy.subVaultBalance(spoke), allocationAmount);
    }

    function test_recall_thenRemoveSubVault_preventsFurtherAllocation() public {
        (address spoke, uint256 allocationAmount) = _firstAllocatableSpoke(strategy, 50_000e6);

        _depositIntoStrategy(allocationAmount);

        vm.prank(keeperAddr);
        strategy.allocate(spoke, allocationAmount);

        vm.startPrank(adminAddr);
        strategy.recallSubVault(spoke);
        strategy.removeSubVault(spoke);
        vm.stopPrank();

        assertFalse(strategy.isApproved(spoke));
        assertEq(IERC20(USDC).allowance(address(strategy), spoke), 0);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.allocate(spoke, 1);
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

    function test_constructor_acceptsLiveInitialAaveV4SubVaults() public {
        address[] memory initialSubVaults = _configuredSpokes();
        ERC4626MultiStrategyV1_2 seededStrategy = _deployStrategy("Aave V4 Seeded", initialSubVaults);

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
        strategy.sweepReward(AAVE_V4_CORE_USDC, vaultAddr);
    }

    function test_isHealthy_withLiveAaveV4Spokes() public view {
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
        uint256 preferredPerSpoke
    )
        internal
        view
        returns (address[] memory spokes, uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount)
    {
        spokes = _configuredSpokes();
        amounts = new uint256[](spokes.length);

        for (uint256 i = 0; i < spokes.length; i++) {
            uint256 maxDeposit = IERC4626(spokes[i]).maxDeposit(address(targetStrategy));
            if (maxDeposit == 0) continue;

            uint256 amount = _min(maxDeposit, preferredPerSpoke);
            if (amount == 0) continue;

            amounts[i] = amount;
            totalAllocation += amount;
            activeCount++;
        }
    }

    function _firstAllocatableSpoke(
        ERC4626MultiStrategyV1_2 targetStrategy,
        uint256 preferredAmount
    )
        internal
        view
        returns (address spoke, uint256 allocationAmount)
    {
        address[] memory spokes = _configuredSpokes();

        for (uint256 i = 0; i < spokes.length; i++) {
            uint256 maxDeposit = IERC4626(spokes[i]).maxDeposit(address(targetStrategy));
            if (maxDeposit == 0) continue;

            allocationAmount = _min(maxDeposit, preferredAmount);
            if (allocationAmount == 0) continue;

            return (spokes[i], allocationAmount);
        }

        revert("no allocatable Aave v4 spoke");
    }

    function _allocatePlan(
        ERC4626MultiStrategyV1_2 targetStrategy,
        address[] memory spokes,
        uint256[] memory amounts
    )
        internal
    {
        vm.startPrank(keeperAddr);
        for (uint256 i = 0; i < spokes.length; i++) {
            if (amounts[i] == 0) continue;
            targetStrategy.allocate(spokes[i], amounts[i]);
        }
        vm.stopPrank();
    }

    function _sumDirectVaultAssets(
        ERC4626MultiStrategyV1_2 targetStrategy,
        address[] memory spokes
    )
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < spokes.length; i++) {
            total += _directVaultAssets(targetStrategy, spokes[i]);
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

    function _configuredSpokes() internal pure returns (address[] memory spokes) {
        spokes = new address[](3);
        spokes[0] = AAVE_V4_CORE_USDC;
        spokes[1] = AAVE_V4_PLUS_USDC;
        spokes[2] = AAVE_V4_PRIME_USDC;
    }

    function _addSubVaults(ERC4626MultiStrategyV1_2 targetStrategy, address[] memory spokes) internal {
        for (uint256 i = 0; i < spokes.length; i++) {
            targetStrategy.addSubVault(spokes[i]);
        }
    }

    function _assertApproxAssets(uint256 actual, uint256 expected) internal pure {
        if (actual > expected) assertLe(actual - expected, ASSET_TOLERANCE);
        else assertLe(expected - actual, ASSET_TOLERANCE);
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
