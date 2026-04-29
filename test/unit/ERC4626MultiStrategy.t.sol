// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// ---- Mock ERC-20 token (mintable) ----

contract MockToken is ERC20 {
    uint8 internal _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

// ---- Mock ERC-4626 vault ----

contract MockVault4626 is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Vault", "mVAULT") {}
}

// ---- Tests ----

contract ERC4626MultiStrategyTest is Test {
    MockToken token;
    MockVault4626 subVaultA;
    MockVault4626 subVaultB;
    ERC4626MultiStrategyV1_2 strategy;

    address vaultAddr;
    address adminAddr;
    address keeperAddr;
    address randomUser;

    function setUp() public {
        vaultAddr = makeAddr("vault");
        adminAddr = makeAddr("admin");
        keeperAddr = makeAddr("keeper");
        randomUser = makeAddr("random");

        token = new MockToken("USD Coin", "USDC", 6);
        subVaultA = new MockVault4626(IERC20(address(token)));
        subVaultB = new MockVault4626(IERC20(address(token)));

        strategy = new ERC4626MultiStrategyV1_2(address(token), vaultAddr, adminAddr, "MetaMorpho USDC", 20, new address[](0));

        // Admin sets keeper
        vm.prank(adminAddr);
        strategy.setKeeper(keeperAddr);

        // Admin adds sub-vaults
        vm.startPrank(adminAddr);
        strategy.addSubVault(address(subVaultA));
        strategy.addSubVault(address(subVaultB));
        vm.stopPrank();
    }

    // ========== Constructor ==========

    function test_constructor_setsImmutables() public view {
        assertEq(strategy.asset(), address(token));
        assertEq(strategy.vault(), vaultAddr);
        assertEq(strategy.admin(), adminAddr);
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        new ERC4626MultiStrategyV1_2(address(0), vaultAddr, adminAddr, "test", 64, new address[](0));
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        new ERC4626MultiStrategyV1_2(address(token), address(0), adminAddr, "test", 64, new address[](0));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        new ERC4626MultiStrategyV1_2(address(token), vaultAddr, address(0), "test", 64, new address[](0));
    }

    // ========== Admin: addSubVault ==========

    function test_addSubVault_works() public view {
        assertTrue(strategy.isApproved(address(subVaultA)));
        assertTrue(strategy.isApproved(address(subVaultB)));
        assertEq(strategy.subVaultCount(), 2);
    }

    function test_addSubVault_revertsIfNotAdmin() public {
        MockVault4626 newVault = new MockVault4626(IERC20(address(token)));
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.addSubVault(address(newVault));
    }

    function test_addSubVault_revertsIfAlreadyApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultAlreadyApproved.selector);
        strategy.addSubVault(address(subVaultA));
    }

    function test_addSubVault_revertsOnAssetMismatch() public {
        MockToken otherToken = new MockToken("Other", "OTH", 18);
        MockVault4626 wrongVault = new MockVault4626(IERC20(address(otherToken)));
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.AssetMismatch.selector);
        strategy.addSubVault(address(wrongVault));
    }

    function test_addSubVault_revertsOnZeroAddress() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        strategy.addSubVault(address(0));
    }

    // ========== Admin: removeSubVault ==========

    function test_removeSubVault_works() public {
        vm.prank(adminAddr);
        strategy.removeSubVault(address(subVaultA));

        assertFalse(strategy.isApproved(address(subVaultA)));
        assertEq(strategy.subVaultCount(), 1);
    }

    function test_removeSubVault_revertsIfNotApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.removeSubVault(makeAddr("unknown"));
    }

    function test_removeSubVault_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.removeSubVault(address(subVaultA));
    }

    // ========== Admin: setKeeper ==========

    function test_setKeeper_works() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(adminAddr);
        strategy.setKeeper(newKeeper);
        assertEq(strategy.keeper(), newKeeper);
    }

    function test_setKeeper_revertsOnZero() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        strategy.setKeeper(address(0));
    }

    function test_setKeeper_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.setKeeper(makeAddr("x"));
    }

    // ========== Admin: transferAdmin ==========

    function test_transferAdmin_works() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);
        assertEq(strategy.pendingAdmin(), newAdmin);
        assertEq(strategy.admin(), adminAddr);

        vm.prank(newAdmin);
        strategy.acceptAdmin();
        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_revertsIfNotPending() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotPendingAdmin.selector);
        strategy.acceptAdmin();
    }

    function test_transferAdmin_revertsOnZero() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.ZeroAddress.selector);
        strategy.transferAdmin(address(0));
    }

    function test_transferAdmin_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.transferAdmin(makeAddr("x"));
    }

    // ========== Vault: deposit ==========

    function test_deposit_holdsIdle() public {
        _fundVaultAndApprove(1000e6);

        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        assertEq(token.balanceOf(address(strategy)), 1000e6);
        assertEq(strategy.balanceOf(), 1000e6);
    }

    function test_deposit_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotVault.selector);
        strategy.deposit(100e6);
    }

    // ========== Keeper: allocate / deallocate ==========

    function test_allocate_movesIdleToSubVault() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        assertEq(token.balanceOf(address(strategy)), 400e6);
        assertGe(strategy.subVaultBalance(address(subVaultA)), 599e6); // rounding tolerance
    }

    function test_allocate_revertsIfNotKeeper() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotKeeper.selector);
        strategy.allocate(address(subVaultA), 100e6);
    }

    function test_allocate_revertsIfNotApproved() public {
        address unknown = makeAddr("unknown");
        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.allocate(unknown, 100e6);
    }

    function test_allocate_revertsIfInsufficientIdle() public {
        _fundVaultAndApprove(100e6);
        vm.prank(vaultAddr);
        strategy.deposit(100e6);

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.InsufficientIdle.selector);
        strategy.allocate(address(subVaultA), 200e6);
    }

    function test_deallocate_movesBackToIdle() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        vm.prank(keeperAddr);
        strategy.deallocate(address(subVaultA), 300e6);

        // Idle should have ~700e6 (400 + 300)
        uint256 idle = token.balanceOf(address(strategy));
        assertGe(idle, 699e6);
    }

    function test_deallocate_revertsIfNotKeeper() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotKeeper.selector);
        strategy.deallocate(address(subVaultA), 100e6);
    }

    function test_deallocate_revertsIfNotApproved() public {
        address unknown = makeAddr("unknown");
        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.deallocate(unknown, 100e6);
    }

    // ========== Vault: withdraw ==========

    function test_withdraw_fromIdleOnly() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(500e6);

        assertEq(withdrawn, 500e6);
        assertEq(token.balanceOf(vaultAddr), 500e6);
    }

    function test_withdraw_waterfallFromSubVaults() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        // Allocate all idle to sub-vaults
        vm.startPrank(keeperAddr);
        strategy.allocate(address(subVaultA), 500e6);
        strategy.allocate(address(subVaultB), 500e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(strategy)), 0);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(700e6);

        assertGe(withdrawn, 699e6);
        assertGe(token.balanceOf(vaultAddr), 699e6);
    }

    function test_withdraw_idlePlusSubVaults() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        // Idle = 400, sub-vault = 600. Withdraw 800 -> 400 idle + 400 from sub-vault
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(800e6);

        assertGe(withdrawn, 799e6);
    }

    function test_withdraw_moreThanAvailable() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(1000e6);

        assertEq(withdrawn, 500e6);
    }

    function test_withdraw_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotVault.selector);
        strategy.withdraw(100e6);
    }

    // ========== Vault: emergencyWithdraw ==========

    function test_emergencyWithdraw_collectsEverything() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(address(subVaultA), 400e6);
        strategy.allocate(address(subVaultB), 400e6);
        vm.stopPrank();

        // 200 idle + 400 in A + 400 in B
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertGe(withdrawn, 999e6);
        assertGe(token.balanceOf(vaultAddr), 999e6);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_emergencyWithdraw_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotVault.selector);
        strategy.emergencyWithdraw();
    }

    // ========== Views: balanceOf, availableLiquidity, isHealthy ==========

    function test_balanceOf_idlePlusSubVaults() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 300e6);

        // 700 idle + 300 in sub-vault
        assertGe(strategy.balanceOf(), 999e6);
    }

    function test_availableLiquidity_idlePlusMaxWithdraw() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 500e6);

        assertGe(strategy.availableLiquidity(), 999e6);
    }

    function test_isHealthy_falseWhenNoSubVaultActivity() public view {
        // Sub-vaults have no deposits from anyone
        assertFalse(strategy.isHealthy());
    }

    function test_isHealthy_trueWhenSubVaultHasAssets() public {
        _fundVaultAndApprove(100e6);
        vm.prank(vaultAddr);
        strategy.deposit(100e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 100e6);

        assertTrue(strategy.isHealthy());
    }

    // ========== sweepReward ==========

    function test_sweepReward_works() public {
        MockToken reward = new MockToken("Reward", "RWD", 18);
        reward.mint(address(strategy), 50e18);

        address rewardsModule = makeAddr("rewardsModule");

        vm.prank(vaultAddr);
        uint256 swept = strategy.sweepReward(address(reward), rewardsModule);

        assertEq(swept, 50e18);
        assertEq(reward.balanceOf(rewardsModule), 50e18);
    }

    function test_sweepReward_revertsOnAsset() public {
        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.CannotSweepAsset.selector);
        strategy.sweepReward(address(token), makeAddr("to"));
    }

    function test_sweepReward_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotVault.selector);
        strategy.sweepReward(makeAddr("token"), makeAddr("to"));
    }

    // ========== View helpers ==========

    function test_getSubVaults_returnsAll() public view {
        address[] memory vaults = strategy.getSubVaults();
        assertEq(vaults.length, 2);
        assertEq(vaults[0], address(subVaultA));
        assertEq(vaults[1], address(subVaultB));
    }

    function test_subVaultBalance_returnsBalance() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 300e6);

        assertGe(strategy.subVaultBalance(address(subVaultA)), 299e6);
        assertEq(strategy.subVaultBalance(address(subVaultB)), 0);
    }

    function test_harvest_returnsZero() public {
        vm.prank(vaultAddr);
        uint256 result = strategy.harvest(makeAddr("rewards"));
        assertEq(result, 0);
    }

    // ========== MAX_SUB_VAULTS cap ==========

    function test_addSubVault_revertsAtMaxCap() public {
        // Already have 2, add 18 more to hit MAX_SUB_VAULTS = 20
        for (uint256 i = 0; i < 18; i++) {
            MockVault4626 sv = new MockVault4626(IERC20(address(token)));
            vm.prank(adminAddr);
            strategy.addSubVault(address(sv));
        }
        assertEq(strategy.subVaultCount(), 20);

        // 21st should revert
        MockVault4626 extra = new MockVault4626(IERC20(address(token)));
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.TooManySubVaults.selector);
        strategy.addSubVault(address(extra));
    }

    // ========== removeSubVault: active position guard ==========

    function test_removeSubVault_revertsIfActivePosition() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 500e6);

        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultHasActivePosition.selector);
        strategy.removeSubVault(address(subVaultA));
    }

    function test_removeSubVault_worksAfterFullDeallocate() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 500e6);

        // Recall first (deallocates and freezes)
        vm.prank(adminAddr);
        strategy.recallSubVault(address(subVaultA));

        // Now remove should work
        vm.prank(adminAddr);
        strategy.removeSubVault(address(subVaultA));
        assertFalse(strategy.isApproved(address(subVaultA)));
    }

    // ========== sweepReward: share token guard ==========

    function test_sweepReward_revertsOnSubVaultShareToken() public {
        // subVaultA is an approved sub-vault — its address is a share token
        // sweepReward should block sweeping it (would drain positions)
        vm.prank(vaultAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.CannotSweepAsset.selector);
        strategy.sweepReward(address(subVaultA), makeAddr("to"));
    }

    // ========== WithdrawFailed events in withdraw waterfall ==========

    function test_withdraw_emitsWithdrawFailed_onBrokenSubVault() public {
        // Deploy a sub-vault that reverts on withdraw
        RevertingVault4626 brokenVault = new RevertingVault4626(IERC20(address(token)));

        vm.prank(adminAddr);
        strategy.addSubVault(address(brokenVault));

        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        // Allocate to both: working vault A and broken vault
        vm.startPrank(keeperAddr);
        strategy.allocate(address(subVaultA), 400e6);
        strategy.allocate(address(brokenVault), 400e6);
        vm.stopPrank();

        // Break the vault
        brokenVault.setBroken(true);

        // Withdraw more than idle — should emit WithdrawFailed for broken vault
        // but still succeed partially via subVaultA
        vm.prank(vaultAddr);
        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.WithdrawFailed(address(brokenVault));
        uint256 withdrawn = strategy.withdraw(800e6);

        // Should get idle (200) + subVaultA (400) = 600, broken vault skipped
        assertGe(withdrawn, 599e6);
    }

    // ========== emergencyWithdraw fault tolerance ==========

    function test_emergencyWithdraw_recoversPartialWhenOneBroken() public {
        RevertingVault4626 brokenVault = new RevertingVault4626(IERC20(address(token)));

        vm.prank(adminAddr);
        strategy.addSubVault(address(brokenVault));

        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(address(subVaultA), 400e6);
        strategy.allocate(address(brokenVault), 400e6);
        vm.stopPrank();

        // Break the vault
        brokenVault.setBroken(true);

        // emergencyWithdraw should recover subVaultA + idle, skip broken
        vm.prank(vaultAddr);
        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.WithdrawFailed(address(brokenVault));
        uint256 withdrawn = strategy.emergencyWithdraw();

        // Should get idle (200) + subVaultA (400) = 600
        assertGe(withdrawn, 599e6);
        // Strategy retains the stuck funds in broken vault
    }

    // ========== recallSubVault fault tolerance ==========

    function test_recallSubVault_emitsWithdrawFailedOnBrokenVault() public {
        RevertingVault4626 brokenVault = new RevertingVault4626(IERC20(address(token)));

        vm.prank(adminAddr);
        strategy.addSubVault(address(brokenVault));

        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(brokenVault), 400e6);

        brokenVault.setBroken(true);

        // recallSubVault should not revert, should emit WithdrawFailed and still freeze
        vm.prank(adminAddr);
        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.WithdrawFailed(address(brokenVault));
        strategy.recallSubVault(address(brokenVault));

        assertTrue(strategy.depositFrozenSubVaults(address(brokenVault)));
    }

    // =========================================================================
    // Audit fix #21 (Oak 2026-04-24): revoke sub-vault allowance on
    //                                 freeze/recall, restore on unfreeze
    // =========================================================================

    /// @notice freezeSubVaultDeposits must revoke the asset allowance the
    ///         strategy granted on addSubVault. Pre-fix the freeze flag only
    ///         blocked the strategy's own allocate() path; a frozen-but-
    ///         compromised child could still call transferFrom and pull idle
    ///         balances that accumulated later (fresh deposits, recalled
    ///         positions from other children).
    function test_auditFix21_freezeRevokesSubVaultAllowance() public {
        assertEq(
            token.allowance(address(strategy), address(subVaultA)),
            type(uint256).max,
            "precondition: addSubVault granted approval"
        );

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        assertEq(
            token.allowance(address(strategy), address(subVaultA)),
            0,
            "freeze must revoke allowance"
        );
    }

    /// @notice recallSubVault must revoke the allowance after pulling shares
    ///         back to idle. A recalled child has been operationally flagged
    ///         as distressed and must not retain a live pull.
    function test_auditFix21_recallRevokesSubVaultAllowance() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 200e6);

        assertEq(token.allowance(address(strategy), address(subVaultA)), type(uint256).max);

        vm.prank(adminAddr);
        strategy.recallSubVault(address(subVaultA));

        assertEq(
            token.allowance(address(strategy), address(subVaultA)),
            0,
            "recall must revoke allowance"
        );
    }

    /// @notice unfreezeSubVaultDeposits must restore the allowance the
    ///         freeze revoked, mirroring addSubVault. Without this, a
    ///         legitimate post-incident re-enable would leave the child
    ///         unable to receive deposits via the next allocate call.
    function test_auditFix21_unfreezeRestoresSubVaultAllowance() public {
        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));
        assertEq(token.allowance(address(strategy), address(subVaultA)), 0);

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(address(subVaultA));

        assertEq(
            token.allowance(address(strategy), address(subVaultA)),
            type(uint256).max,
            "unfreeze must restore allowance"
        );
    }

    /// @notice After freeze, the child cannot pull idle assets even if it
    ///         tries. The allowance is the binding contract; with it revoked,
    ///         transferFrom reverts.
    function test_auditFix21_frozenChildCannotPullIdle() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        // The sub-vault impersonates a malicious pull on idle.
        vm.prank(address(subVaultA));
        vm.expectRevert();
        IERC20(address(token)).transferFrom(address(strategy), address(subVaultA), 1);
    }

    // =========================================================================
    // Audit fix #14 (Oak 2026-04-24): per-sub-vault read isolation
    // =========================================================================

    /// @notice Pre-fix, balanceOf() and availableLiquidity() on the parent
    ///         strategy iterated sub-vaults without per-call try/catch. A
    ///         single reverting child (deprecated/paused MetaMorpho-style
    ///         vault) made the aggregate revert, which in turn:
    ///           * bricked totalAssets-driven previews on the Tezoro vault, and
    ///           * stalled the keeper rebalance loop (which reads strategy
    ///             balances per iteration).
    ///         Post-fix, the aggregator wraps each sub-vault read in try/catch
    ///         so a broken child contributes 0 instead of poisoning the sum.
    function test_auditFix14_balanceOfSurvivesBrokenSubVault() public {
        // Healthy sub-vaults A and B already added in setUp; allocate to them.
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 200e6);
        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultB), 100e6);

        // Add a third sub-vault and allocate to it before breaking.
        RevertingVault4626 brokenVault = new RevertingVault4626(IERC20(address(token)));
        vm.prank(adminAddr);
        strategy.addSubVault(address(brokenVault));

        vm.prank(keeperAddr);
        strategy.allocate(address(brokenVault), 150e6);

        // Now break it. Pre-fix: balanceOf on the strategy reverts on the
        // first read of brokenVault.balanceOf. Post-fix: revert is swallowed,
        // broken vault contributes 0.
        brokenVault.setBroken(true);

        uint256 total = strategy.balanceOf();
        // 50e6 idle + ~200e6 (A) + ~100e6 (B) + 0 (broken) = ~350e6.
        // Allow ±2 wei rounding inside ERC4626 share math.
        assertApproxEqAbs(total, 350e6, 2, "broken sub-vault must not poison balanceOf");
    }

    /// @notice Same regression on availableLiquidity: broken child must report 0
    ///         to maxWithdraw/maxRedeem instead of bricking the parent's
    ///         ERC-4626 view functions.
    function test_auditFix14_availableLiquiditySurvivesBrokenSubVault() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 200e6);
        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultB), 100e6);

        RevertingVault4626 brokenVault = new RevertingVault4626(IERC20(address(token)));
        vm.prank(adminAddr);
        strategy.addSubVault(address(brokenVault));

        vm.prank(keeperAddr);
        strategy.allocate(address(brokenVault), 150e6);

        brokenVault.setBroken(true);

        uint256 avail = strategy.availableLiquidity();
        // 50e6 idle + ~200e6 (A) + ~100e6 (B) + 0 (broken) = ~350e6.
        assertApproxEqAbs(avail, 350e6, 2, "broken sub-vault must not poison availableLiquidity");
    }

    // =========================================================================
    // Audit fix #22 (Oak 2026-04-24): redeem fallback uses previewWithdraw
    // =========================================================================

    /// @notice Pre-fix, the redeem-only fallback in withdraw() quoted shares
    ///         via convertToShares — a deposit-side, round-DOWN calculation.
    ///         When the sub-vault's share price is above 1 (any donation, any
    ///         interest accrual), a small withdrawal target rounded to ZERO
    ///         shares and the fallback emitted WithdrawFailed even though the
    ///         sub-vault still had redeemable liquidity. The liquidity stayed
    ///         unreachable through ordinary vault-mediated withdrawals.
    ///         Post-fix uses previewWithdraw (withdraw-side, round-UP) capped
    ///         against maxRedeem.
    function test_auditFix22_redeemFallbackUsesPreviewWithdraw() public {
        // 1. Deploy a redeem-only sub-vault (some real-world ERC-4626s
        // (e.g. YO.xyz) only support redeem, not withdraw).
        RedeemOnlyVault4626 ro = new RedeemOnlyVault4626(IERC20(address(token)));
        vm.prank(adminAddr);
        strategy.addSubVault(address(ro));

        // 2. Allocate strategy idle into ro at 1:1.
        _fundVaultAndApprove(100e6);
        vm.prank(vaultAddr);
        strategy.deposit(100e6);
        vm.prank(keeperAddr);
        strategy.allocate(address(ro), 100e6);

        // 3. Inflate ro's share price: donate 100e6 directly, totalAssets
        //    doubles while supply stays the same → 1 wei withdrawal rounds
        //    convertToShares → 0 (the bug surface) and previewWithdraw → 1.
        token.mint(address(ro), 100e6);

        // sanity: rounding direction differs as the audit describes.
        assertEq(ro.convertToShares(1), 0, "deposit-side rounds 1 wei to 0 shares");
        assertEq(ro.previewWithdraw(1), 1, "withdraw-side rounds 1 wei up to 1 share");

        // 4. Vault asks strategy for 1 wei. The other sub-vaults hold no
        //    position, so the loop reaches ro and hits the redeem fallback.
        uint256 vaultBalBefore = token.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(1);

        // Post-fix: previewWithdraw quotes 1 share, redeem returns 2 wei,
        //          delivery satisfies the target.
        // Pre-fix:  convertToShares quotes 0, fallback continues without a
        //          redeem, withdrawn == 0.
        assertGe(withdrawn, 1, "redeem fallback must reach available sub-vault liquidity");
        assertGe(token.balanceOf(vaultAddr) - vaultBalBefore, 1);
    }

    /// @notice Cap against maxRedeem so a previewWithdraw that quotes more
    ///         shares than the sub-vault can service this transaction does
    ///         not push the redeem into a hard revert.
    function test_auditFix22_redeemFallbackCapsToMaxRedeem() public {
        RedeemOnlyVault4626 ro = new RedeemOnlyVault4626(IERC20(address(token)));
        ro.setMaxRedeemCap(50e6); // sub-vault can service at most 50e6 shares per call
        vm.prank(adminAddr);
        strategy.addSubVault(address(ro));

        _fundVaultAndApprove(200e6);
        vm.prank(vaultAddr);
        strategy.deposit(200e6);
        vm.prank(keeperAddr);
        strategy.allocate(address(ro), 200e6);

        // Withdraw more than the cap. Without the maxRedeem cap, the fallback
        // would call redeem(200e6) which the sub-vault rejects, and the whole
        // sub-vault would be skipped via WithdrawFailed.
        uint256 vaultBalBefore = token.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(200e6);

        assertApproxEqAbs(withdrawn, 50e6, 2, "must extract the maxRedeem-capped portion");
        assertApproxEqAbs(token.balanceOf(vaultAddr) - vaultBalBefore, 50e6, 2);
    }

    // ========== Helpers ==========

    function _fundVaultAndApprove(uint256 amount) internal {
        token.mint(vaultAddr, amount);
        vm.prank(vaultAddr);
        token.approve(address(strategy), amount);
    }
}

// ---- Mock ERC-4626 vault that can revert ----

contract RevertingVault4626 is ERC4626 {
    bool public broken;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Broken Vault", "bVAULT") {}

    function setBroken(bool b) external {
        broken = b;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (broken) revert("broken");
        return super.maxWithdraw(owner);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (broken) revert("broken");
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (broken) revert("broken");
        return super.redeem(shares, receiver, owner);
    }

    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        if (broken) revert("broken");
        return super.balanceOf(account);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (broken) revert("broken");
        return super.convertToAssets(shares);
    }
}

// ---- Mock ERC-4626 vault that supports redeem only (no withdraw) ----
//
// Models real-world sub-vaults (e.g. YO.xyz) that expose ERC-4626 but only
// implement the share-quoted exit. withdraw reverts; the multi-strategy
// must fall back to redeem with the correct (round-up) share quote.
contract RedeemOnlyVault4626 is ERC4626 {
    uint256 public maxRedeemCap = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Redeem-only Vault", "roVAULT") {}

    function setMaxRedeemCap(uint256 cap) external {
        maxRedeemCap = cap;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        // Setting this to zero would make the parent strategy skip the
        // sub-vault entirely; redeem-only sub-vaults usually quote a
        // generous max here even though they can't service withdraw.
        // Returning a large value keeps the strategy in the redeem fallback.
        return type(uint256).max;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 owned = balanceOf(owner);
        return owned > maxRedeemCap ? maxRedeemCap : owned;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("redeem-only");
    }
}
