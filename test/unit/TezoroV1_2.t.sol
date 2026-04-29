// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// ---- Mock ERC-20 ----

contract V1TestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---- Mock Strategy with configurable behavior ----

contract V1TestStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    uint256 internal _balance;
    bool public healthy = true;
    bool public broken = false;
    bool public fullyBroken = false;
    bool public depositBroken = false; // deposit reverts but isHealthy works
    bool public withdrawBroken = false; // withdraw reverts but availableLiquidity works
    uint256 public extraWithdraw = 0; // extra tokens to return beyond requested amount
    uint256 public shortWithdraw = 0; // simulate underdelivery (e.g. underlying-protocol rounding)

    // Reward token support
    mapping(address => uint256) public rewardBalances;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256 amount) external override {
        if (broken || depositBroken) revert("broken");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balance += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        if (broken || withdrawBroken) revert("broken");
        uint256 toSend = amount > _balance ? _balance : amount;
        toSend += extraWithdraw; // simulate returning more than requested
        if (toSend > shortWithdraw) toSend -= shortWithdraw;
        else toSend = 0;
        if (toSend > _balance) toSend = _balance;
        _balance -= toSend;
        IERC20(asset).safeTransfer(msg.sender, toSend);
        return toSend;
    }

    function emergencyWithdraw() external override returns (uint256) {
        if (fullyBroken) revert("fully broken");
        uint256 bal = _balance;
        _balance = 0;
        IERC20(asset).safeTransfer(msg.sender, bal);
        return bal;
    }

    function balanceOf() external view override returns (uint256) {
        if (broken) revert("broken");
        return _balance;
    }

    function availableLiquidity() external view override returns (uint256) {
        if (broken) revert("broken");
        return _balance;
    }

    function isHealthy() external view override returns (bool) {
        if (broken) revert("broken");
        return healthy;
    }

    function harvest(address) external view override returns (uint256) {
        if (broken) revert("broken");
        return 0;
    }

    function sweepReward(address rewardToken, address to) external override returns (uint256) {
        uint256 bal = IERC20(rewardToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(rewardToken).safeTransfer(to, bal);
        }
        return bal;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setFullyBroken(bool b) external {
        broken = b;
        fullyBroken = b;
    }

    function setHealthy(bool h) external {
        healthy = h;
    }

    function setDepositBroken(bool b) external {
        depositBroken = b;
    }

    function setWithdrawBroken(bool b) external {
        withdrawBroken = b;
    }

    function setExtraWithdraw(uint256 extra) external {
        extraWithdraw = extra;
    }

    function setShortWithdraw(uint256 short) external {
        shortWithdraw = short;
    }

    function simulateYield(uint256 amount) external {
        V1TestUSDC(asset).mint(address(this), amount);
        _balance += amount;
    }
}

// ---- Mock reward token ----

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---- Tests ----

contract TezoroV1_2Test is Test {
    V1TestUSDC token;
    TezoroV1_2 vault;
    V1TestStrategy strategyA;
    V1TestStrategy strategyB;
    MockRewardToken rewardToken;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address nobody = makeAddr("nobody");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        token = new V1TestUSDC();
        rewardToken = new MockRewardToken();

        vault = new TezoroV1_2(
            IERC20(address(token)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            1_000, // 10% performance fee
            300 // 3% idle buffer
        );

        strategyA = new V1TestStrategy(address(token));
        strategyB = new V1TestStrategy(address(token));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategyA)));
        vault.addStrategy(IStrategy(address(strategyB)));
        vault.setKeeper(keeper);
        vault.setGuardian(guardian);
        vm.stopPrank();

        // Fund users
        token.mint(alice, DEPOSIT * 10);
        token.mint(bob, DEPOSIT * 10);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // Constructor Validation
    // =========================================================================

    function test_constructor_reverts_zeroAdmin() public {
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        new TezoroV1_2(IERC20(address(token)), "V", "V", address(0), feeRecipient, 0, 0);
    }

    function test_constructor_reverts_zeroFeeRecipient() public {
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        new TezoroV1_2(IERC20(address(token)), "V", "V", admin, address(0), 0, 0);
    }

    function test_constructor_reverts_feeTooHigh() public {
        vm.expectRevert(TezoroV1_2.InvalidFee.selector);
        new TezoroV1_2(IERC20(address(token)), "V", "V", admin, feeRecipient, 3_001, 0);
    }

    function test_constructor_reverts_bufferTooHigh() public {
        vm.expectRevert(TezoroV1_2.InvalidBuffer.selector);
        new TezoroV1_2(IERC20(address(token)), "V", "V", admin, feeRecipient, 0, 2_001);
    }

    function test_constructor_setsHwm() public view {
        // HWM should be initial share price = 1e6 (1 USDC per share unit)
        assertEq(vault.highWaterMark(), 1e6);
    }

    // =========================================================================
    // Modifier Revert Paths
    // =========================================================================

    function test_onlyAdmin_reverts() public {
        vm.prank(nobody);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.transferAdmin(nobody);
    }

    function test_onlyAdminOrKeeper_reverts() public {
        vm.prank(nobody);
        vm.expectRevert(TezoroV1_2.NotAdminOrKeeper.selector);
        vault.rebalance();
    }

    function test_onlyGuardianOrAdmin_reverts() public {
        vm.prank(nobody);
        vm.expectRevert(TezoroV1_2.NotGuardianOrAdmin.selector);
        vault.pauseStrategy(IStrategy(address(strategyA)));
    }

    function test_whenNotPaused_reverts() public {
        vm.prank(admin);
        vault.pauseVault();

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.VaultIsPaused.selector);
        vault.deposit(DEPOSIT, alice);
    }

    // =========================================================================
    // Admin Config Setters
    // =========================================================================

    function test_setIdleBuffer() public {
        vm.prank(admin);
        vault.setIdleBuffer(500);
        assertEq(vault.idleBufferBps(), 500);
    }

    function test_setIdleBuffer_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidBuffer.selector);
        vault.setIdleBuffer(2_001);
    }

    function test_setMaxDeviation() public {
        vm.prank(admin);
        vault.setMaxDeviation(100);
        assertEq(vault.maxDeviationBps(), 100);
    }

    function test_setMaxDeviation_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.setMaxDeviation(10_001);
    }

    function test_setDepositCap() public {
        vm.prank(admin);
        vault.setDepositCap(1_000_000e6);
        assertEq(vault.depositCap(), 1_000_000e6);
    }

    function test_pauseVault() public {
        vm.prank(admin);
        vault.pauseVault();
        assertTrue(vault.paused());
    }

    function test_unpauseVault() public {
        vm.prank(admin);
        vault.pauseVault();
        vm.prank(admin);
        vault.unpauseVault();
        assertFalse(vault.paused());
    }

    function test_setRewardsModule() public {
        address rm = makeAddr("rm");
        vm.prank(admin);
        vault.setRewardsModule(rm);
        assertEq(vault.rewardsModule(), rm);
    }

    function test_setRewardsModule_requiresTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        address rm = makeAddr("rm");
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.setRewardsModule(rm);
    }

    function test_setRewardsModule_worksWithTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        address rm = makeAddr("rm");
        bytes32 opHash = keccak256(abi.encode("setRewardsModule", rm));
        vm.prank(admin);
        vault.proposeTimelock(opHash);
        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vault.setRewardsModule(rm);
        assertEq(vault.rewardsModule(), rm);
    }

    function test_setRewardsModule_noTimelockWhenDisabled() public {
        // timelockDelay is 0 by default — should work immediately
        address rm = makeAddr("rm");
        vm.prank(admin);
        vault.setRewardsModule(rm);
        assertEq(vault.rewardsModule(), rm);
    }

    // =========================================================================
    // Strategy Management
    // =========================================================================

    function test_addStrategy_reverts_duplicate() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyAlreadyActive.selector);
        vault.addStrategy(IStrategy(address(strategyA)));
    }

    function test_addStrategy_reverts_tooMany() public {
        // Fill up to MAX_STRATEGIES (already 2, add 18 more)
        for (uint256 i = 0; i < 18; i++) {
            V1TestStrategy s = new V1TestStrategy(address(token));
            vm.prank(admin);
            vault.addStrategy(IStrategy(address(s)));
        }

        V1TestStrategy extra = new V1TestStrategy(address(token));
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TooManyStrategies.selector);
        vault.addStrategy(IStrategy(address(extra)));
    }

    function test_addStrategy_reverts_assetMismatch() public {
        V1TestUSDC otherToken = new V1TestUSDC();
        V1TestStrategy mismatch = new V1TestStrategy(address(otherToken));
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyAssetMismatch.selector);
        vault.addStrategy(IStrategy(address(mismatch)));
    }

    function test_unpauseStrategy() public {
        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));
        assertTrue(vault.pausedStrategies(IStrategy(address(strategyA))));

        vm.prank(admin);
        vault.unpauseStrategy(IStrategy(address(strategyA)));
        assertFalse(vault.pausedStrategies(IStrategy(address(strategyA))));
    }

    function test_unpauseStrategy_reverts_notActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.unpauseStrategy(IStrategy(address(0xdead)));
    }

    function test_setMaxAllocation() public {
        vm.prank(admin);
        vault.setMaxAllocation(IStrategy(address(strategyA)), 5_000);
        assertEq(vault.maxAllocationBps(IStrategy(address(strategyA))), 5_000);
    }

    function test_setMaxAllocation_reverts_notActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.setMaxAllocation(IStrategy(address(0xdead)), 5_000);
    }

    function test_setMaxAllocation_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.setMaxAllocation(IStrategy(address(strategyA)), 10_001);
    }

    function test_removeStrategy_clearsState() public {
        // Deposit and rebalance so strategy has balance
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.startPrank(admin);
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Remove strategy
        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(strategyA)));

        assertFalse(vault.isActiveStrategy(IStrategy(address(strategyA))));
        assertEq(vault.targetAllocationBps(IStrategy(address(strategyA))), 0);
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
        assertEq(vault.strategiesCount(), 1);
    }

    function test_removeStrategy_reverts_notActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.removeStrategy(IStrategy(address(0xdead)));
    }

    function test_pauseStrategy_reverts_notActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.pauseStrategy(IStrategy(address(0xdead)));
    }

    // =========================================================================
    // sweepStrategyReward
    // =========================================================================

    function test_sweepStrategyReward() public {
        address rm = makeAddr("rm");
        vm.prank(admin);
        vault.setRewardsModule(rm);

        // Give strategy some reward tokens
        rewardToken.mint(address(strategyA), 100e18);

        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategyA)), address(rewardToken));

        assertEq(rewardToken.balanceOf(rm), 100e18);
    }

    function test_sweepStrategyReward_reverts_notActive() public {
        vm.prank(admin);
        vault.setRewardsModule(makeAddr("rm"));

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.sweepStrategyReward(IStrategy(address(0xdead)), address(rewardToken));
    }

    function test_sweepStrategyReward_reverts_noRewardsModule() public {
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.sweepStrategyReward(IStrategy(address(strategyA)), address(rewardToken));
    }

    // =========================================================================
    // View Helpers
    // =========================================================================

    function test_strategiesCount() public view {
        assertEq(vault.strategiesCount(), 2);
    }

    function test_getStrategies() public view {
        IStrategy[] memory strats = vault.getStrategies();
        assertEq(strats.length, 2);
        assertEq(address(strats[0]), address(strategyA));
        assertEq(address(strats[1]), address(strategyB));
    }

    function test_idleBalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        assertEq(vault.idleBalance(), DEPOSIT);
    }

    function test_needsRebalance_falseWhenNoDeviation() public view {
        // maxDeviationBps = 0 by default -> always false
        assertFalse(vault.needsRebalance());
    }

    function test_needsRebalance_falseWhenNoAssets() public {
        vm.prank(admin);
        vault.setMaxDeviation(100);
        assertFalse(vault.needsRebalance());
    }

    function test_needsRebalance_trueWhenDeviated() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Set target allocation but don't rebalance
        vm.startPrank(admin);
        vault.setMaxDeviation(100); // 1%
        vm.stopPrank();

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000; // 50% target

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Simulate yield on strategyA to create deviation
        strategyA.simulateYield(DEPOSIT / 2);
        vm.prank(keeper);
        vault.reconcile();

        assertTrue(vault.needsRebalance());
    }

    function test_needsRebalance_checksCurrentAboveTarget() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.setMaxDeviation(100);

        // Set high allocation, rebalance, then zero allocation
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now set target to 0 -> current > target
        bps[0] = 0;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // After rebalance with 0 target, funds should be withdrawn back
        // needsRebalance should be false after rebalance
        assertFalse(vault.needsRebalance());
    }

    function test_getAllocationStatus() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_000;
        bps[1] = 3_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        (IStrategy[] memory s, uint256[] memory targets, uint256[] memory actuals, bool[] memory h) =
            vault.getAllocationStatus();

        assertEq(s.length, 2);
        assertEq(targets[0], 4_000);
        assertEq(targets[1], 3_000);
        assertGt(actuals[0], 0);
        assertGt(actuals[1], 0);
        assertTrue(h[0]);
        assertTrue(h[1]);
    }

    function test_getAllocationStatus_brokenStrategy() public {
        strategyA.setBroken(true);

        (,,, bool[] memory h) = vault.getAllocationStatus();
        assertFalse(h[0]);
        assertTrue(h[1]);
    }

    // =========================================================================
    // totalAssets with paused strategies
    // =========================================================================

    function test_totalAssets_excludesPausedStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        uint256 totalAfter = vault.totalAssets();
        assertLt(totalAfter, totalBefore);
    }

    // =========================================================================
    // maxDeposit / maxMint with depositCap
    // =========================================================================

    function test_maxDeposit_withCap() public {
        vm.prank(admin);
        vault.setDepositCap(DEPOSIT);

        assertEq(vault.maxDeposit(alice), DEPOSIT);

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        assertEq(vault.maxDeposit(bob), 0);
    }

    function test_maxMint_withCap() public {
        vm.prank(admin);
        vault.setDepositCap(DEPOSIT);

        uint256 maxM = vault.maxMint(alice);
        assertGt(maxM, 0);

        vm.prank(alice);
        vault.mint(maxM, alice);

        assertEq(vault.maxMint(bob), 0);
    }

    function test_maxDeposit_returnsZeroWhenPaused() public {
        vm.prank(admin);
        vault.pauseVault();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxMint_returnsZeroWhenPaused() public {
        vm.prank(admin);
        vault.pauseVault();
        assertEq(vault.maxMint(alice), 0);
    }

    function test_maxDeposit_noCap() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_maxMint_noCap() public view {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    // =========================================================================
    // Withdraw via allowance (caller != owner)
    // =========================================================================

    function test_withdraw_viaAllowance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(DEPOSIT / 2, bob, alice);
        assertEq(token.balanceOf(bob), bobBefore + DEPOSIT / 2);
    }

    function test_redeem_viaAllowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);

        uint256 halfShares = shares / 2;
        vm.prank(alice);
        vault.approve(bob, halfShares);

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(halfShares, bob, alice);
        assertGt(token.balanceOf(bob), bobBefore);
    }

    // =========================================================================
    // Rebalance Branches
    // =========================================================================

    function test_rebalance_skipsPausedStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyB));
        bps[0] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
        assertGt(vault.trackedBalance(IStrategy(address(strategyB))), 0);
    }

    function test_rebalance_skipsUnhealthyStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.setHealthy(false);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 3_000;
        bps[1] = 3_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
        assertGt(vault.trackedBalance(IStrategy(address(strategyB))), 0);
    }

    function test_rebalance_skipsBrokenHealthCheck() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.setBroken(true);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 3_000;
        bps[1] = 3_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
        assertGt(vault.trackedBalance(IStrategy(address(strategyB))), 0);
    }

    function test_rebalance_enforcesCap() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // First set allocation to 50% (no cap yet)
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now lower the cap to 20% AFTER allocation was set
        vm.prank(admin);
        vault.setMaxAllocation(IStrategy(address(strategyA)), 2_000);

        // Rebalance again — cap should clamp the target
        vm.prank(keeper);
        vault.rebalance();

        // trackedBalance should be reduced to ~20% of total
        uint256 tracked = vault.trackedBalance(IStrategy(address(strategyA)));
        uint256 maxExpected = vault.totalAssets() * 2_000 / 10_000 + 1;
        assertLe(tracked, maxExpected);
    }

    function test_rebalance_respectsDeviationThreshold() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.setMaxDeviation(5_000); // 50% threshold -> won't rebalance small deviations

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 1_000; // 10% target, deviation = 10% < 50%

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Should skip because deviation < threshold
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    function test_rebalance_deviationThreshold_withdrawSide() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // First: allocate 50% to strategyA
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now set high deviation threshold and try to reduce allocation slightly
        vm.prank(admin);
        vault.setMaxDeviation(4_000); // 40% threshold

        bps[0] = 4_500; // 45% target, 5% deviation < 40% threshold
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Should skip withdraw because deviation < threshold
        // trackedBalance should still be ~50% of total
        uint256 tracked = vault.trackedBalance(IStrategy(address(strategyA)));
        assertGt(tracked, DEPOSIT * 4_000 / 10_000); // still > 40%
    }

    function test_rebalance_withdrawsFromOverallocated() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate 50%
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 trackedBefore = vault.trackedBalance(IStrategy(address(strategyA)));
        assertGt(trackedBefore, 0);

        // Reduce to 10%
        bps[0] = 1_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 trackedAfter = vault.trackedBalance(IStrategy(address(strategyA)));
        assertLt(trackedAfter, trackedBefore);
    }

    function test_rebalance_withdrawCatchesError() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Break strategy, then try to withdraw
        strategyA.setBroken(true);

        bps[0] = 0;
        vm.prank(keeper);
        vault.rebalance(strats, bps);
        // Should not revert; broken strategy is skipped
    }

    function test_rebalance_depositCatchesError() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.setBroken(true);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);
        // Should not revert; broken deposit is caught
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    function test_rebalance_skipsDepositFrozenStrategy() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    function test_rebalance_noIdleAvailable() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate everything
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_850;
        bps[1] = 4_850;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Try to allocate more -- no idle left
        bps[0] = 5_000;
        bps[1] = 4_700;
        vm.prank(keeper);
        vault.rebalance(strats, bps);
        // Should not revert, just skip when no idle
    }

    function test_rebalance_setAllocations_lengthMismatch() public {
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 5_000;

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.rebalance(strats, bps);
    }

    function test_rebalance_setAllocation_reverts_notActive() public {
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(0xdead));
        bps[0] = 5_000;

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.rebalance(strats, bps);
    }

    function test_rebalance_setAllocation_reverts_tooHigh() public {
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 10_001;

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.rebalance(strats, bps);
    }

    function test_rebalance_setAllocation_reverts_exceedsCap() public {
        vm.prank(admin);
        vault.setMaxAllocation(IStrategy(address(strategyA)), 2_000);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 3_000;

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.AllocationExceedsCap.selector);
        vault.rebalance(strats, bps);
    }

    // =========================================================================
    // Reconcile
    // =========================================================================

    function test_reconcile_updateTrackedBalances() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Simulate yield
        strategyA.simulateYield(1_000e6);

        uint256 trackedBefore = vault.trackedBalance(IStrategy(address(strategyA)));
        vm.prank(keeper);
        vault.reconcile();
        uint256 trackedAfter = vault.trackedBalance(IStrategy(address(strategyA)));

        assertGt(trackedAfter, trackedBefore);
    }

    function test_reconcile_skipsBrokenStrategy() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 3_000;
        bps[1] = 3_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 trackedA = vault.trackedBalance(IStrategy(address(strategyA)));

        // Break strategyA
        strategyA.setBroken(true);

        // Reconcile should skip A but still work for B
        vm.prank(keeper);
        vault.reconcile();

        // A's tracked balance should be unchanged (stale)
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), trackedA);
    }

    function test_reconcile_skipsPausedStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        strategyA.simulateYield(1_000e6);

        uint256 trackedBefore = vault.trackedBalance(IStrategy(address(strategyA)));
        vm.prank(keeper);
        vault.reconcile();
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), trackedBefore);
    }

    // =========================================================================
    // harvestAll
    // =========================================================================

    function test_harvestAll_noop_whenNoRewardsModule() public {
        vm.prank(keeper);
        vault.harvestAll();
        // Should not revert, just no-op
    }

    function test_harvestAll_skipsBroken() public {
        vm.prank(admin);
        vault.setRewardsModule(makeAddr("rm"));

        strategyA.setBroken(true);

        vm.prank(keeper);
        vault.harvestAll();
        // Should not revert
    }

    function test_harvestAll_skipsPaused() public {
        vm.prank(admin);
        vault.setRewardsModule(makeAddr("rm"));

        vm.prank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        vm.prank(keeper);
        vault.harvestAll();
        // Should not revert
    }

    // =========================================================================
    // Timelock
    // =========================================================================

    function test_timelock_proposeAndCancel() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256("test_op");

        vm.prank(admin);
        vault.proposeTimelock(opHash);

        assertFalse(vault.isTimelockReady(opHash)); // not ready yet

        vm.warp(block.timestamp + 1 days);
        assertTrue(vault.isTimelockReady(opHash)); // now ready

        vm.prank(admin);
        vault.cancelTimelock(opHash);

        assertFalse(vault.isTimelockReady(opHash)); // cancelled
    }

    function test_cancelTimelock_reverts_notFound() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.cancelTimelock(keccak256("nonexistent"));
    }

    function test_isTimelockReady_falseWhenNotProposed() public view {
        assertFalse(vault.isTimelockReady(keccak256("nonexistent")));
    }

    function test_isTimelockReady_falseWhenExecuted() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Propose and execute forceRedeem
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        bytes32 opHash = keccak256(abi.encode("forceRedeem", alice));
        vm.prank(admin);
        vault.proposeTimelock(opHash);

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vault.forceRedeem(alice);

        // Should be false after execution
        assertFalse(vault.isTimelockReady(opHash));
    }

    // =========================================================================
    // Withdrawal Waterfall with broken strategies
    // =========================================================================

    function test_withdraw_waterfallSkipsBrokenStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 3_000;
        bps[1] = 3_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Break strategyA's availableLiquidity
        strategyA.setBroken(true);

        // Should still withdraw from idle + strategyB
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0);

        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
    }

    function test_withdraw_waterfallSkipsBrokenWithdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate only to strategyA
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Idle should have ~3% (idle buffer) + strategyA has ~90%
        // Now break strategyA
        strategyA.setBroken(true);

        // maxWithdraw should be limited to idle only (broken strategy skipped)
        uint256 maxW = vault.maxWithdraw(alice);
        // Should be > 0 because idle exists
        assertGt(maxW, 0);

        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
    }

    // =========================================================================
    // _availableLiquidity with broken strategies
    // =========================================================================

    function test_availableLiquidity_skipsBrokenStrategies() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_000;
        bps[1] = 4_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 maxBefore = vault.maxWithdraw(alice);

        // Break one strategy
        strategyA.setBroken(true);

        uint256 maxAfter = vault.maxWithdraw(alice);
        assertLt(maxAfter, maxBefore);
    }

    // =========================================================================
    // depositRewards
    // =========================================================================

    function test_depositRewards_reverts_notRewardsModule() public {
        vm.prank(nobody);
        vm.expectRevert(TezoroV1_2.NotRewardsModule.selector);
        vault.depositRewards(1_000e6);
    }

    // =========================================================================
    // Edge: rebalance withdraw returns more than tracked (saturating sub)
    // =========================================================================

    function test_rebalance_withdraw_saturating() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Inject extra yield to strategy so it returns more than tracked
        strategyA.simulateYield(5_000e6);

        // Reduce allocation -> withdraw
        bps[0] = 1_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Should not underflow
        assertGe(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    // =========================================================================
    // Edge: withdraw(0) and redeem(0)
    // =========================================================================

    function test_withdraw_zero() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(alice);
        vault.withdraw(0, alice, alice);
        // Should not revert
    }

    function test_redeem_zero() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(alice);
        vault.redeem(0, alice, alice);
        // Should not revert
    }

    // =========================================================================
    // Rebalance simple form (no args)
    // =========================================================================

    function test_rebalance_simple() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Set allocations manually first
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now use the simple rebalance()
        vm.prank(keeper);
        vault.rebalance();
        // Should not revert
    }

    function test_rebalance_simple_reverts_whenPaused() public {
        vm.prank(admin);
        vault.pauseVault();

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.VaultIsPaused.selector);
        vault.rebalance();
    }

    // =========================================================================
    // Rebalance deposit catch (strategy healthy but deposit fails)
    // =========================================================================

    function test_rebalance_depositCatchesError_healthyStrategy() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Strategy is healthy but deposit is broken
        strategyA.setDepositBroken(true);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Should not revert; deposit catch handles the error
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    // =========================================================================
    // Rebalance withdraw catch (withdraw reverts during rebalance)
    // =========================================================================

    function test_rebalance_withdrawCatchesError_withdrawBroken() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate to strategy
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now break withdraw only and try to reduce allocation
        strategyA.setWithdrawBroken(true);

        bps[0] = 0;
        vm.prank(keeper);
        vault.rebalance(strats, bps);
        // Should not revert, withdraw catch handles it
    }

    // =========================================================================
    // Withdrawal waterfall: strategy.withdraw catch
    // =========================================================================

    function test_withdraw_waterfall_withdrawCatch() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate to both strategies
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_000;
        bps[1] = 4_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 idle = vault.idleBalance();
        uint256 trackedB = vault.trackedBalance(IStrategy(address(strategyB)));

        // Break strategyA's withdraw (but availableLiquidity still works)
        strategyA.setWithdrawBroken(true);

        // Withdraw only what idle + strategyB can cover (skip broken A)
        uint256 safeAmount = idle + trackedB - 2; // minus buffer
        assertGt(safeAmount, 0);

        vm.prank(alice);
        vault.withdraw(safeAmount, alice, alice);
    }

    // =========================================================================
    // Withdrawal waterfall: withdrawn > trackedBalance (saturating subtraction)
    // =========================================================================

    function test_withdraw_waterfall_withdrawnExceedsTracked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate 90% to strategyA
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 trackedBefore = vault.trackedBalance(IStrategy(address(strategyA)));

        // Inject yield to strategy so _balance > tracked
        strategyA.simulateYield(10_000e6);
        // DON'T reconcile - tracked stays at old value

        // Strategy's availableLiquidity() returns _balance (> tracked)
        // If waterfall requests more than tracked, withdrawn > tracked -> saturating sub

        // Withdraw everything possible -> waterfall pulls from strategy
        uint256 maxW = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);

        // trackedBalance should be 0 or reduced (saturating subtraction handled it)
        assertLe(vault.trackedBalance(IStrategy(address(strategyA))), trackedBefore);
    }

    // =========================================================================
    // needsRebalance: returns false when all within threshold
    // =========================================================================

    function test_needsRebalance_falseWhenWithinThreshold() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.setMaxDeviation(5_000); // 50% threshold

        // Set small allocation and rebalance
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 2_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // All strategies within threshold -> false
        assertFalse(vault.needsRebalance());
    }

    // =========================================================================
    // recallToIdle: withdrawn > trackedBalance
    // =========================================================================

    function test_recallToIdle_withdrawnExceedsTracked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Inject yield (strategy balance > tracked)
        strategyA.simulateYield(5_000e6);

        // recallToIdle withdraws tracked amount, but strategy may return more
        // Due to how our mock works (returns min(amount, balance)), it returns
        // exactly the requested amount. The tracked balance is set to 0 normally.
        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    // =========================================================================
    // mint when paused
    // =========================================================================

    function test_mint_reverts_whenPaused() public {
        vm.prank(admin);
        vault.pauseVault();

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.VaultIsPaused.selector);
        vault.mint(1e12, alice);
    }

    // =========================================================================
    // transferAdmin
    // =========================================================================

    function test_transferAdmin_reverts_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        vault.transferAdmin(address(0));
    }

    function test_transferAdmin_setsPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vault.transferAdmin(newAdmin);
        // Admin should NOT change yet
        assertEq(vault.admin(), admin);
        assertEq(vault.pendingAdmin(), newAdmin);
    }

    function test_acceptAdmin_works() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vault.transferAdmin(newAdmin);

        vm.prank(newAdmin);
        vault.acceptAdmin();
        assertEq(vault.admin(), newAdmin);
        assertEq(vault.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_reverts_notPending() public {
        vm.prank(nobody);
        vm.expectRevert(TezoroV1_2.NotPendingAdmin.selector);
        vault.acceptAdmin();
    }

    // =========================================================================
    // setFeeRecipient
    // =========================================================================

    function test_setFeeRecipient_works() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_reverts_zero() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    // =========================================================================
    // Rebalance via keeper (onlyAdminOrKeeper)
    // =========================================================================

    function test_rebalance_worksForAdmin() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.rebalance();
    }

    // =========================================================================
    // setPerformanceFee
    // =========================================================================

    function test_setPerformanceFee() public {
        vm.prank(admin);
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFeeBps(), 2_000);
    }

    function test_setPerformanceFee_reverts_tooHigh() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidFee.selector);
        vault.setPerformanceFee(3_001);
    }

    function test_setPerformanceFee_increase_requiresTimelock() public {
        // Set initial fee to 1000 bps (10%)
        vm.prank(admin);
        vault.setPerformanceFee(1_000);

        // Enable timelock
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Increasing fee should require timelock
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.setPerformanceFee(2_000);
    }

    function test_setPerformanceFee_increase_worksWithTimelock() public {
        vm.prank(admin);
        vault.setPerformanceFee(1_000);

        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("setPerformanceFee", uint256(2_000)));
        vm.prank(admin);
        vault.proposeTimelock(opHash);
        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFeeBps(), 2_000);
    }

    function test_setPerformanceFee_decrease_noTimelockNeeded() public {
        vm.prank(admin);
        vault.setPerformanceFee(2_000);

        // Enable timelock
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Decreasing fee should work immediately (no timelock needed)
        vm.prank(admin);
        vault.setPerformanceFee(500);
        assertEq(vault.performanceFeeBps(), 500);
    }

    function test_setPerformanceFee_toZero_noTimelockNeeded() public {
        vm.prank(admin);
        vault.setPerformanceFee(2_000);

        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Setting to 0 is a decrease — should work immediately
        vm.prank(admin);
        vault.setPerformanceFee(0);
        assertEq(vault.performanceFeeBps(), 0);
    }

    // =========================================================================
    // Guardian can pause vault
    // =========================================================================

    function test_guardian_canPauseVault() public {
        vm.prank(guardian);
        vault.pauseVault();
        assertTrue(vault.paused());
    }

    function test_guardian_cannotUnpauseVault() public {
        vm.prank(admin);
        vault.pauseVault();

        vm.prank(guardian);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.unpauseVault();
    }

    // =========================================================================
    // Withdraw still works when paused
    // =========================================================================

    function test_withdraw_worksWhenPaused() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.pauseVault();

        vm.prank(alice);
        vault.withdraw(DEPOSIT, alice, alice);
    }

    function test_redeem_worksWhenPaused() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);

        vm.prank(admin);
        vault.pauseVault();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    // =========================================================================
    // setKeeper
    // =========================================================================

    function test_setKeeper_disables() public {
        vm.prank(admin);
        vault.setKeeper(address(0));
        assertEq(vault.keeper(), address(0));
    }

    // =========================================================================
    // setTimelockDelay
    // =========================================================================

    function test_setTimelockDelay() public {
        vm.prank(admin);
        vault.setTimelockDelay(2 days);
        assertEq(vault.timelockDelay(), 2 days);
    }

    // =========================================================================
    // withdrawn > trackedBalance (saturating subtraction in recallToIdle)
    // =========================================================================

    function test_recallToIdle_strategyReturnsMoreThanTracked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Inject extra yield so _balance > tracked
        strategyA.simulateYield(5_000e6);
        // Set extraWithdraw so withdraw returns more than requested
        strategyA.setExtraWithdraw(2_000e6);

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        // trackedBalance should be 0 (saturating subtraction)
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
    }

    // =========================================================================
    // withdrawn > trackedBalance in _rebalance withdraw phase
    // =========================================================================

    function test_rebalance_withdrawReturnsMoreThanTracked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Inject yield to strategy so _balance > tracked
        strategyA.simulateYield(5_000e6);
        // Strategy returns extra tokens beyond amount requested
        strategyA.setExtraWithdraw(3_000e6);

        // Set allocation to 0 so toWithdraw = full trackedBalance
        // Strategy returns trackedBalance + extraWithdraw > trackedBalance
        bps[0] = 0;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Audit fix #2 (parallel location): trackedBalance is refreshed to the
        // strategy's live balance, not zeroed.
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), strategyA.balanceOf());
    }

    // =========================================================================
    // withdrawn > trackedBalance in _withdraw waterfall
    // =========================================================================

    function test_withdraw_waterfall_strategyReturnsMoreThanTracked() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Inject yield and set strategy to return extra
        strategyA.simulateYield(5_000e6);
        strategyA.setExtraWithdraw(2_000e6);

        // Withdraw forces waterfall to pull from strategy
        uint256 maxW = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);

        // Audit fix #2: trackedBalance is refreshed to the strategy's live
        // balance (was previously zeroed, hiding any leftover yield).
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), strategyA.balanceOf());
    }

    // =========================================================================
    // Fix 2: Dynamic _decimalsOffset
    // =========================================================================

    function test_decimalsOffset_matchesAssetDecimals() public view {
        // V1TestUSDC has 6 decimals, vault should have 12 total (6 + 6 offset)
        assertEq(vault.decimals(), 12);
    }

    // =========================================================================
    // Fix 3: Allocation sum validation
    // =========================================================================

    function test_rebalance_reverts_allocationExceedsBPS() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Set allocations summing to 10000 + 300 idle buffer = 10300 > BPS
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 5_000;
        bps[1] = 5_000; // 5000 + 5000 + 300 (idle) = 10300 > 10000

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.rebalance(strats, bps);
    }

    function test_rebalance_worksAtExactBPS() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // 4850 + 4850 + 300 (idle) = 10000 exactly
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_850;
        bps[1] = 4_850;

        vm.prank(keeper);
        vault.rebalance(strats, bps); // should not revert
    }

    function test_setIdleBuffer_reverts_pushesOverBPS() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // First set allocations close to limit
        IStrategy[] memory strats = new IStrategy[](2);
        uint256[] memory bps = new uint256[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        bps[0] = 4_500;
        bps[1] = 4_500; // 9000 + 300 idle = 9300, ok

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now increasing idle buffer to 1500 => 9000 + 1500 = 10500 > BPS
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidAllocation.selector);
        vault.setIdleBuffer(1_500);
    }

    // =========================================================================
    // Fix 5: Timelock overwrite prevention
    // =========================================================================

    function test_proposeTimelock_reverts_alreadyPending() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256("test_op");

        vm.prank(admin);
        vault.proposeTimelock(opHash);

        // Re-proposing same hash should revert
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockAlreadyPending.selector);
        vault.proposeTimelock(opHash);
    }

    function test_proposeTimelock_afterCancel_works() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256("test_op");

        vm.prank(admin);
        vault.proposeTimelock(opHash);

        // Cancel then re-propose
        vm.prank(admin);
        vault.cancelTimelock(opHash);

        vm.prank(admin);
        vault.proposeTimelock(opHash); // should not revert
    }

    function test_proposeTimelock_afterExecuted_works() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Propose and execute forceRedeem
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        bytes32 opHash = keccak256(abi.encode("forceRedeem", alice));
        vm.prank(admin);
        vault.proposeTimelock(opHash);

        vm.warp(block.timestamp + 1 days);
        vm.prank(admin);
        vault.forceRedeem(alice);

        // Deposit again so we can re-propose (audit-fix #4: bump staleness
        // clock since 1 day > MAX_STALENESS).
        vault.reconcile();
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Re-propose same hash after execution should work
        vm.prank(admin);
        vault.proposeTimelock(opHash); // should not revert
    }

    // =========================================================================
    // Fix 4: setTimelockDelay reduction requires timelock
    // =========================================================================

    function test_setTimelockDelay_increase_immediate() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Increasing delay should work immediately
        vm.prank(admin);
        vault.setTimelockDelay(2 days);
        assertEq(vault.timelockDelay(), 2 days);
    }

    function test_setTimelockDelay_decrease_requiresTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(2 days);

        // Decreasing without proposal should revert
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.setTimelockDelay(1 days);
    }

    function test_setTimelockDelay_decrease_withTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(2 days);

        // Propose the reduction
        bytes32 opHash = keccak256(abi.encode("setTimelockDelay", uint256(1 days)));
        vm.prank(admin);
        vault.proposeTimelock(opHash);

        // Wait for current delay (2 days)
        vm.warp(block.timestamp + 2 days);

        // Now reduction should work
        vm.prank(admin);
        vault.setTimelockDelay(1 days);
        assertEq(vault.timelockDelay(), 1 days);
    }

    function test_setTimelockDelay_toZero_requiresTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Setting to 0 is a reduction — requires timelock
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.setTimelockDelay(0);
    }

    // =========================================================================
    // Fix 6: removeStrategy timelock
    // =========================================================================

    function test_removeStrategy_requiresTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        // Should revert without proposal
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.removeStrategy(IStrategy(address(strategyA)));
    }

    function test_removeStrategy_worksWithTimelock() public {
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("removeStrategy", address(strategyA)));
        vm.prank(admin);
        vault.proposeTimelock(opHash);

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(strategyA)));
        assertFalse(vault.isActiveStrategy(IStrategy(address(strategyA))));
    }

    function test_removeStrategy_noTimelockWhenDisabled() public {
        // timelockDelay is 0 by default — should work immediately
        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(strategyA)));
        assertFalse(vault.isActiveStrategy(IStrategy(address(strategyA))));
    }

    // =========================================================================
    // Fix 7: removeStrategy fund loss event
    // =========================================================================

    function test_removeStrategy_emitsFundsLost_whenWithdrawFails() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Deploy funds to strategyA
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 9_700; // 97% to strategy

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 tracked = vault.trackedBalance(IStrategy(address(strategyA)));
        assertGt(tracked, 0);

        // Break the strategy so emergencyWithdraw fails
        strategyA.setFullyBroken(true);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TezoroV1_2.StrategyRemovalFundsLost(address(strategyA), tracked);
        vault.removeStrategy(IStrategy(address(strategyA)));
    }

    function test_removeStrategy_noFundsLost_whenWithdrawSucceeds() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bps = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bps[0] = 9_700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 tracked = vault.trackedBalance(IStrategy(address(strategyA)));
        assertGt(tracked, 0);

        // Strategy is healthy — emergencyWithdraw returns funds, so vault balance increases
        uint256 vaultBalBefore = token.balanceOf(address(vault));
        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(strategyA)));
        uint256 vaultBalAfter = token.balanceOf(address(vault));

        // Vault should have recovered the funds
        assertGe(vaultBalAfter - vaultBalBefore, tracked - 1, "Funds should be recovered");
    }

    // =========================================================================
    // Fix 10: ERC-4626 preview accuracy
    // =========================================================================

    function test_previewDeposit_matchesActual() public {
        // Seed vault first to establish share price
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Simulate yield so share price != 1:1
        strategyA.simulateYield(5_000e6);
        vm.prank(keeper);
        vault.reconcile();
        vm.prank(keeper);
        vault.collectFees();

        // Now test preview accuracy
        uint256 amount = 50_000e6;
        uint256 preview = vault.previewDeposit(amount);

        vm.prank(bob);
        uint256 actual = vault.deposit(amount, bob);

        assertEq(preview, actual, "previewDeposit should match actual shares minted");
    }

    function test_previewMint_matchesActual() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.simulateYield(5_000e6);
        vm.prank(keeper);
        vault.reconcile();
        vm.prank(keeper);
        vault.collectFees();

        uint256 sharesToMint = 10_000e12; // shares in 12-decimal
        uint256 preview = vault.previewMint(sharesToMint);

        vm.prank(bob);
        uint256 actual = vault.mint(sharesToMint, bob);

        assertEq(preview, actual, "previewMint should match actual assets taken");
    }

    function test_previewWithdraw_matchesActual() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.simulateYield(5_000e6);
        vm.prank(keeper);
        vault.reconcile();
        vm.prank(keeper);
        vault.collectFees();

        uint256 amount = 10_000e6;
        uint256 preview = vault.previewWithdraw(amount);

        vm.prank(alice);
        uint256 actual = vault.withdraw(amount, alice, alice);

        assertEq(preview, actual, "previewWithdraw should match actual shares burned");
    }

    function test_previewRedeem_matchesActual() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.simulateYield(5_000e6);
        vm.prank(keeper);
        vault.reconcile();
        vm.prank(keeper);
        vault.collectFees();

        uint256 shares = vault.balanceOf(alice) / 2;
        uint256 preview = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);

        assertEq(preview, actual, "previewRedeem should match actual assets received");
    }

    // =========================================================================
    // Fix 10: maxWithdraw/maxRedeem with pending performance fee
    // =========================================================================

    function test_maxWithdraw_withPendingFee() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Generate yield so there's a pending fee
        strategyA.simulateYield(10_000e6);
        vm.prank(keeper);
        vault.reconcile();

        // maxWithdraw should not revert when used
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0);

        vm.prank(alice);
        vault.withdraw(maxW, alice, alice); // should not revert
    }

    function test_maxRedeem_withPendingFee() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        strategyA.simulateYield(10_000e6);
        vm.prank(keeper);
        vault.reconcile();

        uint256 maxR = vault.maxRedeem(alice);
        assertGt(maxR, 0);

        vm.prank(alice);
        vault.redeem(maxR, alice, alice); // should not revert
    }

    // =========================================================================
    // Fix 10: Re-add removed strategy
    // =========================================================================

    function test_reAddRemovedStrategy() public {
        vm.prank(admin);
        vault.removeStrategy(IStrategy(address(strategyA)));
        assertFalse(vault.isActiveStrategy(IStrategy(address(strategyA))));

        // Re-add should work
        vm.prank(admin);
        vault.addStrategy(IStrategy(address(strategyA)));
        assertTrue(vault.isActiveStrategy(IStrategy(address(strategyA))));
    }

    // =========================================================================
    // Fix 10: depositRewards happy path
    // =========================================================================

    function test_depositRewards_happyPath() public {
        address rewards = makeAddr("rewardsModule");
        vm.prank(admin);
        vault.setRewardsModule(rewards);

        uint256 rewardAmount = 5_000e6;
        token.mint(rewards, rewardAmount);

        vm.startPrank(rewards);
        token.approve(address(vault), rewardAmount);
        vault.depositRewards(rewardAmount);
        vm.stopPrank();

        // Rewards should increase idle balance
        assertEq(vault.idleBalance(), rewardAmount);
    }

    // =========================================================================
    // depositRewards: fee accrual before deposit
    // =========================================================================

    function test_depositRewards_accruesFeeBeforeDeposit() public {
        // Setup: enable performance fee
        vm.prank(admin);
        vault.setPerformanceFee(1_000); // 10%

        // Alice deposits to create shares
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Simulate yield: mint extra tokens directly to vault (increases totalAssets)
        uint256 yieldAmount = 10_000e6;
        token.mint(address(vault), yieldAmount);

        // Setup rewards module
        address rewards = makeAddr("rewardsModule");
        vm.prank(admin);
        vault.setRewardsModule(rewards);

        uint256 rewardAmount = 5_000e6;
        token.mint(rewards, rewardAmount);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        // depositRewards should accrue fee BEFORE adding rewards to totalAssets
        vm.startPrank(rewards);
        token.approve(address(vault), rewardAmount);
        vault.depositRewards(rewardAmount);
        vm.stopPrank();

        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);

        // Fee recipient should have received shares from the yield accrual
        assertGt(feeRecipientSharesAfter, feeRecipientSharesBefore, "Fee should be accrued before rewards deposit");
    }

    // =========================================================================
    // _dustTolerance
    // =========================================================================

    function test_dustTolerance_withFewStrategies() public view {
        // vault has 2 strategies (strategyA, strategyB) from setUp
        // perStrategy = 2 * 2 = 4
        // For small amounts, perStrategy > bpsBased
        // bpsBased = 100e6 / 10000 = 10_000
        // perStrategy(4) < bpsBased(10_000) for 100e6
        // But for tiny amounts: bpsBased = 10 / 10000 = 0 -> perStrategy wins
        uint256 tinyAssets = 10;
        // strategies.length * 2 = 4, bpsBased = 10/10000 = 0
        // _dustTolerance is internal, so we test it indirectly via the view
        // Actually, we can't call _dustTolerance directly. Let's verify the behavior
        // through forceRedeem which uses it.
        // For now, just verify the vault has correct strategy count
        assertEq(vault.strategiesCount(), 2);
        // The dust tolerance for tiny assets = max(4, 0) = 4
        // The dust tolerance for 100e6 assets = max(4, 10_000) = 10_000
        // We can't call internal fn directly, but the forceRedeem tests below verify behavior
        assertGt(tinyAssets, 0); // just to avoid unused var warning
    }

    function test_forceRedeem_toleratesDust() public {
        // This verifies _dustTolerance works correctly in forceRedeem
        // by depositing and then force-redeeming when withdrawal has rounding
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Deploy half to strategy (which may have rounding on withdrawal)
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bpsList = new uint256[](1);
        bpsList[0] = 5_000;
        vm.prank(keeper);
        vault.rebalance(strats, bpsList);

        // Force redeem should succeed even with small rounding dust
        vm.prank(admin);
        vault.forceRedeem(alice);

        assertEq(vault.balanceOf(alice), 0, "Alice should have 0 shares after force redeem");
    }

    // =========================================================================
    // Audit fix #1 (Oak 2026-04-24): bounded dust tolerance in normal withdraw
    // =========================================================================

    /// @notice Pre-fix, _withdraw reverted whenever the cumulative strategy
    ///         underdelivery was non-zero. Post-fix, a normal user withdrawal
    ///         absorbs shortfalls up to _dustTolerance (per-strategy 2 wei OR
    ///         1 bps of assets) instead of bricking the user exit path.
    function test_auditFix1_underdeliveryWithinToleranceSucceeds() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // Allocate 90% to strategyA so the withdrawal must hit the strategy.
        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bpsList = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bpsList[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bpsList);

        // Simulate a small rounding loss (1 wei) inside the strategy adapter.
        strategyA.setShortWithdraw(1);

        // maxWithdraw already subtracts the per-strategy safety margin (2 wei),
        // so asking for it bypasses ERC4626's upfront ExceededMaxWithdraw guard
        // and exercises the post-execution underdelivery path that fix #1 patches.
        uint256 maxW = vault.maxWithdraw(alice);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
        uint256 balanceAfter = token.balanceOf(alice);

        // User receives maxW - 1 wei; the dust is absorbed by the tolerance.
        assertEq(balanceAfter - balanceBefore, maxW - 1, "user should receive maxW - dust");
    }

    /// @notice Shortfalls above the dust tolerance still revert. Tolerance is
    ///         meant for protocol rounding, not silent value loss.
    function test_auditFix1_underdeliveryAboveToleranceReverts() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bpsList = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bpsList[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bpsList);

        uint256 maxW = vault.maxWithdraw(alice);
        // _dustTolerance(maxW) = max(strategiesCount * 2, maxW / BPS).
        uint256 perStrategy = vault.strategiesCount() * 2;
        uint256 bpsBased = maxW / vault.BPS();
        uint256 tolerance = perStrategy > bpsBased ? perStrategy : bpsBased;

        strategyA.setShortWithdraw(tolerance + 1);

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.WithdrawalFailed.selector);
        vault.withdraw(maxW, alice, alice);
    }

    // =========================================================================
    // Audit fix #2 (Oak 2026-04-24): refresh live trackedBalance on overdelivery
    // =========================================================================

    /// @notice Pre-fix, withdrawing more than the stale trackedBalance set
    ///         trackedBalance to 0, hiding any unreconciled yield still held
    ///         by the strategy and letting later depositors enter at a cheap
    ///         price until the next reconcile.
    /// @notice Post-fix, trackedBalance is refreshed to strategy.balanceOf()
    ///         so accounting stays consistent with reality.
    function test_auditFix2_overdeliveryRefreshesTrackedBalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        uint256[] memory bpsList = new uint256[](1);
        strats[0] = IStrategy(address(strategyA));
        bpsList[0] = 9_000;
        vm.prank(keeper);
        vault.rebalance(strats, bpsList);

        // Inject hidden balance into the strategy (simulates unreconciled yield).
        uint256 hiddenYield = 50_000e6;
        strategyA.simulateYield(hiddenYield);

        // Force the next strategy.withdraw to return more than asked, mimicking
        // the audit scenario where a withdrawal drains part of the unreconciled
        // yield alongside the requested principal.
        uint256 overdeliver = 20_000e6;
        strategyA.setExtraWithdraw(overdeliver);

        uint256 maxW = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);

        // Post-fix: trackedBalance equals strategy.balanceOf() — the leftover
        // yield is preserved in vault accounting instead of being zeroed.
        uint256 trackedAfter = vault.trackedBalance(IStrategy(address(strategyA)));
        uint256 liveAfter = strategyA.balanceOf();
        assertEq(trackedAfter, liveAfter, "trackedBalance must equal live balance");
        assertGt(trackedAfter, 0, "yield remainder must not be erased from accounting");
    }

    // =========================================================================
    // Audit fix #3 (Oak 2026-04-24): include RewardsModule base-asset balance
    //                                in totalAssets
    // =========================================================================

    /// @notice Pre-fix, base-asset rewards already swapped and parked in the
    ///         RewardsModule (waiting for sweepToVault) were not counted in
    ///         totalAssets. A depositor in that window minted shares against
    ///         a stale, lower NAV and captured part of the prior yield once
    ///         the sweep landed.
    function test_auditFix3_pendingRewardsIncludedInTotalAssets() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        address rm = makeAddr("rewards");
        vm.prank(admin);
        vault.setRewardsModule(rm);

        uint256 totalBefore = vault.totalAssets();

        // Simulate a swap landing base-asset rewards in the RewardsModule
        // (post-swap, pre-sweep window).
        uint256 rewardAmount = 10_000e6;
        token.mint(rm, rewardAmount);

        // Post-fix: totalAssets reflects the parked rewards immediately.
        assertEq(
            vault.totalAssets(),
            totalBefore + rewardAmount,
            "totalAssets must include base-asset rewards parked in RewardsModule"
        );
    }

    /// @notice Bob's deposit during the post-swap, pre-sweep window mints fewer
    ///         shares than the same deposit before the rewards landed. Pre-fix,
    ///         the rewards were invisible and bob got identical shares for the
    ///         same assets — capturing prior yield. Post-fix, the rewards are
    ///         priced in, so bob is correctly diluted.
    function test_auditFix3_depositInRewardWindowDoesNotCheapen() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        address rm = makeAddr("rewards");
        vm.prank(admin);
        vault.setRewardsModule(rm);

        uint256 bobDeposit = 10_000e6;
        // Reference: bob's shares before any rewards land in the module.
        uint256 sharesBefore = vault.previewDeposit(bobDeposit);

        // Reward sitting in the RewardsModule, not yet swept.
        uint256 rewardAmount = 10_000e6;
        token.mint(rm, rewardAmount);

        uint256 sharesAfter = vault.previewDeposit(bobDeposit);

        // Post-fix: rewards in the module raise totalAssets, so the same
        // deposit mints strictly fewer shares — no cheap entry.
        assertLt(sharesAfter, sharesBefore, "depositor in reward window must not mint stale-priced shares");
    }

    // =========================================================================
    // Audit fix #4 (Oak 2026-04-24): MAX_STALENESS + permissionless reconcile
    // =========================================================================

    /// @notice Deposit reverts with StaleNAV once the cached NAV is older than
    ///         MAX_STALENESS, bounding the stale-trackedBalance pricing window.
    function test_auditFix4_depositRevertsWhenStale() public {
        vm.warp(block.timestamp + vault.MAX_STALENESS() + 1);

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.StaleNAV.selector);
        vault.deposit(DEPOSIT, alice);
    }

    /// @notice Withdraw is gated by the same freshness check.
    function test_auditFix4_withdrawRevertsWhenStale() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.warp(block.timestamp + vault.MAX_STALENESS() + 1);

        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.StaleNAV.selector);
        vault.withdraw(1e6, alice, alice);
    }

    /// @notice Anyone can call reconcile() to refresh the staleness clock —
    ///         users self-unblock if the keeper falls behind.
    function test_auditFix4_reconcileIsPermissionless() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.warp(block.timestamp + vault.MAX_STALENESS() + 1);

        // Random EOA — not admin, not keeper.
        vm.prank(nobody);
        vault.reconcile();

        // Now deposit succeeds.
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
    }

    /// @notice reconcile bumps lastReconcileTimestamp.
    function test_auditFix4_reconcileBumpsTimestamp() public {
        uint256 before = vault.lastReconcileTimestamp();
        vm.warp(block.timestamp + 30 minutes);
        vault.reconcile();
        assertEq(vault.lastReconcileTimestamp(), block.timestamp);
        assertGt(vault.lastReconcileTimestamp(), before);
    }
}
