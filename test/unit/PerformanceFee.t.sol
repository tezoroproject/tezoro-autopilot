// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

// ---- Mock ERC-20 ----

contract PerfFeeUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---- Mock Strategy (supports yield injection) ----

contract PerfFeeStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    uint256 internal _balance;

    constructor(address asset_) {
        asset = asset_;
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

    function harvest(address) external pure override returns (uint256) {
        return 0;
    }

    function sweepReward(address, address) external pure override returns (uint256) {
        return 0;
    }

    /// @dev Simulate yield: mint tokens to strategy and increase tracked balance
    function simulateYield(uint256 amount) external {
        PerfFeeUSDC(asset).mint(address(this), amount);
        _balance += amount;
    }
}

// ---- Tests ----

contract PerformanceFeeTest is Test {
    PerfFeeUSDC token;
    TezoroV1_2 vault;
    PerfFeeStrategy strategy;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 100_000e6; // 100k USDC

    function setUp() public {
        token = new PerfFeeUSDC();
        vault = new TezoroV1_2(
            IERC20(address(token)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            1_500, // 15% performance fee
            300 // 3% idle buffer
        );

        strategy = new PerfFeeStrategy(address(token));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
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

    function _generateYield(uint256 amount) internal {
        strategy.simulateYield(amount);
        vm.prank(keeper);
        vault.reconcile();
    }

    // =========================================================================
    // Fee accrued on withdraw — user can't dodge
    // =========================================================================

    function test_withdrawAccruesPerformanceFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6); // 10% yield

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // Alice withdraws — should trigger fee accrual
        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares should be minted on withdraw");
    }

    // =========================================================================
    // Fee accrued on redeem — same behavior
    // =========================================================================

    function test_redeemAccruesPerformanceFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        uint256 shares = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares should be minted on redeem");
    }

    // =========================================================================
    // Fee accrued on forceRedeem
    // =========================================================================

    function test_forceRedeemAccruesPerformanceFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(admin);
        vault.forceRedeem(alice);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares should be minted on forceRedeem");
    }

    // =========================================================================
    // Fee accrued on batchForceRedeem
    // =========================================================================

    function test_batchForceRedeemAccruesPerformanceFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _depositAndAllocate(bob, DEPOSIT);
        _generateYield(20_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(admin);
        vault.batchForceRedeem(users);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares should be minted on batchForceRedeem");
    }

    // =========================================================================
    // collectFees() explicit collection
    // =========================================================================

    function test_collectFeesExplicit() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(keeper);
        vault.collectFees();

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "collectFees should mint fee shares");
    }

    // =========================================================================
    // No double-counting: withdraw accrues -> immediate collectFees is no-op
    // =========================================================================

    function test_noDoubleCountAfterWithdraw() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        // Withdraw accrues fee
        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);

        uint256 feeSharesAfterWithdraw = vault.balanceOf(feeRecipient);

        // collectFees immediately after — should be no-op (HWM already updated)
        vm.prank(keeper);
        vault.collectFees();

        uint256 feeSharesAfterCollect = vault.balanceOf(feeRecipient);
        assertEq(feeSharesAfterCollect, feeSharesAfterWithdraw, "No double-counting");
    }

    // =========================================================================
    // HWM only goes up, never down
    // =========================================================================

    function test_hwmOnlyGoesUp() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 hwm1 = vault.highWaterMark();

        // Generate yield -> collect fees -> HWM goes up
        _generateYield(5_000e6);
        vm.prank(keeper);
        vault.collectFees();

        uint256 hwm2 = vault.highWaterMark();
        assertGt(hwm2, hwm1, "HWM should increase after yield");

        // More yield -> collect again -> HWM goes up further
        _generateYield(3_000e6);
        vm.prank(keeper);
        vault.collectFees();

        uint256 hwm3 = vault.highWaterMark();
        assertGt(hwm3, hwm2, "HWM should increase again");
    }

    // =========================================================================
    // No fee when share price below HWM
    // =========================================================================

    function test_noFeeWhenBelowHwm() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        // Collect fees — sets HWM high
        vm.prank(keeper);
        vault.collectFees();

        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);

        // No additional yield — collectFees should be no-op
        vm.prank(keeper);
        vault.collectFees();

        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst, "No fee when share price hasn't grown");
    }

    // =========================================================================
    // Fee is 0 when performanceFeeBps == 0
    // =========================================================================

    function test_noFeeWhenBpsIsZero() public {
        vm.prank(admin);
        vault.setPerformanceFee(0);

        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);

        vm.prank(keeper);
        vault.collectFees();

        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore, "No fee shares when fee is 0");
    }

    // =========================================================================
    // setPerformanceFee accrues at old rate before changing
    // =========================================================================

    function test_setPerformanceFeeAccruesAtOldRate() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // Change fee rate — should accrue at old 15% rate first
        vm.prank(admin);
        vault.setPerformanceFee(500); // drop to 5%

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore, "Should accrue at old rate before changing");
    }

    // =========================================================================
    // PerformanceFeeCollected event emitted by collectFees
    // =========================================================================

    function test_collectFeesEmitsEvent() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        vm.prank(keeper);
        vm.expectEmit(false, false, false, false);
        emit TezoroV1_2.PerformanceFeeCollected(0, feeRecipient);
        vault.collectFees();
    }

    // =========================================================================
    // Performance fee amount is approximately correct (15% of gain)
    // =========================================================================

    function test_feeAmountApproximatelyCorrect() public {
        _depositAndAllocate(alice, DEPOSIT);

        uint256 yield_ = 10_000e6; // 10% yield
        _generateYield(yield_);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(keeper);
        vault.collectFees();

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        uint256 feeAssets = vault.convertToAssets(feeSharesAfter - feeSharesBefore);

        // Expected: 10% yield * 15% fee = 1.5% of total = 1,500 USDC
        uint256 expectedFee = yield_ * 1_500 / 10_000;
        assertApproxEqRel(feeAssets, expectedFee, 0.02e18, "Fee should be ~15% of yield");
    }

    // =========================================================================
    // FEAR MITIGATION: Fee is 15% of PROFIT, not 15% of capital
    // =========================================================================

    /// @notice Prove that after yield + fee collection, user gets back their
    ///         full principal plus 85% of yield (fee is only on profit).
    ///         This directly addresses the fear: "will they take 15% of my
    ///         entire balance instead of 15% of just the profit?"
    function test_feeIsOnlyOnProfit_userGetsPrincipalBack() public {
        uint256 principal = DEPOSIT; // 100,000 USDC
        _depositAndAllocate(alice, principal);

        uint256 yield_ = 10_000e6; // 10,000 USDC yield (10%)
        _generateYield(yield_);

        // Alice redeems everything (triggers fee accrual internally)
        // Use maxRedeem to account for fee-dilution during redeem
        uint256 redeemable = vault.maxRedeem(alice);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);
        uint256 received = token.balanceOf(alice) - balanceBefore;

        // Alice should get: principal + yield - fee
        // Fee = 15% of 10,000 = 1,500 USDC
        // So Alice receives ~108,500 USDC
        uint256 expectedFee = yield_ * 1_500 / 10_000; // 1,500 USDC
        uint256 expectedReceived = principal + yield_ - expectedFee;

        // Alice MUST get her full principal back (100,000+)
        assertGe(received, principal, "User must get at least their principal back");

        // Alice's received amount should match expected (within 2%)
        assertApproxEqRel(
            received, expectedReceived, 0.02e18, "User gets principal + 85% of yield"
        );

        // Fee recipient redeems their shares
        uint256 feeShares = vault.maxRedeem(feeRecipient);
        assertGt(feeShares, 0, "Fee recipient must have shares");
        uint256 feeBalanceBefore = token.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.redeem(feeShares, feeRecipient, feeRecipient);
        uint256 feeReceived = token.balanceOf(feeRecipient) - feeBalanceBefore;

        // Fee received should be ~15% of yield, NOT 15% of (principal + yield)
        assertApproxEqRel(
            feeReceived, expectedFee, 0.02e18, "Fee is 15% of yield only"
        );
        // Fee must NOT be 15% of total balance
        uint256 wrongFee = (principal + yield_) * 1_500 / 10_000; // 16,500 USDC
        assertLt(feeReceived, wrongFee / 2, "Fee must NOT be 15% of total capital");
    }

    /// @notice With zero yield, fee must be exactly zero. User gets 100% back.
    function test_zeroYield_zeroFee_fullPrincipalReturned() public {
        uint256 principal = DEPOSIT;
        _depositAndAllocate(alice, principal);

        // No yield generated. Collect fees — should be no-op.
        vm.prank(keeper);
        vault.collectFees();
        assertEq(vault.balanceOf(feeRecipient), 0, "Zero yield -> zero fee shares");

        // Alice withdraws everything (use maxRedeem for ERC-4626 compliance)
        uint256 redeemable = vault.maxRedeem(alice);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);
        uint256 received = token.balanceOf(alice) - balanceBefore;

        // Must get 100% principal back (within rounding tolerance)
        assertApproxEqAbs(received, principal, 2, "Zero yield: user gets full principal");
    }

    /// @notice Multiple yield cycles: HWM ensures no double-counting.
    ///         User still gets principal + majority of yield.
    ///         With post-mint HWM, the fee is exactly 15% of actual per-share gains
    ///         (measured from post-dilution price), which across multiple cycles is
    ///         slightly more than 15% of raw yield due to compounding. This is correct:
    ///         each cycle's fee base includes the recovery from the previous cycle's dilution.
    function test_feeOnlyOnIncrementalProfit_multipleYieldCycles() public {
        uint256 principal = DEPOSIT;
        _depositAndAllocate(alice, principal);

        uint256 totalYield = 0;

        // Cycle 1: 5% yield
        _generateYield(5_000e6);
        totalYield += 5_000e6;
        vm.prank(keeper);
        vault.collectFees();

        uint256 hwmAfterCycle1 = vault.highWaterMark();

        // Cycle 2: another 5% yield
        _generateYield(5_000e6);
        totalYield += 5_000e6;
        vm.prank(keeper);
        vault.collectFees();

        uint256 hwmAfterCycle2 = vault.highWaterMark();

        // HWM must increase each cycle (no double-counting)
        assertGt(hwmAfterCycle2, hwmAfterCycle1, "HWM increases across cycles");

        // User redeems everything
        uint256 redeemable = vault.maxRedeem(alice);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemable, alice, alice);
        uint256 received = token.balanceOf(alice) - balanceBefore;

        // User must get full principal back
        assertGe(received, principal, "User gets principal back after multi-cycle");

        // Fee is ~15% of actual per-share gains. Across 2 cycles with post-mint HWM,
        // this is slightly above 15% of raw yield (compounding effect: ~1-2% overshoot).
        uint256 nominalFee = totalYield * 1_500 / 10_000;
        uint256 actualFeeImplied = principal + totalYield - received;
        assertApproxEqRel(
            actualFeeImplied, nominalFee, 0.03e18,
            "Fee is approximately 15% of total yield"
        );

        // Fee must NOT be based on total capital
        uint256 wrongFee = (principal + totalYield) * 1_500 / 10_000;
        assertLt(actualFeeImplied, wrongFee / 2, "Fee is not 15% of total capital");
    }

    // =========================================================================
    // FEAR MITIGATION: Fee recipient wallet access & immutability
    // =========================================================================

    /// @notice Only admin can change feeRecipient. Keeper, users, strangers cannot.
    function test_setFeeRecipient_onlyAdmin() public {
        address newRecipient = makeAddr("newRecipient");

        // Keeper cannot change feeRecipient
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setFeeRecipient(newRecipient);

        // Random user cannot change feeRecipient
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setFeeRecipient(newRecipient);

        // Admin CAN change feeRecipient
        vm.prank(admin);
        vault.setFeeRecipient(newRecipient);
        assertEq(vault.feeRecipient(), newRecipient, "Admin changed feeRecipient");
    }

    /// @notice feeRecipient cannot be set to zero address (funds would be lost)
    function test_setFeeRecipient_cannotBeZero() public {
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    /// @notice feeRecipient can redeem their fee shares for real tokens
    function test_feeRecipient_canRedeemShares() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        vm.prank(keeper);
        vault.collectFees();

        uint256 feeShares = vault.balanceOf(feeRecipient);
        assertGt(feeShares, 0, "Fee recipient has shares");

        // Fee recipient redeems — must get real USDC
        uint256 balanceBefore = token.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.redeem(feeShares, feeRecipient, feeRecipient);
        uint256 received = token.balanceOf(feeRecipient) - balanceBefore;

        assertGt(received, 0, "Fee recipient redeems for real tokens");
        assertEq(vault.balanceOf(feeRecipient), 0, "All fee shares redeemed");
    }

    /// @notice After feeRecipient is changed, new fees go to the new address,
    ///         and old recipient retains already-minted shares.
    function test_feeRecipient_change_preservesOldShares() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(5_000e6);

        vm.prank(keeper);
        vault.collectFees();
        uint256 oldRecipientShares = vault.balanceOf(feeRecipient);
        assertGt(oldRecipientShares, 0, "Old recipient has shares from first yield");

        // Admin changes fee recipient
        address newRecipient = makeAddr("newFeeWallet");
        vm.prank(admin);
        vault.setFeeRecipient(newRecipient);

        // Generate more yield
        _generateYield(5_000e6);
        vm.prank(keeper);
        vault.collectFees();

        // Old recipient still has their shares
        assertEq(
            vault.balanceOf(feeRecipient),
            oldRecipientShares,
            "Old recipient shares unchanged"
        );
        // New recipient got the new fees
        assertGt(vault.balanceOf(newRecipient), 0, "New recipient got new fees");
    }

    /// @notice Only admin can change performanceFee. Cannot exceed 30% cap.
    function test_setPerformanceFee_accessControl() public {
        // Keeper cannot change fee
        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setPerformanceFee(2_000);

        // Random user cannot change fee
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setPerformanceFee(2_000);

        // Cannot exceed MAX_PERFORMANCE_FEE_BPS (30%)
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.InvalidFee.selector);
        vault.setPerformanceFee(3_001);

        // Admin CAN set within cap
        vm.prank(admin);
        vault.setPerformanceFee(2_000);
        assertEq(vault.performanceFeeBps(), 2_000, "Fee updated to 20%");
    }

    // =========================================================================
    // FIX VALIDATION: New depositor must NOT be charged for pre-deposit gains
    // =========================================================================

    /// @notice A new depositor who enters AFTER yield was generated should not
    ///         subsidize the performance fee on gains they never received.
    ///
    ///         Bug (before fix): deposit() did NOT call _accruePerformanceFee().
    ///         When the next fee collection happened it used the enlarged totalShares
    ///         (including Bob's), causing Bob to pay part of the fee on Alice's gains.
    ///
    ///         Fix: deposit()/mint() call _accruePerformanceFee() first. Fee is
    ///         settled at the old totalShares; Bob enters at the post-fee share price.
    function test_newDepositor_notChargedForPreDepositGains() public {
        uint256 alicePrincipal = DEPOSIT; // 100k USDC
        _depositAndAllocate(alice, alicePrincipal);

        uint256 yield_ = 10_000e6; // $10k yield → 10%
        _generateYield(yield_);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        // Bob deposits AFTER yield was generated, HWM not yet updated
        uint256 bobPrincipal = DEPOSIT;
        vm.prank(bob);
        vault.deposit(bobPrincipal, bob);

        // Trigger any remaining fee collection
        vm.prank(keeper);
        vault.collectFees();

        // Total fee must equal 15% of the $10k yield that happened BEFORE Bob's deposit.
        // Before fix: fee used enlarged totalShares → collected ~$2,863 instead of $1,500.
        uint256 newFeeShares = vault.balanceOf(feeRecipient) - feeRecipientSharesBefore;
        uint256 feeAssets = vault.convertToAssets(newFeeShares);
        uint256 expectedFee = yield_ * 1_500 / 10_000; // 15% of $10k = $1,500
        assertApproxEqRel(feeAssets, expectedFee, 0.02e18, "Fee must be 15% of pre-deposit yield only");

        // Bob's current value must be approximately his deposit (no gains yet, not diluted by pre-deposit fee)
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqRel(bobValue, bobPrincipal, 0.005e18, "Bob's value must be approx his deposit amount");
    }

    /// @notice Verify deposit() triggers fee accrual by checking the event is emitted.
    function test_deposit_accruesFeeWhenAboveHwm() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        // Bob deposits — should trigger PerformanceFeeCollected
        vm.prank(bob);
        vm.expectEmit(false, false, false, false);
        emit TezoroV1_2.PerformanceFeeCollected(0, feeRecipient);
        vault.deposit(DEPOSIT, bob);
    }

    /// @notice Verify mint() triggers fee accrual by checking the event is emitted.
    function test_mint_accruesFeeWhenAboveHwm() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        // Shares equivalent to ~50k USDC at current price. Vault decimals = 12
        // (USDC 6 + _decimalsOffset 6), so shares are O(1e16), NOT 1e18.
        uint256 mintShares = vault.previewDeposit(50_000e6);

        vm.prank(bob);
        vm.expectEmit(false, false, false, false);
        emit TezoroV1_2.PerformanceFeeCollected(0, feeRecipient);
        vault.mint(mintShares, bob);
    }

    /// @notice Two deposits in a row: second deposit produces no double-counting.
    ///         After first deposit accrues fee and updates HWM, second deposit
    ///         should NOT emit another PerformanceFeeCollected (HWM already current).
    function test_secondDeposit_noDoubleFeeAccrual() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // First deposit: accrues fee
        vm.prank(bob);
        vault.deposit(DEPOSIT / 2, bob);

        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfterFirst, feeSharesBefore, "First deposit must accrue fee");

        // Second deposit in same state: HWM is already at current price, no more fee
        vm.prank(bob);
        vault.deposit(DEPOSIT / 2, bob);

        uint256 feeSharesAfterSecond = vault.balanceOf(feeRecipient);
        assertEq(feeSharesAfterSecond, feeSharesAfterFirst, "Second deposit must not double-count fee");
    }

    // =========================================================================
    // FIX VALIDATION: previewDeposit / previewMint must match actual
    // =========================================================================

    /// @notice ERC-4626 invariant: previewDeposit(assets) MUST equal the actual
    ///         number of shares returned by deposit(assets).
    ///
    ///         Before fix: previewDeposit used OZ default (no pending fee),
    ///         but deposit() now accrues fees first (larger totalSupply after fee),
    ///         so actual shares < previewDeposit → invariant violated.
    ///
    ///         After fix: previewDeposit accounts for _pendingFeeShares().
    function test_previewDeposit_matchesActual_withPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6); // Share price above HWM — fee is pending

        uint256 depositAmount = 50_000e6;
        uint256 preview = vault.previewDeposit(depositAmount);

        vm.prank(bob);
        uint256 actual = vault.deposit(depositAmount, bob);

        assertEq(actual, preview, "previewDeposit must equal actual shares (ERC-4626 invariant)");
    }

    /// @notice ERC-4626 invariant: previewMint(shares) MUST equal the actual
    ///         amount of assets pulled by mint(shares).
    ///
    ///         Same reasoning as previewDeposit — pending fee enlarges totalSupply,
    ///         making each share more expensive. Preview must account for this.
    function test_previewMint_matchesActual_withPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6); // Share price above HWM — fee is pending

        // Shares equivalent to ~50k USDC at current price. Vault decimals = 12
        // (USDC 6 + _decimalsOffset 6), so shares are O(1e16), NOT 1e18.
        uint256 mintShares = vault.previewDeposit(50_000e6);
        uint256 preview = vault.previewMint(mintShares);

        uint256 balanceBefore = token.balanceOf(bob);
        vm.prank(bob);
        vault.mint(mintShares, bob);
        uint256 actualAssetsSpent = balanceBefore - token.balanceOf(bob);

        assertEq(actualAssetsSpent, preview, "previewMint must equal actual assets (ERC-4626 invariant)");
    }

    /// @notice previewDeposit must be accurate when there is NO pending fee (HWM current).
    ///         This ensures the fix doesn't break the normal (no-pending-fee) case.
    function test_previewDeposit_accurate_whenNoPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);

        // Collect fees so HWM is current (no pending fee)
        vm.prank(keeper);
        vault.collectFees();

        uint256 depositAmount = 50_000e6;
        uint256 preview = vault.previewDeposit(depositAmount);

        vm.prank(bob);
        uint256 actual = vault.deposit(depositAmount, bob);

        assertEq(actual, preview, "previewDeposit must match when no pending fee");
    }

    // =========================================================================
    // FIX VALIDATION: fee fairness across multiple periods
    // =========================================================================

    /// @notice Prove that fees across two yield periods are correctly allocated:
    ///         - Alice is charged for period 1 (she was the only depositor)
    ///         - Alice AND Bob share the fee for period 2 (both deposited before period 2 yield)
    ///         - Bob gets ZERO gains from period 1 (he joined after it was settled)
    ///
    ///         HWM is set to the post-dilution share price after fee mint. This means
    ///         period 2's fee is measured from the actual per-share value — no untaxed gap.
    function test_feeFairness_twoYieldPeriods() public {
        uint256 principal = DEPOSIT; // $100k each

        // Period 1: only Alice
        _depositAndAllocate(alice, principal);
        _generateYield(10_000e6); // $10k yield

        vm.prank(keeper);
        vault.collectFees(); // HWM updated (post-dilution) — settles period 1

        uint256 feesAfterPeriod1 = vault.convertToAssets(vault.balanceOf(feeRecipient));
        uint256 expectedFee1 = 10_000e6 * 1_500 / 10_000; // $1,500
        assertApproxEqRel(feesAfterPeriod1, expectedFee1, 0.02e18, "Period 1 fee is 15% of $10k");

        // Bob joins after period 1 is settled (no pending fee at this point)
        vm.prank(bob);
        vault.deposit(principal, bob);

        // Period 2: both Alice and Bob present
        _generateYield(10_000e6); // another $10k yield

        vm.prank(keeper);
        vault.collectFees();

        // Bob's value should reflect only period 2 gains (minus his portion of period 2 fee).
        // Period 2 gross yield is $10k on a ~$210k vault; Bob holds ~47.6% of shares,
        // so Bob's gross gain ≈ $4,762. His share of the period 2 fee ≈ 15% of his gain.
        // Net ≈ 50% of $10k × (1 - 15%) = $4,250.
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        uint256 bobExpected = principal + 5_000e6 * 8_500 / 10_000; // $100k + $4,250
        assertApproxEqRel(bobValue, bobExpected, 0.03e18, "Bob's gains come only from period 2");
    }

    // =========================================================================
    // FIX VALIDATION: previewWithdraw / previewRedeem ERC-4626 compliance
    // =========================================================================

    /// @notice ERC-4626: previewWithdraw(assets) MUST return >= actual shares burned.
    ///
    ///         Before fix: OZ default used pre-fee totalSupply.
    ///         With pending fees, _accruePerformanceFee() enlarges totalSupply inside
    ///         withdraw() → more shares burned per asset → preview < actual → SPEC VIOLATION.
    ///
    ///         After fix: previewWithdraw accounts for _pendingFeeShares(), returning
    ///         exactly the shares that will be burned (preview == actual).
    function test_previewWithdraw_matchesActual_withPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6); // Share price above HWM — fee is pending

        uint256 withdrawAmount = 40_000e6;
        uint256 preview = vault.previewWithdraw(withdrawAmount);

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        uint256 actualBurned = sharesBefore - vault.balanceOf(alice);

        // Spec: preview >= actual. Our override makes them exactly equal.
        assertGe(preview, actualBurned, "previewWithdraw must be >= actual shares burned (ERC-4626)");
        assertEq(preview, actualBurned, "previewWithdraw must equal actual shares burned");
    }

    /// @notice ERC-4626: previewRedeem(shares) MUST return <= actual assets received.
    ///
    ///         Before fix: OZ default used pre-fee totalSupply.
    ///         With pending fees, _accruePerformanceFee() enlarges totalSupply inside
    ///         redeem() → fewer assets per share → preview > actual → SPEC VIOLATION.
    ///
    ///         After fix: previewRedeem accounts for _pendingFeeShares(), returning
    ///         exactly the assets that will be received (preview == actual).
    function test_previewRedeem_matchesActual_withPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        _generateYield(10_000e6); // Share price above HWM — fee is pending

        uint256 redeemShares = vault.balanceOf(alice) / 2;
        uint256 preview = vault.previewRedeem(redeemShares);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemShares, alice, alice);
        uint256 actualReceived = token.balanceOf(alice) - balBefore;

        // Spec: preview <= actual. Our override makes them exactly equal.
        assertLe(preview, actualReceived, "previewRedeem must be <= actual assets received (ERC-4626)");
        assertEq(preview, actualReceived, "previewRedeem must equal actual assets received");
    }

    /// @notice previewWithdraw must be accurate when there is NO pending fee.
    function test_previewWithdraw_accurate_whenNoPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        vm.prank(keeper);
        vault.collectFees(); // HWM current, no pending fee

        uint256 withdrawAmount = 40_000e6;
        uint256 preview = vault.previewWithdraw(withdrawAmount);

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        uint256 actualBurned = sharesBefore - vault.balanceOf(alice);

        assertEq(preview, actualBurned, "previewWithdraw must match actual when no pending fee");
    }

    /// @notice previewRedeem must be accurate when there is NO pending fee.
    function test_previewRedeem_accurate_whenNoPendingFee() public {
        _depositAndAllocate(alice, DEPOSIT);
        vm.prank(keeper);
        vault.collectFees(); // HWM current, no pending fee

        uint256 redeemShares = vault.balanceOf(alice) / 2;
        uint256 preview = vault.previewRedeem(redeemShares);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(redeemShares, alice, alice);
        uint256 actualReceived = token.balanceOf(alice) - balBefore;

        assertEq(preview, actualReceived, "previewRedeem must match actual when no pending fee");
    }

    // =========================================================================
    // FIX VALIDATION: no retroactive fee when re-enabling from zero
    // =========================================================================

    /// @notice Setting fee to 0 then generating yield then re-enabling must NOT
    ///         retroactively tax the yield earned while fee was disabled.
    ///
    ///         Before fix: _accruePerformanceFee() early-returned when performanceFeeBps==0,
    ///         leaving HWM stale. Re-enabling fee caused the full yield period to be
    ///         retroactively taxed.
    ///
    ///         After fix: HWM always advances when share price exceeds it, even when
    ///         performanceFeeBps==0. Re-enabling finds HWM already at current price → no fee.
    function test_noRetroactiveFeeAfterReenablingFromZero() public {
        _depositAndAllocate(alice, DEPOSIT);

        // Admin disables fee (e.g., promotional period)
        vm.prank(admin);
        vault.setPerformanceFee(0);

        // Yield generated while fee is disabled — HWM must still advance
        _generateYield(10_000e6);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        // Re-enable fee — must NOT retroactively charge for the $10k yield above
        vm.prank(admin);
        vault.setPerformanceFee(1_500);

        // Collect immediately — should find nothing to collect
        vm.prank(keeper);
        vault.collectFees();

        uint256 newFeeShares = vault.balanceOf(feeRecipient) - feeSharesBefore;
        assertEq(newFeeShares, 0, "No retroactive fee after re-enabling from zero");
    }

    /// @notice Only admin can transfer admin role (two-step: propose + accept).
    function test_transferAdmin_onlyAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        // Non-admin cannot propose transfer
        vm.prank(alice);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.transferAdmin(newAdmin);

        vm.prank(keeper);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.transferAdmin(newAdmin);

        // Admin proposes transfer (two-step)
        vm.prank(admin);
        vault.transferAdmin(newAdmin);
        assertEq(vault.pendingAdmin(), newAdmin);
        assertEq(vault.admin(), admin, "Admin unchanged until accepted");

        // New admin accepts
        vm.prank(newAdmin);
        vault.acceptAdmin();

        // Old admin no longer has access
        vm.prank(admin);
        vm.expectRevert(TezoroV1_2.NotAdmin.selector);
        vault.setFeeRecipient(alice);

        // New admin has access
        vm.prank(newAdmin);
        vault.setFeeRecipient(alice);
        assertEq(vault.feeRecipient(), alice, "New admin controls feeRecipient");
    }
}
