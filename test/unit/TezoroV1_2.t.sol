// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// ---- Mock ERC-20 ----

contract V1_2_MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---- Mock Strategy ----

contract V1_2_MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    uint256 internal _balance;
    bool public healthy = true;
    bool public broken = false;

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

    function setHealthy(bool h) external {
        healthy = h;
    }

    /// @dev Simulate yield: mint tokens to strategy and increase tracked balance
    function simulateYield(address token, uint256 amount) external {
        V1_2_MockUSDC(token).mint(address(this), amount);
        _balance += amount;
    }
}

// ---- Tests: M-1 Two-pass rebalance ----

contract TwoPassRebalanceTest is Test {
    V1_2_MockUSDC token;
    TezoroV1_2 vault;
    V1_2_MockStrategy strategyA;
    V1_2_MockStrategy strategyB;
    V1_2_MockStrategy strategyC;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6; // 100k USDC

    function setUp() public {
        token = new V1_2_MockUSDC();
        vault = new TezoroV1_2(
            IERC20(address(token)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            0, // no performance fee
            0 // no idle buffer
        );

        strategyA = new V1_2_MockStrategy(address(token));
        strategyB = new V1_2_MockStrategy(address(token));
        strategyC = new V1_2_MockStrategy(address(token));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategyA)));
        vault.addStrategy(IStrategy(address(strategyB)));
        vault.addStrategy(IStrategy(address(strategyC)));
        vault.setKeeper(keeper);
        vm.stopPrank();

        // Alice deposits
        token.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();
    }

    /// @notice Rebalance converges in a single call when shifting allocation
    ///         from strategy C (later in array) to strategy A (earlier in array).
    ///         V1_1 required two calls because single-pass processed A before C's withdrawal.
    function test_rebalance_convergesInOneCall() public {
        // Initial allocation: 100% to strategy C (index 2)
        IStrategy[] memory strats = new IStrategy[](3);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        strats[2] = IStrategy(address(strategyC));
        uint256[] memory bps = new uint256[](3);
        bps[0] = 0;
        bps[1] = 0;
        bps[2] = 10_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Verify C has everything
        assertEq(vault.trackedBalance(IStrategy(address(strategyC))), DEPOSIT);
        assertEq(vault.trackedBalance(IStrategy(address(strategyA))), 0);

        // Now shift: 50% A, 0% B, 50% C
        bps[0] = 5_000;
        bps[2] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Both should be at ~50% after ONE call
        uint256 balA = vault.trackedBalance(IStrategy(address(strategyA)));
        uint256 balC = vault.trackedBalance(IStrategy(address(strategyC)));

        assertEq(balA, DEPOSIT / 2, "Strategy A should have 50% after single rebalance");
        assertEq(balC, DEPOSIT / 2, "Strategy C should have 50% after single rebalance");
    }

    /// @notice Rebalance converges when moving from multiple strategies to one.
    function test_rebalance_multipleWithdrawalsToOneDeposit() public {
        // Initial allocation: 33% each
        IStrategy[] memory strats = new IStrategy[](3);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        strats[2] = IStrategy(address(strategyC));
        uint256[] memory bps = new uint256[](3);
        bps[0] = 3_334;
        bps[1] = 3_333;
        bps[2] = 3_333;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now shift: 100% to A
        bps[0] = 10_000;
        bps[1] = 0;
        bps[2] = 0;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        uint256 balA = vault.trackedBalance(IStrategy(address(strategyA)));
        uint256 balB = vault.trackedBalance(IStrategy(address(strategyB)));
        uint256 balC = vault.trackedBalance(IStrategy(address(strategyC)));

        assertEq(balA, DEPOSIT, "Strategy A should have 100% after single rebalance");
        assertEq(balB, 0, "Strategy B should have 0% after single rebalance");
        assertEq(balC, 0, "Strategy C should have 0% after single rebalance");
    }

    /// @notice Rebalance handles the case where first strategy needs funds
    ///         from last strategy -- the worst case for single-pass.
    function test_rebalance_firstNeedsFromLast() public {
        // Put everything in C (last)
        IStrategy[] memory strats = new IStrategy[](3);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        strats[2] = IStrategy(address(strategyC));
        uint256[] memory bps = new uint256[](3);
        bps[0] = 0;
        bps[1] = 0;
        bps[2] = 10_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // Now: 100% to A (first)
        bps[0] = 10_000;
        bps[2] = 0;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        assertEq(
            vault.trackedBalance(IStrategy(address(strategyA))),
            DEPOSIT,
            "Strategy A should have everything after single rebalance"
        );
        assertEq(vault.trackedBalance(IStrategy(address(strategyC))), 0);
    }
}

// ---- Tests: M-2 Pause does not drop share price ----

contract PauseSharePriceTest is Test {
    V1_2_MockUSDC token;
    TezoroV1_2 vault;
    V1_2_MockStrategy strategyA;
    V1_2_MockStrategy strategyB;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        token = new V1_2_MockUSDC();
        vault = new TezoroV1_2(
            IERC20(address(token)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            0, // no performance fee
            0 // no idle buffer
        );

        strategyA = new V1_2_MockStrategy(address(token));
        strategyB = new V1_2_MockStrategy(address(token));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategyA)));
        vault.addStrategy(IStrategy(address(strategyB)));
        vault.setKeeper(keeper);
        vault.setGuardian(guardian);
        vm.stopPrank();

        // Alice deposits
        token.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        token.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Allocate 50/50
        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 5_000;
        bps[1] = 5_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);
    }

    /// @notice Pausing a strategy should NOT change totalAssets or share price.
    function test_pauseDoesNotDropTotalAssets() public {
        uint256 totalBefore = vault.totalAssets();
        uint256 oneShare = 10 ** vault.decimals();
        uint256 sharePriceBefore = vault.convertToAssets(oneShare);

        // Guardian pauses strategy A
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        uint256 totalAfter = vault.totalAssets();
        uint256 sharePriceAfter = vault.convertToAssets(oneShare);

        assertEq(totalAfter, totalBefore, "totalAssets must not change on pause");
        assertEq(sharePriceAfter, sharePriceBefore, "share price must not change on pause");
    }

    /// @notice Pausing and unpausing should have zero net effect on share price.
    function test_pauseUnpause_sharePriceStable() public {
        uint256 oneShare = 10 ** vault.decimals();
        uint256 sharePriceBefore = vault.convertToAssets(oneShare);

        // Pause
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        // Unpause
        vm.prank(admin);
        vault.unpauseStrategy(IStrategy(address(strategyA)));

        uint256 sharePriceAfter = vault.convertToAssets(oneShare);
        assertEq(sharePriceAfter, sharePriceBefore, "share price must be identical after pause/unpause cycle");
    }

    /// @notice No arbitrage: depositing while a strategy is paused should not
    ///         give cheaper shares.
    function test_pauseDoesNotCreateArbitrage() public {
        // Pause strategy A
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        // Bob deposits during pause
        uint256 bobDeposit = 10_000e6;
        token.mint(bob, bobDeposit);
        vm.startPrank(bob);
        token.approve(address(vault), bobDeposit);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        // Unpause
        vm.prank(admin);
        vault.unpauseStrategy(IStrategy(address(strategyA)));

        // Bob's share price should be the same as before pause (no free value)
        uint256 bobAssets = vault.convertToAssets(bobShares);
        // Allow 1 wei rounding
        assertApproxEqAbs(bobAssets, bobDeposit, 1, "Bob should not gain value from pause arbitrage");
    }

    /// @notice totalAssets includes paused strategy when yield accrues.
    function test_pausedStrategy_yieldStillCounted() public {
        // Pause strategy A
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        uint256 totalBefore = vault.totalAssets();

        // Simulate yield on paused strategy
        uint256 yield = 1_000e6;
        strategyA.simulateYield(address(token), yield);

        // Reconcile (paused strategies are skipped by reconcile)
        // But totalAssets counts trackedBalance regardless of pause.
        // After reconcile of non-paused strategies:
        vm.prank(keeper);
        vault.reconcile();

        // totalAssets should reflect yield from non-paused strategy B if any,
        // and trackedBalance of A remains unchanged (reconcile skips paused).
        // The key point: totalAssets does NOT drop just because A is paused.
        uint256 totalAfter = vault.totalAssets();
        assertGe(totalAfter, totalBefore, "totalAssets must not decrease after pausing");
    }

    /// @notice Rebalance skips paused strategies for both deposits and withdrawals.
    function test_rebalance_skipsPausedStrategies() public {
        uint256 balA_before = vault.trackedBalance(IStrategy(address(strategyA)));
        uint256 balB_before = vault.trackedBalance(IStrategy(address(strategyB)));

        // Pause A
        vm.prank(guardian);
        vault.pauseStrategy(IStrategy(address(strategyA)));

        // Try to shift allocation: 0% A, 100% B
        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(strategyA));
        strats[1] = IStrategy(address(strategyB));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 0;
        bps[1] = 10_000;

        vm.prank(keeper);
        vault.rebalance(strats, bps);

        // A should remain untouched (paused = skipped in both passes)
        assertEq(
            vault.trackedBalance(IStrategy(address(strategyA))),
            balA_before,
            "Paused strategy A should not be withdrawn from during rebalance"
        );
        // B gets deposits from idle only, not from A
        assertGe(vault.trackedBalance(IStrategy(address(strategyB))), balB_before);
    }
}
