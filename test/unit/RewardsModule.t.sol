// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_1} from "../../src/TezoroV1_1.sol";
import {RewardsModule} from "../../src/RewardsModule.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// ---- Mock tokens ----

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward Token", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---- Mock strategy with harvest support ----

contract RewardsStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    address public rewardToken;
    uint256 internal _balance;
    uint256 internal _rewardBalance;

    constructor(address asset_, address rewardToken_) {
        asset = asset_;
        rewardToken = rewardToken_;
    }

    function deposit(uint256 amount) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balance += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        uint256 toSend = amount > _balance ? _balance : amount;
        _balance -= toSend;
        IERC20(asset).safeTransfer(msg.sender, toSend);
        return toSend;
    }

    function emergencyWithdraw() external override returns (uint256) {
        uint256 bal = _balance;
        _balance = 0;
        IERC20(asset).safeTransfer(msg.sender, bal);
        return bal;
    }

    function balanceOf() external view override returns (uint256) {
        return _balance;
    }

    function availableLiquidity() external view override returns (uint256) {
        return _balance;
    }

    function isHealthy() external pure override returns (bool) {
        return true;
    }

    /// @dev Transfers reward tokens to the rewards module (simulates harvest).
    function harvest(address rewardsModuleAddr) external override returns (uint256) {
        uint256 amount = _rewardBalance;
        if (amount == 0) return 0;
        _rewardBalance = 0;
        IERC20(rewardToken).safeTransfer(rewardsModuleAddr, amount);
        return amount;
    }

    function sweepReward(address token, address to) external override returns (uint256) {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        IERC20(token).safeTransfer(to, amount);
        return amount;
    }

    /// @dev Test helper: mint reward tokens to strategy to simulate accrual.
    function simulateRewardAccrual(uint256 amount) external {
        MockRewardToken(rewardToken).mint(address(this), amount);
        _rewardBalance += amount;
    }

    function simulateYield(uint256 amount) external {
        MockUSDC(asset).mint(address(this), amount);
        _balance += amount;
    }
}

// ---- Mock DEX router that simulates a swap ----

/// @dev Simulates a DEX router. Pulls tokenIn from the caller, sends a pre-configured
///      USDC amount back. The usdcOut value must be set before each swap in tests.
///      This decouples the test from decimal-scale issues between reward tokens and USDC.
contract MockRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    uint256 public usdcOut; // configurable output amount for the next swap

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setUsdcOut(uint256 amount) external {
        usdcOut = amount;
    }

    /// @dev Called by RewardsModule.swap() via low-level call.
    ///      Pulls tokenIn from caller (RewardsModule), sends usdcOut USDC back.
    function doSwap(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(usdc).safeTransfer(msg.sender, usdcOut);
    }
}

// ---- Tests ----

contract RewardsModuleTest is Test {
    MockUSDC usdc;
    MockRewardToken rwd;
    TezoroV1_1 vault;
    RewardsModule module;
    RewardsStrategy strategy;
    MockRouter router;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6; // 100k USDC

    function setUp() public {
        usdc = new MockUSDC();
        rwd = new MockRewardToken();
        router = new MockRouter(address(usdc));

        vault = new TezoroV1_1(
            IERC20(address(usdc)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            makeAddr("feeRecipient"),
            1_500, // 15% performance fee
            300 // 3% idle buffer
        );

        module = new RewardsModule(address(vault), admin);
        strategy = new RewardsStrategy(address(usdc), address(rwd));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
        vault.setRewardsModule(address(module));
        module.setKeeper(keeper);
        vm.stopPrank();

        // Fund Alice
        usdc.mint(alice, DEPOSIT * 10);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Helper
    // =========================================================================

    function _depositAndAllocate(address user, uint256 amount) internal {
        vm.prank(user);
        vault.deposit(amount, user);

        IStrategy[] memory s = new IStrategy[](1);
        s[0] = IStrategy(address(strategy));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9_700; // 97% to strategy, 3% idle
        vm.prank(keeper);
        vault.rebalance(s, bps);
    }

    // =========================================================================
    // Constructor / setup
    // =========================================================================

    function test_constructor_setsVaultAndBaseAsset() public view {
        assertEq(module.vault(), address(vault));
        assertEq(module.baseAsset(), address(usdc));
        assertEq(module.admin(), admin);
    }

    // =========================================================================
    // harvestAll → reward tokens swept to RewardsModule
    // =========================================================================

    function test_harvestAll_sweepsRewardTokensToModule() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 rewardAmount = 500e18; // 500 RWD tokens
        strategy.simulateRewardAccrual(rewardAmount);

        uint256 moduleBefore = rwd.balanceOf(address(module));

        vm.prank(keeper);
        vault.harvestAll();

        uint256 moduleAfter = rwd.balanceOf(address(module));
        assertEq(moduleAfter - moduleBefore, rewardAmount, "Harvest must sweep all reward tokens to module");
    }

    function test_harvestAll_emitsHarvestCompleted() public {
        _depositAndAllocate(alice, DEPOSIT);
        strategy.simulateRewardAccrual(500e18);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, false);
        emit TezoroV1_1.HarvestCompleted(0); // value doesn't matter, just check event
        vault.harvestAll();
    }

    function test_harvestAll_noopWhenNoRewardsModule() public {
        // Deploy a vault without a rewards module
        TezoroV1_1 bareVault = new TezoroV1_1(
            IERC20(address(usdc)), "T", "t", admin, makeAddr("fee"), 1_500, 300
        );
        vm.prank(admin);
        bareVault.addStrategy(IStrategy(address(strategy)));

        // Should not revert
        vm.prank(admin);
        bareVault.harvestAll();
    }

    // =========================================================================
    // executeClaim — merkle / airdrop claim
    // =========================================================================

    function test_executeClaim_requiresWhitelist() public {
        address fakeTarget = makeAddr("fakeTarget");
        bytes memory data = abi.encodeWithSignature("claim()");

        // EOA target hits code-size check first
        vm.prank(keeper);
        vm.expectRevert(RewardsModule.TargetHasNoCode.selector);
        module.executeClaim(fakeTarget, data);
    }

    function test_executeClaim_succeeds_whenWhitelisted() public {
        // Deploy a simple claimable contract
        MockClaimable claimable = new MockClaimable(address(rwd));
        rwd.mint(address(claimable), 1_000e18);

        bytes4 selector = MockClaimable.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(claimable), selector, true);

        uint256 before = rwd.balanceOf(address(module));
        bytes memory data = abi.encodeCall(MockClaimable.claim, (address(module), 1_000e18));
        vm.prank(keeper);
        module.executeClaim(address(claimable), data);

        assertEq(rwd.balanceOf(address(module)) - before, 1_000e18, "Claim must land in module");
    }

    // =========================================================================
    // swap — reward token → base asset
    // =========================================================================

    function test_swap_revertsIfRouterNotWhitelisted() public {
        vm.prank(keeper);
        vm.expectRevert(RewardsModule.RouterNotWhitelisted.selector);
        module.swap(
            address(router), address(rwd), address(usdc), 1e18, 1e6,
            abi.encodeCall(MockRouter.doSwap, (address(rwd), 1e18))
        );
    }

    function test_swap_revertsIfTokenOutNotBaseAsset() public {
        vm.prank(admin);
        module.setRouterWhitelist(address(router), true);

        address notUsdc = makeAddr("notUsdc");
        vm.prank(keeper);
        vm.expectRevert(RewardsModule.InvalidTokenOut.selector);
        module.swap(
            address(router), address(rwd), notUsdc, 1e18, 0,
            abi.encodeCall(MockRouter.doSwap, (address(rwd), 1e18))
        );
    }

    function test_swap_revertsIfTokenInIsBaseAsset() public {
        vm.prank(admin);
        module.setRouterWhitelist(address(router), true);

        vm.prank(keeper);
        vm.expectRevert(RewardsModule.CannotSwapBaseAsset.selector);
        module.swap(
            address(router), address(usdc), address(usdc), 1e6, 0,
            abi.encodeCall(MockRouter.doSwap, (address(usdc), 1e6))
        );
    }

    function test_swap_revertsOnSlippage() public {
        vm.prank(admin);
        module.setRouterWhitelist(address(router), true);

        // Fund module with reward tokens; router returns only 100 USDC but we require 200.
        rwd.mint(address(module), 100e18);
        usdc.mint(address(router), 100e6);
        router.setUsdcOut(100e6); // router will output 100 USDC

        vm.prank(keeper);
        vm.expectRevert(RewardsModule.SlippageExceeded.selector);
        module.swap(
            address(router), address(rwd), address(usdc), 100e18, 200e6, // require 200 USDC out
            abi.encodeCall(MockRouter.doSwap, (address(rwd), 100e18))
        );
    }

    function test_swap_succeeds() public {
        vm.prank(admin);
        module.setRouterWhitelist(address(router), true);

        uint256 swapAmount = 500e18; // 500 RWD (18-decimal)
        uint256 expectedUsdc = 500e6; // 500 USDC (6-decimal) output
        rwd.mint(address(module), swapAmount);
        usdc.mint(address(router), expectedUsdc);
        router.setUsdcOut(expectedUsdc);

        uint256 usdcBefore = usdc.balanceOf(address(module));
        vm.prank(keeper);
        module.swap(
            address(router), address(rwd), address(usdc), swapAmount, expectedUsdc,
            abi.encodeCall(MockRouter.doSwap, (address(rwd), swapAmount))
        );

        assertEq(usdc.balanceOf(address(module)) - usdcBefore, expectedUsdc, "Swap must produce USDC in module");
        assertEq(rwd.balanceOf(address(module)), 0, "All RWD must be consumed");
    }

    // =========================================================================
    // sweepToVault (depositRewards path)
    // =========================================================================

    function test_sweepToVault_revertsWhenEmpty() public {
        vm.prank(keeper);
        vm.expectRevert(RewardsModule.NothingToSweep.selector);
        module.sweepToVault();
    }

    function test_sweepToVault_increasesVaultTotalAssets() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 rewardUsdc = 1_000e6; // 1k USDC rewards
        usdc.mint(address(module), rewardUsdc);

        uint256 assetsBefore = vault.totalAssets();
        vm.prank(keeper);
        module.sweepToVault();

        uint256 assetsAfter = vault.totalAssets();
        assertEq(assetsAfter - assetsBefore, rewardUsdc, "totalAssets must increase by exact reward amount");
    }

    function test_sweepToVault_increasesSharePrice() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 sharePriceBefore = vault.convertToAssets(10 ** vault.decimals());

        uint256 rewardUsdc = 10_000e6; // 10k USDC rewards
        usdc.mint(address(module), rewardUsdc);

        vm.prank(keeper);
        module.sweepToVault();

        uint256 sharePriceAfter = vault.convertToAssets(10 ** vault.decimals());
        assertGt(sharePriceAfter, sharePriceBefore, "Share price must increase after rewards deposited");
    }

    function test_sweepToVault_emitsSweptToVault() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 rewardUsdc = 500e6;
        usdc.mint(address(module), rewardUsdc);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit RewardsModule.SweptToVault(rewardUsdc);
        module.sweepToVault();
    }

    // =========================================================================
    // Full rewards cycle: harvest → swap → sweep → fee accrues
    // =========================================================================

    /// @notice Full cycle: strategy accrues rewards → harvestAll → swap → sweepToVault
    ///         Verifies: vault.totalAssets increases, share price increases, fee accrues on next withdrawal.
    function test_fullRewardsCycle() public {
        _depositAndAllocate(alice, DEPOSIT);

        // Whitelist the router
        vm.prank(admin);
        module.setRouterWhitelist(address(router), true);

        // --- Step 1: Strategy accrues 1k RWD reward tokens ---
        uint256 rewardTokens = 1_000e18;
        strategy.simulateRewardAccrual(rewardTokens);

        // --- Step 2: Keeper harvests — RWD lands in RewardsModule ---
        vm.prank(keeper);
        vault.harvestAll();
        assertEq(rwd.balanceOf(address(module)), rewardTokens, "Step 2: RWD in module");

        // --- Step 3: Keeper swaps RWD → USDC (via mock router) ---
        // Router is pre-funded with the USDC it will output; usdcOut must be set explicitly
        // because RWD has 18 decimals and USDC has 6 — amounts are different scales.
        uint256 rewardUsdc = 1_000e6; // 1k USDC output from the swap
        usdc.mint(address(router), rewardUsdc);
        router.setUsdcOut(rewardUsdc);
        bytes memory swapData = abi.encodeCall(MockRouter.doSwap, (address(rwd), rewardTokens));

        vm.prank(keeper);
        module.swap(address(router), address(rwd), address(usdc), rewardTokens, rewardUsdc, swapData);
        assertEq(usdc.balanceOf(address(module)), rewardUsdc, "Step 3: USDC in module after swap");

        // --- Step 4: Keeper sweeps USDC to vault ---
        uint256 assetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = vault.convertToAssets(10 ** vault.decimals());

        vm.prank(keeper);
        module.sweepToVault();

        // Vault totalAssets increased by exact reward amount
        uint256 assetsAfter = vault.totalAssets();
        assertEq(assetsAfter - assetsBefore, rewardUsdc, "Step 4: totalAssets +1k USDC");

        // Share price increased — all depositors benefit
        uint256 sharePriceAfter = vault.convertToAssets(10 ** vault.decimals());
        assertGt(sharePriceAfter, sharePriceBefore, "Step 4: share price increased");

        // --- Step 5: Fee accrues on next withdrawal (rewards pushed share price above HWM) ---
        uint256 feeSharesBefore = vault.balanceOf(makeAddr("feeRecipient"));
        vm.prank(alice);
        vault.withdraw(1e6, alice, alice);
        uint256 feeSharesAfter = vault.balanceOf(makeAddr("feeRecipient"));

        assertGt(feeSharesAfter, feeSharesBefore, "Step 5: fee accrued on withdrawal after rewards");
    }

    // =========================================================================
    // rescueToken
    // =========================================================================

    function test_rescueToken_cannotRescueBaseAsset() public {
        usdc.mint(address(module), 1_000e6);
        vm.prank(admin);
        vm.expectRevert(RewardsModule.CannotRescueBaseAsset.selector);
        module.rescueToken(address(usdc), admin, 1_000e6);
    }

    function test_rescueToken_succeeds_forNonBaseAsset() public {
        rwd.mint(address(module), 500e18);
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        module.rescueToken(address(rwd), recipient, 500e18);
        assertEq(rwd.balanceOf(recipient), 500e18);
    }

    // =========================================================================
    // depositRewards — vault access control
    // =========================================================================

    function test_depositRewards_revertsIfNotModule() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(alice);
        vm.expectRevert(TezoroV1_1.NotRewardsModule.selector);
        vault.depositRewards(1_000e6);
    }

    // =========================================================================
    // Two-step admin transfer (RewardsModule)
    // =========================================================================

    function test_transferAdmin_setsPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        module.transferAdmin(newAdmin);
        assertEq(module.admin(), admin, "Admin should not change yet");
        assertEq(module.pendingAdmin(), newAdmin, "Pending admin should be set");
    }

    function test_acceptAdmin_works() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        module.transferAdmin(newAdmin);

        vm.prank(newAdmin);
        module.acceptAdmin();
        assertEq(module.admin(), newAdmin);
        assertEq(module.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_reverts_notPending() public {
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotPendingAdmin.selector);
        module.acceptAdmin();
    }

    // =========================================================================
    // Access control — missing coverage
    // =========================================================================

    function test_setClaimWhitelist_reverts_notAdmin() public {
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotAdmin.selector);
        module.setClaimWhitelist(makeAddr("target"), bytes4(0xdeadbeef), true);
    }

    function test_setRouterWhitelist_reverts_notAdmin() public {
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotAdmin.selector);
        module.setRouterWhitelist(makeAddr("router"), true);
    }

    function test_executeClaim_reverts_notAdminOrKeeper() public {
        bytes memory data = abi.encodeWithSignature("claim()");
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotAdminOrKeeper.selector);
        module.executeClaim(makeAddr("target"), data);
    }

    function test_swap_reverts_notAdminOrKeeper() public {
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotAdminOrKeeper.selector);
        module.swap(address(router), address(rwd), address(usdc), 1e18, 1e6, hex"");
    }

    function test_sweepToVault_reverts_notAdminOrKeeper() public {
        vm.prank(alice);
        vm.expectRevert(RewardsModule.NotAdminOrKeeper.selector);
        module.sweepToVault();
    }

    function test_executeClaim_reverts_dataShorterThan4Bytes() public {
        // Deploy a contract at the target address so it passes code-size check
        MockClaimable target = new MockClaimable(address(rwd));

        vm.prank(keeper);
        vm.expectRevert(RewardsModule.TargetNotWhitelisted.selector);
        module.executeClaim(address(target), hex"aabbcc");
    }

    function test_rescueToken_reverts_zeroAddress() public {
        rwd.mint(address(module), 100e18);
        vm.prank(admin);
        vm.expectRevert(RewardsModule.ZeroAddress.selector);
        module.rescueToken(address(rwd), address(0), 100e18);
    }

    function test_constructor_reverts_zeroVault() public {
        vm.expectRevert(RewardsModule.ZeroAddress.selector);
        new RewardsModule(address(0), admin);
    }

    function test_constructor_reverts_zeroAdmin() public {
        vm.expectRevert(RewardsModule.ZeroAddress.selector);
        new RewardsModule(address(vault), address(0));
    }
}

// ---- Helper contract for claim tests ----

contract MockClaimable {
    using SafeERC20 for IERC20;
    address public token;

    constructor(address token_) {
        token = token_;
    }

    function claim(address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }
}
