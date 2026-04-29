// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// ---- Mock ERC-20 ----

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---- Mock Strategy ----

contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    uint256 internal _balance;
    bool public healthy = true;
    bool public broken = false;
    bool public fullyBroken = false;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256 amount) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balance += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        if (broken) revert("broken");
        uint256 toSend = amount > _balance ? _balance : amount;
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

    function harvest(address) external pure override returns (uint256) {
        return 0;
    }

    function sweepReward(address, address) external pure override returns (uint256) {
        return 0;
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
}

// ---- Tests ----

contract DepositFreezeTest is Test {
    MockUSDC token;
    TezoroV1_2 vault;
    MockStrategy strategyA;
    MockStrategy strategyB;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new MockUSDC();
        vault = new TezoroV1_2(
            IERC20(address(token)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            0, // no performance fee
            300 // 3% idle buffer
        );

        strategyA = new MockStrategy(address(token));
        strategyB = new MockStrategy(address(token));

        vm.startPrank(admin);
        vault.setKeeper(keeper);
        vault.setGuardian(guardian);
        vault.addStrategy(IStrategy(address(strategyA)));
        vault.addStrategy(IStrategy(address(strategyB)));
        vm.stopPrank();

        // Fund users
        token.mint(alice, 100_000e6);
        token.mint(bob, 50_000e6);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // ========== freezeStrategyDeposits ==========

    function test_freezeStrategyDeposits_works() public {
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
        assertFalse(vault.depositFrozenStrategies(IStrategy(address(strategyB))));
    }

    function test_freezeStrategyDeposits_guardianCanFreeze() public {
        vm.prank(guardian);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
    }

    function test_freezeStrategyDeposits_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TezoroV1_2.StrategyDepositFrozen(address(strategyA));

        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
    }

    function test_freezeStrategyDeposits_revertsIfNotGuardianOrAdmin() public {
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotGuardianOrAdmin.selector);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
    }

    function test_freezeStrategyDeposits_revertsIfNotActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.freezeStrategyDeposits(IStrategy(makeAddr("unknown")));
    }

    function test_freezeStrategyDeposits_revertsIfAlreadyFrozen() public {
        vm.startPrank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        vm.expectRevert(TezoroV1_2.StrategyAlreadyDepositFrozen.selector);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
        vm.stopPrank();
    }

    // ========== unfreezeStrategyDeposits ==========

    function test_unfreezeStrategyDeposits_works() public {
        vm.startPrank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
        vault.unfreezeStrategyDeposits(IStrategy(address(strategyA)));
        vm.stopPrank();

        assertFalse(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
    }

    function test_unfreezeStrategyDeposits_emitsEvent() public {
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        vm.expectEmit(true, false, false, false);
        emit TezoroV1_2.StrategyDepositUnfrozen(address(strategyA));

        vm.prank(admin);
        vault.unfreezeStrategyDeposits(IStrategy(address(strategyA)));
    }

    function test_unfreezeStrategyDeposits_revertsIfNotAdmin() public {
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        vm.prank(guardian);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.unfreezeStrategyDeposits(IStrategy(address(strategyA)));
    }

    function test_unfreezeStrategyDeposits_revertsIfNotFrozen() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotDepositFrozen.selector);
        vault.unfreezeStrategyDeposits(IStrategy(address(strategyA)));
    }

    // ========== Rebalance skips frozen strategy deposits ==========

    function test_rebalance_skipsDepositToFrozenStrategy() public {
        // Deposit into vault
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Set allocations: A=50%, B=50%
        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 4_850;
        bps[1] = 4_850;

        // Rebalance normally first
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 balA = strategyA.balanceOf();
        uint256 balB = strategyB.balanceOf();
        assertGt(balA, 0);
        assertGt(balB, 0);

        // Freeze strategy A
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        // Deposit more to vault (adds to idle)
        vm.prank(alice);
        vault.deposit(5_000e6, alice);

        // Record strategy A balance before rebalance
        uint256 balABefore = strategyA.balanceOf();

        // Rebalance again - A should NOT receive more deposits
        vm.prank(keeper);
        vault.rebalance();

        // Strategy A balance should not increase
        assertEq(strategyA.balanceOf(), balABefore);
        // Strategy B should still receive deposits
        assertGt(strategyB.balanceOf(), balB);
    }

    function test_rebalance_stillWithdrawsFromFrozenStrategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 4_850;
        bps[1] = 4_850;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Freeze A and set allocation to 0
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        bps[0] = 0;
        bps[1] = 5000;

        // Rebalance should withdraw from frozen A (allocation is 0)
        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Strategy A should be emptied
        assertEq(strategyA.balanceOf(), 0);
    }

    // ========== totalAssets INCLUDES frozen strategies ==========

    function test_totalAssets_includesFrozenStrategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 4_850;
        bps[1] = 4_850;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 totalBefore = vault.totalAssets();

        // Freeze A - should NOT change totalAssets
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalBefore, totalAfter);
    }

    // ========== Withdrawal waterfall INCLUDES frozen strategies ==========

    function test_withdraw_pullsFromFrozenStrategy() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 4_850;
        bps[1] = 4_850;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Freeze A
        vm.prank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));

        // User can still withdraw from frozen strategy via waterfall
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0);

        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);

        assertGe(token.balanceOf(alice), maxW + 90_000e6); // initial 100k - 10k + maxW back
    }

    // ========== removeStrategy cleans up depositFrozen ==========

    function test_removeStrategy_clearsFrozenFlag() public {
        vm.startPrank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));

        vault.removeStrategy(IStrategy(address(strategyA)));
        assertFalse(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
        vm.stopPrank();
    }

    // ========== recallToIdle ==========

    function test_recallToIdle_withdrawsAndFreezes() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 totalBefore = vault.totalAssets();
        uint256 stratBalBefore = strategyA.balanceOf();
        assertGt(stratBalBefore, 0);

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        // Strategy should be empty
        assertEq(strategyA.balanceOf(), 0);
        // Vault tracked balance should be 0
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);
        // Allocation should be 0
        assertEq(vault.targetAllocationBps(IStrategy(address(strategyA))), 0);
        // Should be deposit-frozen
        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
        // Total assets unchanged (idle up, tracked down)
        assertEq(vault.totalAssets(), totalBefore);
    }

    function test_recallToIdle_emitsEvents() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        vm.expectEmit(true, false, false, false);
        emit TezoroV1_2.RecalledToIdle(address(strategyA), 0); // amount checked loosely

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));
    }

    function test_recallToIdle_revertsIfNotAdmin() public {
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.recallToIdle(IStrategy(address(strategyA)));
    }

    function test_recallToIdle_revertsIfNotActive() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.StrategyNotActive.selector);
        vault.recallToIdle(IStrategy(makeAddr("unknown")));
    }

    function test_recallToIdle_fallsBackToEmergencyWithdraw() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Make normal withdraw fail
        strategyA.setBroken(true);

        // recallToIdle should still work via emergencyWithdraw fallback
        // (emergencyWithdraw doesn't check broken flag in our mock — let's add a separate test)
        // For this test, we need a strategy where withdraw fails but emergencyWithdraw works.
        // Our mock's emergencyWithdraw doesn't check broken, so it should work.
        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        assertEq(strategyA.balanceOf(), 0);
    }

    function test_recallToIdle_idempotentOnAlreadyFrozen() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Freeze first, then recall
        vm.startPrank(admin);
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
        vault.recallToIdle(IStrategy(address(strategyA)));
        vm.stopPrank();

        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
        assertEq(strategyA.balanceOf(), 0);
    }

    function test_recallToIdle_noopIfZeroBalance() public {
        // No deposits, strategy balance is 0
        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
        assertEq(vault.targetAllocationBps(IStrategy(address(strategyA))), 0);
    }

    // ========== forceRedeem ==========

    function test_forceRedeem_sendsAssetsToUser() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 aliceBalBefore = token.balanceOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0);

        vm.prank(admin);
        vault.forceRedeem(alice);

        // Alice should have no shares
        assertEq(vault.balanceOf(alice), 0);
        // Alice should have received her assets back
        assertGt(token.balanceOf(alice), aliceBalBefore);
    }

    function test_forceRedeem_emitsEvent() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.expectEmit(true, false, false, false);
        emit TezoroV1_2.ForceRedeemed(alice, 0, 0); // loose match

        vm.prank(admin);
        vault.forceRedeem(alice);
    }

    function test_forceRedeem_worksWithStrategies() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(admin);
        vault.forceRedeem(alice);

        assertEq(vault.balanceOf(alice), 0);
        // Alice got ~10k back (minus rounding)
        assertGt(token.balanceOf(alice) - aliceBalBefore, 9_900e6);
    }

    function test_forceRedeem_revertsIfNoShares() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.NoSharesToRedeem.selector);
        vault.forceRedeem(alice);
    }

    function test_forceRedeem_revertsIfNotAdmin() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.forceRedeem(alice);
    }

    function test_forceRedeem_sendsToUserNotAdmin() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 adminBalBefore = token.balanceOf(admin);

        vm.prank(admin);
        vault.forceRedeem(alice);

        // Admin balance should NOT increase
        assertEq(token.balanceOf(admin), adminBalBefore);
        // Alice should have her assets
        assertGt(token.balanceOf(alice), 90_000e6);
    }

    // ========== batchForceRedeem ==========

    function test_batchForceRedeem_multipleUsers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        uint256 aliceBalBefore = token.balanceOf(alice);
        uint256 bobBalBefore = token.balanceOf(bob);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        vault.batchForceRedeem(users);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
        assertGt(token.balanceOf(alice), aliceBalBefore);
        assertGt(token.balanceOf(bob), bobBalBefore);
    }

    function test_batchForceRedeem_skipsZeroShareUsers() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Bob has no shares
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        vault.batchForceRedeem(users);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_batchForceRedeem_revertsIfAllZeroShares() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.NoSharesToRedeem.selector);
        vault.batchForceRedeem(users);
    }

    function test_batchForceRedeem_revertsIfEmptyList() public {
        address[] memory users = new address[](0);

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.EmptyUserList.selector);
        vault.batchForceRedeem(users);
    }

    function test_batchForceRedeem_revertsIfTooMany() public {
        address[] memory users = new address[](51);
        for (uint256 i = 0; i < 51; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
        }

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.BatchTooLarge.selector);
        vault.batchForceRedeem(users);
    }

    function test_batchForceRedeem_revertsIfNotAdmin() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.batchForceRedeem(users);
    }

    // ========== recallToIdle: RecallFailed ==========

    function test_recallToIdle_emitsRecallFailed_whenBothWithdrawsFail() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 9700;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 tracked = vault.trackedBalance(IStrategy(address(strategyA)));
        assertGt(tracked, 0);

        // Make BOTH withdraw paths fail
        strategyA.setFullyBroken(true);

        vm.expectEmit(true, false, false, true);
        emit TezoroV1_2.RecallFailed(address(strategyA), tracked);

        vm.prank(admin);
        vault.recallToIdle(IStrategy(address(strategyA)));

        // Tracked balance should NOT change (funds still stuck in strategy)
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), tracked);
        // But allocation is 0 and deposits are frozen
        assertEq(vault.targetAllocationBps(IStrategy(address(strategyA))), 0);
        assertTrue(vault.depositFrozenStrategies(IStrategy(address(strategyA))));
    }

    // ========== forceRedeem: Timelock enforcement ==========

    function test_forceRedeem_worksWithoutTimelock() public {
        // timelockDelay = 0 (default) — forceRedeem works immediately
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(admin);
        vault.forceRedeem(alice);

        assertEq(vault.balanceOf(alice), 0);
    }

    function test_forceRedeem_revertsWithoutProposal_whenTimelockActive() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        // Enable timelock
        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.forceRedeem(alice);
    }

    function test_forceRedeem_revertsIfTimelockNotReady() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.startPrank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("forceRedeem", alice));
        vault.proposeTimelock(opHash);

        // Try immediately — not ready yet
        vm.expectRevert(TezoroV1_2.TimelockNotReady.selector);
        vault.forceRedeem(alice);
        vm.stopPrank();
    }

    function test_forceRedeem_worksAfterTimelockExpires() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.startPrank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("forceRedeem", alice));
        vault.proposeTimelock(opHash);

        // Warp past delay
        vm.warp(block.timestamp + 1 days + 1);

        vault.forceRedeem(alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
    }

    function test_forceRedeem_revertsIfTimelockAlreadyExecuted() public {
        vm.prank(alice);
        vault.deposit(5_000e6, alice);
        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        vm.startPrank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("forceRedeem", alice));
        vault.proposeTimelock(opHash);

        vm.warp(block.timestamp + 1 days + 1);
        vault.forceRedeem(alice);

        // Alice deposits again
        vm.stopPrank();
        token.mint(alice, 5_000e6);
        vm.prank(alice);
        vault.deposit(5_000e6, alice);

        // Try to replay the same proposal
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockAlreadyExecuted.selector);
        vault.forceRedeem(alice);
    }

    // ========== batchForceRedeem: Timelock enforcement ==========

    function test_batchForceRedeem_revertsWithoutProposal_whenTimelockActive() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.prank(admin);
        vault.setTimelockDelay(1 days);

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.TimelockNotFound.selector);
        vault.batchForceRedeem(users);
    }

    function test_batchForceRedeem_worksAfterTimelockExpires() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(bob);
        vault.deposit(5_000e6, bob);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.startPrank(admin);
        vault.setTimelockDelay(1 days);

        bytes32 opHash = keccak256(abi.encode("batchForceRedeem", users));
        vault.proposeTimelock(opHash);

        vm.warp(block.timestamp + 1 days + 1);
        vault.batchForceRedeem(users);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    // ========== Interaction: frozen + full pause ==========

    function test_fullPauseTakesPrecedenceOverDepositFreeze() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = IStrategy(address(strategyA));
        uint256[] memory bps = new uint256[](1);
        bps[0] = 5000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Full-pause strategy A
        vm.startPrank(admin);
        vault.pauseStrategy(IStrategy(address(strategyA)));
        vault.freezeStrategyDeposits(IStrategy(address(strategyA)));
        vm.stopPrank();

        // totalAssets EXCLUDES full-paused strategy (even if deposit-frozen)
        uint256 total = vault.totalAssets();
        // Should be less than 10k because strategy A is fully paused
        assertLt(total, 10_000e6);
    }
}
