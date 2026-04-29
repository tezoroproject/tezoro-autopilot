// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockUSDCToken, MockRewardToken, MockStrategy, MockDexRouter} from "./shared/RewardsModuleTestBase.sol";

// ---- Reentrancy attack contracts ----

/// @dev Router that tries to reenter RewardsModuleV1_2.swap() during a swap
contract ReentrantRouter {
    using SafeERC20 for IERC20;

    RewardsModuleV1_2 public target;
    address public usdc;
    address public rwd;

    constructor(address usdc_, address rwd_) {
        usdc = usdc_;
        rwd = rwd_;
    }

    function setTarget(RewardsModuleV1_2 target_) external {
        target = target_;
    }

    /// @dev Called during RewardsModuleV1_2.swap() — tries to reenter swap
    function doSwap(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Try to reenter swap
        try target.swap(
            address(this), rwd, usdc, 1, 0,
            abi.encodeCall(this.doSwap, (rwd, 1))
        ) {} catch {}

        IERC20(usdc).safeTransfer(msg.sender, 1); // minimal output
    }
}

/// @dev Router that tries to reenter sweepToVault during a swap
contract ReentrantSweepRouter {
    using SafeERC20 for IERC20;

    RewardsModuleV1_2 public target;
    address public usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setTarget(RewardsModuleV1_2 target_) external {
        target = target_;
    }

    function doSwap(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(usdc).safeTransfer(msg.sender, 1);

        // Try to reenter sweepToVault
        try target.sweepToVault() {} catch {}
    }
}

/// @dev Claim target that tries to reenter executeClaim
contract ReentrantClaimTarget {
    RewardsModuleV1_2 public target;
    bool public attacked;

    function setTarget(RewardsModuleV1_2 target_) external {
        target = target_;
    }

    function claim(address, uint256) external {
        if (!attacked) {
            attacked = true;
            // Try to reenter executeClaim
            try target.executeClaim(
                address(this),
                abi.encodeCall(this.claim, (address(0), 0))
            ) {} catch {}
        }
    }
}

/// @dev Claim target that tries to reenter swap
contract ReentrantSwapClaimTarget {
    using SafeERC20 for IERC20;

    RewardsModuleV1_2 public target;
    address public router;

    function setTarget(RewardsModuleV1_2 target_, address router_) external {
        target = target_;
        router = router_;
    }

    function claim(address, uint256) external {
        // Try to call swap from within executeClaim
        try target.swap(
            router, address(0x1), address(0x2), 1, 0, hex""
        ) {} catch {}
    }
}

/// @dev Router that doesn't pull tokenIn but still sends baseAsset
contract FreeMoneyRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    uint256 public usdcOut;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setUsdcOut(uint256 amount) external {
        usdcOut = amount;
    }

    /// @dev Sends USDC without pulling tokenIn — simulates a bug or exploit
    function doSwap(address, uint256) external {
        // Don't pull tokenIn at all
        IERC20(usdc).safeTransfer(msg.sender, usdcOut);
    }
}

/// @dev Claim target that succeeds but transfers nothing
contract EmptyClaimTarget {
    function claim(address, uint256) external pure {
        // Succeed but do nothing
    }
}

/// @dev Router that fails (reverts)
contract FailingRouter {
    function doSwap(address, uint256) external pure {
        revert("Router broken");
    }
}

// ========================================================================
// Tests
// ========================================================================

contract RewardsModuleSecurityTest is Test {
    MockUSDCToken usdc;
    MockRewardToken rwd;
    TezoroV1_2 vault;
    RewardsModuleV1_2 module;
    MockStrategy strategy;
    MockDexRouter router;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDCToken();
        rwd = new MockRewardToken("Reward Token", "RWD");
        router = new MockDexRouter(address(usdc));

        vault = new TezoroV1_2(
            IERC20(address(usdc)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            makeAddr("feeRecipient"),
            1_500,
            300
        );

        module = new RewardsModuleV1_2(address(vault), admin);
        strategy = new MockStrategy(address(usdc));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
        vault.setRewardsModule(address(module));
        module.setKeeper(keeper);
        module.setRouterWhitelist(address(router), true);
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT * 10);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // 1. Reentrancy: Router → swap
    // =========================================================================

    function test_reentrancy_routerCallsSwap_reverts() public {
        ReentrantRouter reentrantRouter = new ReentrantRouter(address(usdc), address(rwd));
        reentrantRouter.setTarget(module);

        vm.prank(admin);
        module.setRouterWhitelist(address(reentrantRouter), true);

        rwd.mint(address(module), 100e18);
        usdc.mint(address(reentrantRouter), 10e6);

        // The swap itself should succeed (reentrant call silently fails inside try/catch)
        // but the important thing is the reentrant call doesn't execute
        vm.prank(keeper);
        module.swap(
            address(reentrantRouter), address(rwd), address(usdc), 100e18, 1,
            abi.encodeCall(ReentrantRouter.doSwap, (address(rwd), 100e18))
        );

        // Module got 1 USDC from the swap (the reentrant swap was blocked)
        assertEq(usdc.balanceOf(address(module)), 1, "Only initial swap output should land");
    }

    // =========================================================================
    // 2. Reentrancy: Router → sweepToVault
    // =========================================================================

    function test_reentrancy_routerCallsSweep_blocked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        ReentrantSweepRouter reentrantRouter = new ReentrantSweepRouter(address(usdc));
        reentrantRouter.setTarget(module);

        vm.prank(admin);
        module.setRouterWhitelist(address(reentrantRouter), true);

        rwd.mint(address(module), 100e18);
        usdc.mint(address(reentrantRouter), 10e6);
        // Pre-fund module with some USDC to make sweepToVault possible
        usdc.mint(address(module), 500e6);

        uint256 vaultBefore = vault.totalAssets();

        vm.prank(keeper);
        module.swap(
            address(reentrantRouter), address(rwd), address(usdc), 100e18, 1,
            abi.encodeCall(ReentrantSweepRouter.doSwap, (address(rwd), 100e18))
        );

        // The reentrant sweepToVault was blocked by nonReentrant
        // Module should still have the pre-funded USDC + swap output
        assertGt(usdc.balanceOf(address(module)), 0, "Module USDC not swept (reentry blocked)");
        assertEq(vault.totalAssets(), vaultBefore, "Vault should not have received sweep during swap");
    }

    // =========================================================================
    // 3. Reentrancy: Claim target → executeClaim
    // =========================================================================

    function test_reentrancy_claimTargetCallsClaim_blocked() public {
        ReentrantClaimTarget reentrantTarget = new ReentrantClaimTarget();
        reentrantTarget.setTarget(module);

        bytes4 selector = ReentrantClaimTarget.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(reentrantTarget), selector, true);

        // The outer call succeeds, the inner reentrant call is blocked
        vm.prank(keeper);
        module.executeClaim(
            address(reentrantTarget),
            abi.encodeCall(ReentrantClaimTarget.claim, (address(module), 100))
        );

        assertTrue(reentrantTarget.attacked(), "Outer call should have executed");
    }

    // =========================================================================
    // 4. Reentrancy: Claim target → swap
    // =========================================================================

    function test_reentrancy_claimTargetCallsSwap_blocked() public {
        ReentrantSwapClaimTarget reentrantTarget = new ReentrantSwapClaimTarget();
        reentrantTarget.setTarget(module, address(router));

        bytes4 selector = ReentrantSwapClaimTarget.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(reentrantTarget), selector, true);

        // Outer call succeeds, inner swap call is blocked by nonReentrant
        vm.prank(keeper);
        module.executeClaim(
            address(reentrantTarget),
            abi.encodeCall(ReentrantSwapClaimTarget.claim, (address(module), 100))
        );
    }

    // =========================================================================
    // 5. executeClaim on EOA (no code) — reverts with TargetHasNoCode
    // =========================================================================

    function test_executeClaim_eoaTarget_reverts() public {
        address eoaTarget = makeAddr("eoaWithNoCode");
        bytes4 fakeSelector = bytes4(keccak256("claim(address,uint256)"));

        vm.prank(admin);
        module.setClaimWhitelist(eoaTarget, fakeSelector, true);

        // Code-size check catches EOA before whitelist check
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.TargetHasNoCode.selector);
        module.executeClaim(
            eoaTarget,
            abi.encodeWithSelector(fakeSelector, address(module), 100)
        );
    }

    // =========================================================================
    // 6. Swap with router that doesn't consume tokenIn
    // =========================================================================

    function test_swap_routerDoesntPullTokenIn_approvalStillReset() public {
        FreeMoneyRouter freeRouter = new FreeMoneyRouter(address(usdc));

        vm.prank(admin);
        module.setRouterWhitelist(address(freeRouter), true);

        rwd.mint(address(module), 100e18);
        usdc.mint(address(freeRouter), 50e6);
        freeRouter.setUsdcOut(50e6);

        vm.prank(keeper);
        module.swap(
            address(freeRouter), address(rwd), address(usdc), 100e18, 50e6,
            abi.encodeCall(FreeMoneyRouter.doSwap, (address(rwd), 100e18))
        );

        // Router didn't pull RWD — module still has them
        assertEq(rwd.balanceOf(address(module)), 100e18, "RWD still in module");
        // But USDC arrived from router's own balance
        assertEq(usdc.balanceOf(address(module)), 50e6, "USDC from router");
        // Approval on RWD to router was reset
        assertEq(rwd.allowance(address(module), address(freeRouter)), 0, "Approval must be reset");
    }

    // =========================================================================
    // 7. Swap with failing router
    // =========================================================================

    function test_swap_routerReverts_propagatesError() public {
        FailingRouter failRouter = new FailingRouter();

        vm.prank(admin);
        module.setRouterWhitelist(address(failRouter), true);

        rwd.mint(address(module), 100e18);

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.SwapCallFailed.selector);
        module.swap(
            address(failRouter), address(rwd), address(usdc), 100e18, 0,
            abi.encodeCall(FailingRouter.doSwap, (address(rwd), 100e18))
        );
    }

    // =========================================================================
    // 8. Empty claim target — succeeds but transfers nothing
    // =========================================================================

    function test_executeClaim_emptyClaimTarget_succeedsNoTransfer() public {
        EmptyClaimTarget emptyTarget = new EmptyClaimTarget();

        bytes4 selector = EmptyClaimTarget.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(emptyTarget), selector, true);

        uint256 before = rwd.balanceOf(address(module));

        vm.prank(keeper);
        module.executeClaim(
            address(emptyTarget),
            abi.encodeCall(EmptyClaimTarget.claim, (address(module), 1_000e18))
        );

        assertEq(rwd.balanceOf(address(module)), before, "No tokens transferred");
    }

    // =========================================================================
    // 9. Security invariant: base asset can ONLY leave via sweepToVault
    // =========================================================================

    function test_invariant_baseAssetCannotBeRescued() public {
        usdc.mint(address(module), 1_000e6);

        vm.prank(admin);
        vm.expectRevert(RewardsModuleV1_2.CannotRescueBaseAsset.selector);
        module.rescueToken(address(usdc), admin, 1_000e6);
    }

    function test_invariant_baseAssetCannotBeSwapped() public {
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.CannotSwapBaseAsset.selector);
        module.swap(
            address(router), address(usdc), address(usdc), 100e6, 0,
            abi.encodeCall(MockDexRouter.doSwap, (address(usdc), 100e6))
        );
    }

    function test_invariant_sweepOnlyGoesToVault() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        usdc.mint(address(module), 1_000e6);

        uint256 vaultBefore = vault.totalAssets();
        uint256 moduleBefore = usdc.balanceOf(address(module));

        vm.prank(keeper);
        module.sweepToVault();

        // All USDC went to vault
        assertEq(usdc.balanceOf(address(module)), 0, "Module should be empty");
        assertEq(vault.totalAssets(), vaultBefore + moduleBefore, "Vault got exact amount");
    }

    // =========================================================================
    // 10. Admin can overwrite pending admin transfer
    // =========================================================================

    function test_adminCanOverwritePendingTransfer() public {
        address attacker = makeAddr("attacker");
        address safeAdmin = makeAddr("safeAdmin");

        vm.prank(admin);
        module.transferAdmin(attacker);
        assertEq(module.pendingAdmin(), attacker);

        // Admin realizes mistake, overwrites
        vm.prank(admin);
        module.transferAdmin(safeAdmin);
        assertEq(module.pendingAdmin(), safeAdmin);

        // Attacker cannot accept anymore
        vm.prank(attacker);
        vm.expectRevert(RewardsModuleV1_2.NotPendingAdmin.selector);
        module.acceptAdmin();

        // Safe admin can accept
        vm.prank(safeAdmin);
        module.acceptAdmin();
        assertEq(module.admin(), safeAdmin);
    }

    // =========================================================================
    // 11. Keeper set to zero — only admin can act
    // =========================================================================

    function test_keeperSetToZero_onlyAdminCanOperate() public {
        vm.prank(admin);
        module.setKeeper(address(0));

        usdc.mint(address(module), 100e6);

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Keeper cannot sweep
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        module.sweepToVault();

        // Admin can still sweep
        vm.prank(admin);
        module.sweepToVault();
    }

    // =========================================================================
    // 12. Multiple sequential swaps for different reward tokens
    // =========================================================================

    function test_multipleSwaps_differentTokens() public {
        MockRewardToken rwd2 = new MockRewardToken("Reward Token", "RWD");

        rwd.mint(address(module), 100e18);
        rwd2.mint(address(module), 200e18);
        usdc.mint(address(router), 300e6);

        // Swap first token
        router.setUsdcOut(100e6);
        vm.prank(keeper);
        module.swap(
            address(router), address(rwd), address(usdc), 100e18, 100e6,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd), 100e18))
        );

        // Swap second token
        router.setUsdcOut(200e6);
        vm.prank(keeper);
        module.swap(
            address(router), address(rwd2), address(usdc), 200e18, 200e6,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd2), 200e18))
        );

        assertEq(usdc.balanceOf(address(module)), 300e6, "Both swaps produced USDC");
        assertEq(rwd.balanceOf(address(module)), 0, "First token consumed");
        assertEq(rwd2.balanceOf(address(module)), 0, "Second token consumed");
    }

    // =========================================================================
    // 13. Swap then sweep: full cycle integrity
    // =========================================================================

    function test_swapThenSweep_vaultSharePriceIncreases() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory s = new IStrategy[](1);
        s[0] = IStrategy(address(strategy));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9_700;
        vm.prank(keeper);
        vault.rebalance(s, bps);

        uint256 oneShare = 10 ** vault.decimals();
        uint256 sharePriceBefore = vault.convertToAssets(oneShare);

        // Simulate reward swap
        rwd.mint(address(module), 1_000e18);
        usdc.mint(address(router), 1_000e6);
        router.setUsdcOut(1_000e6);

        vm.prank(keeper);
        module.swap(
            address(router), address(rwd), address(usdc), 1_000e18, 1_000e6,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd), 1_000e18))
        );

        vm.prank(keeper);
        module.sweepToVault();

        uint256 sharePriceAfter = vault.convertToAssets(oneShare);
        assertGt(sharePriceAfter, sharePriceBefore, "Share price must increase");
    }

    // =========================================================================
    // 14. Whitelist removal prevents previously-allowed operations
    // =========================================================================

    function test_claimWhitelistRemoval_blocksExecution() public {
        EmptyClaimTarget target = new EmptyClaimTarget();
        bytes4 selector = EmptyClaimTarget.claim.selector;

        vm.prank(admin);
        module.setClaimWhitelist(address(target), selector, true);

        // Works when whitelisted
        vm.prank(keeper);
        module.executeClaim(address(target), abi.encodeCall(EmptyClaimTarget.claim, (address(0), 0)));

        // Remove from whitelist
        vm.prank(admin);
        module.setClaimWhitelist(address(target), selector, false);

        // Now reverts
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.TargetNotWhitelisted.selector);
        module.executeClaim(address(target), abi.encodeCall(EmptyClaimTarget.claim, (address(0), 0)));
    }

    function test_routerWhitelistRemoval_blocksSwap() public {
        rwd.mint(address(module), 100e18);
        usdc.mint(address(router), 100e6);
        router.setUsdcOut(100e6);

        // Remove router
        vm.prank(admin);
        module.setRouterWhitelist(address(router), false);

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.RouterNotWhitelisted.selector);
        module.swap(
            address(router), address(rwd), address(usdc), 100e18, 100e6,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd), 100e18))
        );
    }

    // =========================================================================
    // 15. depositRewards access control: only RewardsModuleV1_2 can call
    // =========================================================================

    function test_depositRewards_onlyRewardsModule() public {
        usdc.mint(bob, 1_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), 1_000e6);

        // Random user cannot deposit rewards
        vm.prank(bob);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.depositRewards(1_000e6);

        // Admin cannot deposit rewards
        usdc.mint(admin, 1_000e6);
        vm.prank(admin);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.depositRewards(1_000e6);

        // Keeper cannot deposit rewards
        usdc.mint(keeper, 1_000e6);
        vm.prank(keeper);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.depositRewards(1_000e6);
    }

    // =========================================================================
    // 16. Swap with zero amountIn
    // =========================================================================

    function test_swap_zeroAmountIn_approvalStillReset() public {
        usdc.mint(address(router), 10e6);
        router.setUsdcOut(10e6);

        // Even with 0 amountIn, the function should execute (router may still send output)
        vm.prank(keeper);
        module.swap(
            address(router), address(rwd), address(usdc), 0, 0,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd), 0))
        );

        // Approval reset even for zero amount
        assertEq(rwd.allowance(address(module), address(router)), 0);
    }

    // =========================================================================
    // 17. Admin cannot be set to current admin's own address (no-op but valid)
    // =========================================================================

    function test_transferAdmin_toSelf_works() public {
        vm.prank(admin);
        module.transferAdmin(admin);

        vm.prank(admin);
        module.acceptAdmin();

        assertEq(module.admin(), admin);
        assertEq(module.pendingAdmin(), address(0));
    }

    // =========================================================================
    // 18. Pause: blocks operations
    // =========================================================================

    function test_pause_blocksExecuteClaim() public {
        EmptyClaimTarget target = new EmptyClaimTarget();
        bytes4 selector = EmptyClaimTarget.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(target), selector, true);

        vm.prank(admin);
        module.pause();

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.IsPaused.selector);
        module.executeClaim(address(target), abi.encodeCall(EmptyClaimTarget.claim, (address(0), 0)));
    }

    function test_pause_blocksSwap() public {
        vm.prank(admin);
        module.pause();

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.IsPaused.selector);
        module.swap(address(router), address(rwd), address(usdc), 1, 0, hex"");
    }

    function test_pause_blocksSweepToVault() public {
        usdc.mint(address(module), 100e6);

        vm.prank(admin);
        module.pause();

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.IsPaused.selector);
        module.sweepToVault();
    }

    function test_pause_rescueTokenStillWorks() public {
        rwd.mint(address(module), 100e18);

        vm.prank(admin);
        module.pause();

        // rescueToken works even when paused (emergency recovery)
        vm.prank(admin);
        module.rescueToken(address(rwd), admin, 100e18);
        assertEq(rwd.balanceOf(admin), 100e18);
    }

    function test_unpause_restoresOperations() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        usdc.mint(address(module), 100e6);

        vm.prank(admin);
        module.pause();

        // Blocked
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.IsPaused.selector);
        module.sweepToVault();

        // Unpause
        vm.prank(admin);
        module.unpause();

        // Works again
        vm.prank(keeper);
        module.sweepToVault();
        assertEq(usdc.balanceOf(address(module)), 0);
    }

    function test_pause_onlyAdmin() public {
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.pause();

        vm.prank(alice);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.pause();
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(admin);
        module.pause();

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.unpause();
    }
}

// ========================================================================
// Fuzz Tests
// ========================================================================

contract RewardsModuleFuzzTest is Test {
    MockUSDCToken usdc;
    MockRewardToken rwd;
    TezoroV1_2 vault;
    RewardsModuleV1_2 module;
    MockStrategy strategy;
    MockDexRouter router;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDCToken();
        rwd = new MockRewardToken("Reward Token", "RWD");
        router = new MockDexRouter(address(usdc));

        vault = new TezoroV1_2(
            IERC20(address(usdc)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            makeAddr("feeRecipient"),
            1_500,
            300
        );

        module = new RewardsModuleV1_2(address(vault), admin);
        strategy = new MockStrategy(address(usdc));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
        vault.setRewardsModule(address(module));
        module.setKeeper(keeper);
        module.setRouterWhitelist(address(router), true);
        vm.stopPrank();

        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Fuzz: swap slippage check
    // =========================================================================

    /// @notice Swap always reverts when actual output < minAmountOut
    function testFuzz_swap_slippageAlwaysEnforced(uint256 actualOut, uint256 minOut) public {
        // Bound to reasonable ranges
        actualOut = bound(actualOut, 0, 10_000_000e6);
        minOut = bound(minOut, 1, 10_000_000e6); // minOut > 0

        uint256 rwdAmount = 1_000e18;
        rwd.mint(address(module), rwdAmount);
        usdc.mint(address(router), actualOut);
        router.setUsdcOut(actualOut);

        bytes memory swapData = abi.encodeCall(MockDexRouter.doSwap, (address(rwd), rwdAmount));

        if (actualOut < minOut) {
            vm.prank(keeper);
            vm.expectRevert(RewardsModuleV1_2.SlippageExceeded.selector);
            module.swap(address(router), address(rwd), address(usdc), rwdAmount, minOut, swapData);
        } else {
            vm.prank(keeper);
            module.swap(address(router), address(rwd), address(usdc), rwdAmount, minOut, swapData);
            assertGe(usdc.balanceOf(address(module)), minOut, "Output must meet minimum");
        }
    }

    // =========================================================================
    // Fuzz: sweepToVault preserves totalAssets accounting
    // =========================================================================

    /// @notice sweepToVault always increases totalAssets by exactly the swept amount
    function testFuzz_sweepToVault_exactAccounting(uint256 depositAmt, uint256 rewardAmt) public {
        depositAmt = bound(depositAmt, 1e6, 1_000_000e6);
        rewardAmt = bound(rewardAmt, 1, 1_000_000e6);

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        usdc.mint(address(module), rewardAmt);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        module.sweepToVault();

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalAfter - totalBefore, rewardAmt, "totalAssets must increase by exact reward amount");
        assertEq(usdc.balanceOf(address(module)), 0, "Module must be empty after sweep");
    }

    // =========================================================================
    // Fuzz: approval is always reset after swap
    // =========================================================================

    function testFuzz_swap_approvalAlwaysReset(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1_000_000e18);

        rwd.mint(address(module), amountIn);
        uint256 usdcAmount = 1e6; // minimal valid output
        usdc.mint(address(router), usdcAmount);
        router.setUsdcOut(usdcAmount);

        vm.prank(keeper);
        module.swap(
            address(router), address(rwd), address(usdc), amountIn, 0,
            abi.encodeCall(MockDexRouter.doSwap, (address(rwd), amountIn))
        );

        assertEq(rwd.allowance(address(module), address(router)), 0, "Approval must be zero after swap");
    }

    // =========================================================================
    // Fuzz: rescueToken works for any non-base token amount
    // =========================================================================

    function testFuzz_rescueToken_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        address recipient = makeAddr("recipient");

        rwd.mint(address(module), amount);

        vm.prank(admin);
        module.rescueToken(address(rwd), recipient, amount);

        assertEq(rwd.balanceOf(address(module)), 0, "Module empty");
        assertEq(rwd.balanceOf(recipient), amount, "Recipient got exact amount");
    }

    // =========================================================================
    // Fuzz: unauthorized callers always revert
    // =========================================================================

    function testFuzz_accessControl_randomCallerReverts(address caller) public {
        vm.assume(caller != admin && caller != keeper && caller != address(0));

        // executeClaim
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        module.executeClaim(address(0x1), abi.encodeWithSignature("claim()"));

        // swap
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        module.swap(address(router), address(rwd), address(usdc), 1, 0, hex"");

        // sweepToVault
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdminOrKeeper.selector);
        module.sweepToVault();

        // setClaimWhitelist
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.setClaimWhitelist(address(0x1), bytes4(0), true);

        // setRouterWhitelist
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.setRouterWhitelist(address(0x1), true);

        // transferAdmin
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.transferAdmin(makeAddr("newAdmin"));

        // setKeeper
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.setKeeper(makeAddr("newKeeper"));

        // rescueToken
        vm.prank(caller);
        vm.expectRevert(RewardsModuleV1_2.NotAdmin.selector);
        module.rescueToken(address(rwd), caller, 1);
    }
}
