// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RewardsModuleV1_2} from "../../../src/RewardsModuleV1_2.sol";
import {VaultForkTests} from "./VaultForkTests.sol";

/// @dev Minimal Uniswap V3 SwapRouter interface for fork swap tests
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Minimal Uniswap V2 Router interface for fork swap tests
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// Well-known DEX aggregator addresses (same on all supported chains)
address constant ONEINCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65;
address constant ODOS_V3 = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;
address constant PARASWAP_V6 = 0x6A000F20005980200259B80c5102003040001068;
address constant ZEROX_PROXY = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

/// @notice RewardsModuleV1_2 fork tests: deploy, claims executor, swap engine, admin, multi-router, aggregators.
///         Inherits VaultForkTests. Chain-specific test contracts inherit BaseChainForkTest which inherits this.
abstract contract RewardsModuleForkTests is VaultForkTests {
    using SafeERC20 for IERC20;

    // =========================================================================
    // RewardsModuleV1_2 Integration
    // =========================================================================

    function test_rewardsModule_deploy_and_configure() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        assertEq(rm.vault(), address(vault));
        assertEq(rm.baseAsset(), token);
        assertEq(rm.admin(), admin);
    }

    function test_rewardsModule_sweepToVault() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        vm.stopPrank();

        // Alice deposits so vault has shares
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        uint256 totalBefore = vault.totalAssets();

        // Simulate rewards arriving and being swapped
        uint256 rewardAmount = depositAmount / 100;
        deal(token, address(rm), rewardAmount);

        vm.prank(keeper);
        rm.sweepToVault();

        assertEq(IERC20(token).balanceOf(address(rm)), 0, "Module should be empty");
        assertEq(vault.totalAssets(), totalBefore + rewardAmount, "Vault totalAssets should increase");
    }

    function test_rewardsModule_rescueToken_notBaseAsset() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        deal(token, address(rm), 100);

        vm.prank(admin);
        vm.expectRevert(RewardsModuleV1_2.CannotRescueBaseAsset.selector);
        rm.rescueToken(token, admin, 100);
    }

    function test_rewardsModule_accessControl() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        deal(token, address(rm), 100);
        vm.prank(admin);
        vault.setRewardsModule(address(rm));

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        rm.sweepToVault();

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        rm.setClaimWhitelist(address(0x1), bytes4(0x12345678), true);

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        rm.setRouterWhitelist(address(0x1), true);
    }

    /// @notice Full rewards pipeline: deposit -> rebalance -> time -> harvest -> sweep -> verify
    function test_rewardsModule_fullPipeline() public {
        if (address(compoundStrategy) == address(0)) return;
        if (!_compRewardsActive()) return;

        // 1. Deploy RewardsModuleV1_2 and configure
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        vm.stopPrank();

        // 2. Deposit and rebalance
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // 3. Warp time to accrue rewards
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile and record totalAssets before
        vm.prank(keeper);
        vault.reconcile();
        uint256 totalBefore = vault.totalAssets();

        // 5. Harvest -- reward tokens flow to rewardsModule
        vm.prank(keeper);
        vault.harvestAll();

        uint256 rewardBalance = IERC20(compRewardToken).balanceOf(address(rm));
        assertGt(rewardBalance, 0, "COMP rewards should be claimed to rewardsModule");

        // 6. Simulate swap: deal base asset to module as if swapped
        uint256 simulatedSwapOutput = depositAmount / 200;
        deal(token, address(rm), simulatedSwapOutput);

        // 7. Sweep to vault
        vm.prank(keeper);
        rm.sweepToVault();

        // 8. Verify total assets increased
        assertGt(vault.totalAssets(), totalBefore, "Total assets should increase after rewards sweep");
        assertEq(IERC20(token).balanceOf(address(rm)), 0, "Module should be empty after sweep");
    }

    // =========================================================================
    // RewardsModuleV1_2: Claims Executor
    // =========================================================================

    function test_rewardsModule_claimWhitelist_crud() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        address target = address(0x123);
        bytes4 selector = bytes4(keccak256("claim(address,address,bool)"));

        // Initially not whitelisted
        assertFalse(rm.claimWhitelist(target, selector));

        // Admin can add
        vm.prank(admin);
        rm.setClaimWhitelist(target, selector, true);
        assertTrue(rm.claimWhitelist(target, selector));

        // Admin can remove
        vm.prank(admin);
        rm.setClaimWhitelist(target, selector, false);
        assertFalse(rm.claimWhitelist(target, selector));
    }

    function test_rewardsModule_executeClaim_reverts_notWhitelisted() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);
        vm.prank(admin);
        rm.setKeeper(keeper);

        // Use a real contract address (vault) so it passes code-size check
        bytes memory data = abi.encodeWithSignature("claim(address,address,bool)", address(0), address(0), true);

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.TargetNotWhitelisted.selector);
        rm.executeClaim(address(vault), data);
    }

    function test_rewardsModule_executeClaim_reverts_notKeeper() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        bytes memory data = abi.encodeWithSignature("claim(address,address,bool)", address(0), address(0), true);

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        rm.executeClaim(address(0x1), data);
    }

    function test_rewardsModule_executeClaim_reverts_shortData() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        // Use a real contract address so it passes code-size check
        vm.prank(admin);
        vm.expectRevert(RewardsModuleV1_2.TargetNotWhitelisted.selector);
        rm.executeClaim(address(vault), hex"001122"); // < 4 bytes
    }

    /// @notice Real executeClaim: supply to Compound from RM, accrue rewards, claim via executeClaim
    function test_rewardsModule_executeClaim_claimsCompRewards() public {
        if (!_compRewardsActive()) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        // Whitelist CometRewards.claim
        bytes4 claimSelector = bytes4(keccak256("claim(address,address,bool)"));
        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setClaimWhitelist(cometRewards, claimSelector, true);
        vm.stopPrank();

        // Supply directly to Compound FROM the RM address so rewards accrue to RM
        uint256 supplyAmount = depositAmount;
        deal(token, address(rm), supplyAmount);

        vm.startPrank(address(rm));
        IERC20(token).forceApprove(compoundComet, supplyAmount);
        (bool ok,) = compoundComet.call(abi.encodeWithSignature("supply(address,uint256)", token, supplyAmount));
        require(ok, "supply failed");
        vm.stopPrank();

        // Warp time to accrue COMP rewards.
        // Use a short period (1 day) to avoid exceeding the CometRewards' COMP
        // balance — on chains with low reward budgets, 30 days of accrual can
        // exceed what the rewards contract actually holds.
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7_200);

        // Execute claim via RewardsModuleV1_2
        bytes memory claimData = abi.encodeWithSelector(claimSelector, compoundComet, address(rm), true);

        vm.prank(keeper);
        rm.executeClaim(cometRewards, claimData);

        // Verify COMP rewards received by RM
        assertGt(IERC20(compRewardToken).balanceOf(address(rm)), 0, "COMP rewards should be claimed to RM");
    }

    // =========================================================================
    // RewardsModuleV1_2: Swap Engine
    // =========================================================================

    function test_rewardsModule_routerWhitelist_crud() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        address router = address(0x456);

        assertFalse(rm.allowedRouters(router));

        vm.prank(admin);
        rm.setRouterWhitelist(router, true);
        assertTrue(rm.allowedRouters(router));

        vm.prank(admin);
        rm.setRouterWhitelist(router, false);
        assertFalse(rm.allowedRouters(router));
    }

    function test_rewardsModule_swap_reverts_routerNotWhitelisted() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);
        vm.prank(admin);
        rm.setKeeper(keeper);

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.RouterNotWhitelisted.selector);
        rm.swap(address(0x1), address(0x2), token, 100, 1, hex"");
    }

    function test_rewardsModule_swap_reverts_invalidTokenOut() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);
        address router = address(0x456);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(router, true);
        vm.stopPrank();

        address wrongToken = address(0xdead);

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.InvalidTokenOut.selector);
        rm.swap(router, address(0x2), wrongToken, 100, 1, hex"");
    }

    function test_rewardsModule_swap_reverts_notKeeper() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        rm.swap(address(0x1), address(0x2), token, 100, 1, hex"");
    }

    /// @notice Real swap: COMP → base asset via Uniswap V3
    function test_rewardsModule_swap_viaUniswap() public {
        if (uniswapRouter == address(0)) return;
        if (compRewardToken == address(0)) return;
        if (swapPath.length == 0) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniswapRouter, true);
        vm.stopPrank();

        // Deal COMP to RewardsModuleV1_2
        uint256 compAmount = 10e18; // 10 COMP
        deal(compRewardToken, address(rm), compAmount);

        // Build Uniswap V3 exactInput calldata using the configured swap path
        bytes memory routerData = abi.encodeCall(
            ISwapRouter.exactInput,
            (
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(rm),
                    deadline: block.timestamp,
                    amountIn: compAmount,
                    amountOutMinimum: 0
                })
            )
        );

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        vm.prank(keeper);
        // minAmountOut == 1 keeps the slippage check effectively permissive
        // while satisfying the zero-floor gate.
        rm.swap(uniswapRouter, compRewardToken, token, compAmount, 1, routerData);

        uint256 baseBalAfter = IERC20(token).balanceOf(address(rm));
        assertGt(baseBalAfter, baseBalBefore, "Base asset balance should increase after swap");

        // Verify COMP was spent
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "All COMP should be swapped");

        // Verify approval was reset
        assertEq(IERC20(compRewardToken).allowance(address(rm), uniswapRouter), 0, "Approval should be reset");
    }

    /// @notice Slippage protection: real swap succeeds on Uniswap but RM rejects due to minAmountOut
    function test_rewardsModule_swap_reverts_slippage() public {
        if (uniswapRouter == address(0)) return;
        if (compRewardToken == address(0)) return;
        if (swapPath.length == 0) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniswapRouter, true);
        vm.stopPrank();

        uint256 compAmount = 1e18; // 1 COMP
        deal(compRewardToken, address(rm), compAmount);

        // Uniswap's amountOutMinimum=0 so swap succeeds, but RM's minAmountOut is unreachably high
        bytes memory routerData = abi.encodeCall(
            ISwapRouter.exactInput,
            (
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(rm),
                    deadline: block.timestamp,
                    amountIn: compAmount,
                    amountOutMinimum: 0
                })
            )
        );

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.SlippageExceeded.selector);
        rm.swap(uniswapRouter, compRewardToken, token, compAmount, type(uint256).max, routerData);
    }

    // =========================================================================
    // RewardsModuleV1_2: Admin
    // =========================================================================

    function test_rewardsModule_transferAdmin() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.prank(admin);
        rm.transferAdmin(alice);
        assertEq(rm.pendingAdmin(), alice);
        assertEq(rm.admin(), admin); // still admin until accepted

        vm.prank(alice);
        rm.acceptAdmin();
        assertEq(rm.admin(), alice);

        // Old admin can no longer act
        vm.prank(admin);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        rm.setRouterWhitelist(address(0x1), true);

        // New admin can
        vm.prank(alice);
        rm.setRouterWhitelist(address(0x1), true);
        assertTrue(rm.allowedRouters(address(0x1)));
    }

    function test_rewardsModule_transferAdmin_reverts_zeroAddress() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.prank(admin);
        vm.expectRevert(RewardsModuleV1_2.ZeroAddress.selector);
        rm.transferAdmin(address(0));
    }

    function test_rewardsModule_setKeeper_access() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        // Non-admin cannot set keeper
        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        rm.setKeeper(alice);

        // Admin can set keeper
        vm.prank(admin);
        rm.setKeeper(keeper);
        assertEq(rm.keeper(), keeper);

        // Admin can disable keeper
        vm.prank(admin);
        rm.setKeeper(address(0));
        assertEq(rm.keeper(), address(0));
    }

    function test_rewardsModule_sweepToVault_reverts_empty() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.NothingToSweep.selector);
        rm.sweepToVault();
    }

    function test_rewardsModule_constructor_reverts_zeroAddress() public {
        vm.expectRevert(RewardsModuleV1_2.ZeroAddress.selector);
        new RewardsModuleV1_2(address(0), admin);

        vm.expectRevert(RewardsModuleV1_2.ZeroAddress.selector);
        new RewardsModuleV1_2(address(vault), address(0));
    }

    function test_rewardsModule_rescueToken_works_forNonBase() public {
        if (compRewardToken == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        uint256 stuckAmount = 1000e18;
        deal(compRewardToken, address(rm), stuckAmount);

        vm.prank(admin);
        rm.rescueToken(compRewardToken, admin, stuckAmount);

        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "RM should be empty");
        assertEq(IERC20(compRewardToken).balanceOf(admin), stuckAmount, "Admin should receive rescued tokens");
    }

    function test_rewardsModule_rescueToken_reverts_notAdmin() public {
        if (compRewardToken == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);
        deal(compRewardToken, address(rm), 100);

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        rm.rescueToken(compRewardToken, alice, 100);
    }

    /// @notice Full end-to-end with REAL swap: harvest → executeClaim → swap via Uniswap → sweep → verify
    function test_rewardsModule_fullPipeline_withRealSwap() public {
        if (uniswapRouter == address(0)) return;
        if (swapPath.length == 0) return;
        if (address(compoundStrategy) == address(0)) return;
        if (!_compRewardsActive()) return;

        // 1. Deploy and configure RewardsModuleV1_2
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniswapRouter, true);
        vm.stopPrank();

        // 2. Deposit and rebalance
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // 3. Warp time to accrue rewards
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile and harvest
        vm.prank(keeper);
        vault.reconcile();
        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.harvestAll();

        uint256 compBalance = IERC20(compRewardToken).balanceOf(address(rm));
        assertGt(compBalance, 0, "COMP should be harvested to RM");

        // 5. REAL swap: COMP → base asset via Uniswap V3
        bytes memory routerData = abi.encodeCall(
            ISwapRouter.exactInput,
            (
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(rm),
                    deadline: block.timestamp,
                    amountIn: compBalance,
                    amountOutMinimum: 0
                })
            )
        );

        vm.prank(keeper);
        rm.swap(uniswapRouter, compRewardToken, token, compBalance, 1, routerData);

        uint256 swappedAmount = IERC20(token).balanceOf(address(rm));
        assertGt(swappedAmount, 0, "Should have base asset after swap");

        // 6. Sweep to vault
        vm.prank(keeper);
        rm.sweepToVault();

        // 7. Verify
        assertGt(vault.totalAssets(), totalBefore, "Total assets should increase");
        assertEq(IERC20(token).balanceOf(address(rm)), 0, "RM should be empty");
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "No COMP left");
    }

    // =========================================================================
    // RewardsModuleV1_2: Multi-Router (Uniswap V2 + Aggregator Verification)
    // =========================================================================

    /// @notice Real swap: COMP → base asset via Uniswap V2 Router
    function test_rewardsModule_swap_viaUniswapV2() public {
        if (uniV2Router == address(0)) return;
        if (compRewardToken == address(0)) return;
        if (wrappedNative == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniV2Router, true);
        vm.stopPrank();

        uint256 compAmount = 10e18; // 10 COMP
        deal(compRewardToken, address(rm), compAmount);

        // Build V2 path: COMP → WETH → baseAsset (or COMP → WETH if baseAsset is WETH)
        address[] memory path = _buildV2Path(compRewardToken, token);

        bytes memory routerData = abi.encodeCall(
            IUniswapV2Router02.swapExactTokensForTokens,
            (compAmount, 0, path, address(rm), block.timestamp)
        );

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        vm.prank(keeper);
        rm.swap(uniV2Router, compRewardToken, token, compAmount, 1, routerData);

        uint256 baseBalAfter = IERC20(token).balanceOf(address(rm));
        assertGt(baseBalAfter, baseBalBefore, "Base asset balance should increase after V2 swap");

        // Verify COMP was spent
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "All COMP should be swapped");

        // Verify approval was reset
        assertEq(IERC20(compRewardToken).allowance(address(rm), uniV2Router), 0, "Approval should be reset");
    }

    /// @notice Whitelist multiple routers (V3 + V2), swap sequentially through each
    function test_rewardsModule_multipleRouters_sequentialSwaps() public {
        if (uniswapRouter == address(0)) return;
        if (uniV2Router == address(0)) return;
        if (compRewardToken == address(0)) return;
        if (swapPath.length == 0) return;
        if (wrappedNative == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniswapRouter, true); // V3
        rm.setRouterWhitelist(uniV2Router, true); // V2
        vm.stopPrank();

        uint256 compAmount = 10e18;
        deal(compRewardToken, address(rm), compAmount);
        uint256 half = compAmount / 2;

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        // --- Swap first half via Uniswap V3 ---
        bytes memory v3Data = abi.encodeCall(
            ISwapRouter.exactInput,
            (
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(rm),
                    deadline: block.timestamp,
                    amountIn: half,
                    amountOutMinimum: 0
                })
            )
        );

        vm.prank(keeper);
        rm.swap(uniswapRouter, compRewardToken, token, half, 1, v3Data);

        uint256 baseAfterV3 = IERC20(token).balanceOf(address(rm));
        assertGt(baseAfterV3, baseBalBefore, "V3 swap should produce output");

        // --- Swap second half via Uniswap V2 ---
        address[] memory path = _buildV2Path(compRewardToken, token);
        bytes memory v2Data = abi.encodeCall(
            IUniswapV2Router02.swapExactTokensForTokens,
            (half, 0, path, address(rm), block.timestamp)
        );

        vm.prank(keeper);
        rm.swap(uniV2Router, compRewardToken, token, half, 1, v2Data);

        uint256 baseAfterV2 = IERC20(token).balanceOf(address(rm));
        assertGt(baseAfterV2, baseAfterV3, "V2 swap should produce additional output");

        // All COMP should be spent
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "All COMP should be swapped");
    }

    /// @notice Verify popular DEX aggregators are deployed and can be whitelisted.
    ///         In production, their API generates the routerData calldata.
    function test_rewardsModule_aggregators_whitelistable() public {
        address[4] memory aggregators = [ONEINCH_V6, ODOS_V3, PARASWAP_V6, ZEROX_PROXY];

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        uint256 deployed = 0;
        for (uint256 i = 0; i < aggregators.length; i++) {
            if (aggregators[i].code.length > 0) {
                deployed++;
                vm.prank(admin);
                rm.setRouterWhitelist(aggregators[i], true);
                assertTrue(rm.allowedRouters(aggregators[i]));
            }
        }

        // All supported chains should have at least 1 major aggregator deployed
        assertGe(deployed, 1, "At least 1 major aggregator should be deployed on this chain");
    }

    /// @notice Full E2E with V2 router: harvest → swap via Uniswap V2 → sweep
    function test_rewardsModule_fullPipeline_withUniswapV2() public {
        if (uniV2Router == address(0)) return;
        if (wrappedNative == address(0)) return;
        if (address(compoundStrategy) == address(0)) return;
        if (!_compRewardsActive()) return;

        // 1. Deploy and configure RewardsModuleV1_2
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(uniV2Router, true);
        vm.stopPrank();

        // 2. Deposit and rebalance
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // 3. Warp time to accrue rewards
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile and harvest
        vm.prank(keeper);
        vault.reconcile();
        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.harvestAll();

        uint256 compBalance = IERC20(compRewardToken).balanceOf(address(rm));
        assertGt(compBalance, 0, "COMP should be harvested to RM");

        // 5. REAL swap via Uniswap V2: COMP → WETH → base asset
        address[] memory path = _buildV2Path(compRewardToken, token);
        bytes memory routerData = abi.encodeCall(
            IUniswapV2Router02.swapExactTokensForTokens,
            (compBalance, 0, path, address(rm), block.timestamp)
        );

        vm.prank(keeper);
        rm.swap(uniV2Router, compRewardToken, token, compBalance, 1, routerData);

        uint256 swappedAmount = IERC20(token).balanceOf(address(rm));
        assertGt(swappedAmount, 0, "Should have base asset after V2 swap");

        // 6. Sweep to vault
        vm.prank(keeper);
        rm.sweepToVault();

        // 7. Verify
        assertGt(vault.totalAssets(), totalBefore, "Total assets should increase after V2 pipeline");
        assertEq(IERC20(token).balanceOf(address(rm)), 0, "RM should be empty");
    }

    // =========================================================================
    // RewardsModuleV1_2: FFI Aggregator Swap Tests (opt-in)
    //
    // These tests call external APIs (1inch, Odos, ParaSwap) via vm.ffi()
    // to get real swap calldata, then execute swaps on a fork.
    //
    // Run with: RUN_FFI_TESTS=true FOUNDRY_PROFILE=ffi forge test --match-test ffi
    // =========================================================================

    /// @notice FFI swap via Odos (no API key required)
    function test_ffi_swap_viaOdos() public {
        if (!vm.envOr("RUN_FFI_TESTS", false)) return;
        if (compRewardToken == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        vm.stopPrank();

        uint256 compAmount = 10e18;
        deal(compRewardToken, address(rm), compAmount);

        // Call external script to get swap calldata from Odos API
        bytes memory result = _getAggregatorCalldata("odos", compRewardToken, token, compAmount, address(rm));
        (address router, bytes memory routerData) = abi.decode(result, (address, bytes));

        // Dynamically whitelist the router returned by the API
        vm.prank(admin);
        rm.setRouterWhitelist(router, true);

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        vm.prank(keeper);
        rm.swap(router, compRewardToken, token, compAmount, 1, routerData);

        uint256 baseBalAfter = IERC20(token).balanceOf(address(rm));
        assertGt(baseBalAfter, baseBalBefore, "Odos: base asset balance should increase");
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "Odos: all reward tokens should be swapped");
        assertEq(IERC20(compRewardToken).allowance(address(rm), router), 0, "Odos: approval should be reset");
    }

    /// @notice FFI swap via ParaSwap (no API key required)
    function test_ffi_swap_viaParaswap() public {
        if (!vm.envOr("RUN_FFI_TESTS", false)) return;
        if (compRewardToken == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        vm.stopPrank();

        uint256 compAmount = 10e18;
        deal(compRewardToken, address(rm), compAmount);

        bytes memory result = _getAggregatorCalldata("paraswap", compRewardToken, token, compAmount, address(rm));
        (address router, bytes memory routerData) = abi.decode(result, (address, bytes));

        vm.prank(admin);
        rm.setRouterWhitelist(router, true);

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        vm.prank(keeper);
        rm.swap(router, compRewardToken, token, compAmount, 1, routerData);

        uint256 baseBalAfter = IERC20(token).balanceOf(address(rm));
        assertGt(baseBalAfter, baseBalBefore, "ParaSwap: base asset balance should increase");
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "ParaSwap: all reward tokens should be swapped");
        assertEq(IERC20(compRewardToken).allowance(address(rm), router), 0, "ParaSwap: approval should be reset");
    }

    /// @notice FFI swap via 1inch (requires ONEINCH_API_KEY env var)
    function test_ffi_swap_via1inch() public {
        if (!vm.envOr("RUN_FFI_TESTS", false)) return;
        if (bytes(vm.envOr("ONEINCH_API_KEY", string(""))).length == 0) return;
        if (compRewardToken == address(0)) return;

        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        rm.setKeeper(keeper);
        vm.stopPrank();

        uint256 compAmount = 10e18;
        deal(compRewardToken, address(rm), compAmount);

        bytes memory result = _getAggregatorCalldata("1inch", compRewardToken, token, compAmount, address(rm));
        (address router, bytes memory routerData) = abi.decode(result, (address, bytes));

        vm.prank(admin);
        rm.setRouterWhitelist(router, true);

        uint256 baseBalBefore = IERC20(token).balanceOf(address(rm));

        vm.prank(keeper);
        rm.swap(router, compRewardToken, token, compAmount, 1, routerData);

        uint256 baseBalAfter = IERC20(token).balanceOf(address(rm));
        assertGt(baseBalAfter, baseBalBefore, "1inch: base asset balance should increase");
        assertEq(IERC20(compRewardToken).balanceOf(address(rm)), 0, "1inch: all reward tokens should be swapped");
        assertEq(IERC20(compRewardToken).allowance(address(rm), router), 0, "1inch: approval should be reset");
    }

    /// @notice FFI full pipeline: harvest → Odos swap → sweep → verify totalAssets increased
    function test_ffi_fullPipeline_viaOdos() public {
        if (!vm.envOr("RUN_FFI_TESTS", false)) return;
        if (!_compRewardsActive()) return;

        // 1. Deploy and configure
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        vm.stopPrank();

        // 2. Deposit and rebalance
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
        vm.prank(keeper);
        vault.rebalance();

        // 3. Accrue rewards
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        // 4. Reconcile and harvest
        vm.prank(keeper);
        vault.reconcile();
        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.harvestAll();

        uint256 compBalance = IERC20(compRewardToken).balanceOf(address(rm));
        assertGt(compBalance, 0, "COMP should be harvested to RM");

        // 5. FFI swap via Odos
        bytes memory result = _getAggregatorCalldata("odos", compRewardToken, token, compBalance, address(rm));
        (address router, bytes memory routerData) = abi.decode(result, (address, bytes));

        vm.prank(admin);
        rm.setRouterWhitelist(router, true);

        vm.prank(keeper);
        rm.swap(router, compRewardToken, token, compBalance, 1, routerData);

        assertGt(IERC20(token).balanceOf(address(rm)), 0, "Should have base asset after Odos swap");

        // 6. Sweep
        vm.prank(keeper);
        rm.sweepToVault();

        // 7. Verify
        assertGt(vault.totalAssets(), totalBefore, "Total assets should increase after Odos pipeline");
        assertEq(IERC20(token).balanceOf(address(rm)), 0, "RM should be empty");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Call external script to get swap calldata from a DEX aggregator API via vm.ffi()
    function _getAggregatorCalldata(
        string memory aggregator,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address from
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](8);
        cmd[0] = "bash";
        cmd[1] = "script/get-swap-calldata.sh";
        cmd[2] = aggregator;
        cmd[3] = vm.toString(block.chainid);
        cmd[4] = vm.toString(tokenIn);
        cmd[5] = vm.toString(tokenOut);
        cmd[6] = vm.toString(amount);
        cmd[7] = vm.toString(from);
        return vm.ffi(cmd);
    }

    /// @dev Build Uniswap V2 path: tokenIn → wrappedNative → tokenOut (or direct if tokenOut == wrappedNative)
    function _buildV2Path(address tokenIn, address tokenOut) internal view returns (address[] memory path) {
        if (tokenOut == wrappedNative) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = wrappedNative;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = wrappedNative;
            path[2] = tokenOut;
        }
    }
}
