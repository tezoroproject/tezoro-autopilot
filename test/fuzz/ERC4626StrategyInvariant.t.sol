// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategy} from "../../src/strategies/ERC4626MultiStrategy.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// MetaMorpho USDC vaults (ERC-4626) on Ethereum mainnet
address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
address constant GAUNTLET_USDC_CORE = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

/// @notice Handler contract that performs random operations on ERC4626MultiStrategy.
contract ERC4626StrategyHandler is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategy public strategy;
    address public vaultAddr;
    address public adminAddr;
    address public keeperAddr;

    address[] public subVaults;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_calls;
    mapping(bytes4 => uint256) public ghost_callCount;

    constructor(
        ERC4626MultiStrategy strategy_,
        address vault_,
        address admin_,
        address keeper_,
        address[] memory subVaults_
    ) {
        strategy = strategy_;
        vaultAddr = vault_;
        adminAddr = admin_;
        keeperAddr = keeper_;

        for (uint256 i = 0; i < subVaults_.length; i++) {
            subVaults.push(subVaults_[i]);
        }
    }

    // ====== Handler actions ======

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 500_000e6);
        ghost_callCount[this.deposit.selector]++;
        ghost_calls++;

        deal(USDC, vaultAddr, amount);
        vm.startPrank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), amount);
        strategy.deposit(amount);
        vm.stopPrank();

        ghost_totalDeposited += amount;
    }

    function allocate(uint256 vaultSeed, uint256 amount) external {
        ghost_callCount[this.allocate.selector]++;
        ghost_calls++;

        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        if (idle < 1e6) return;

        amount = bound(amount, 1e6, idle);
        uint256 idx = vaultSeed % subVaults.length;

        vm.prank(keeperAddr);
        try strategy.allocate(subVaults[idx], amount) {} catch {}
    }

    function deallocate(uint256 vaultSeed, uint256 pct) external {
        ghost_callCount[this.deallocate.selector]++;
        ghost_calls++;

        uint256 idx = vaultSeed % subVaults.length;
        uint256 svBal = strategy.subVaultBalance(subVaults[idx]);
        if (svBal < 2) return;

        pct = bound(pct, 1, 99);
        uint256 amount = svBal * pct / 100;
        if (amount == 0) return;

        vm.prank(keeperAddr);
        try strategy.deallocate(subVaults[idx], amount) {} catch {}
    }

    function withdraw(uint256 amount) external {
        ghost_callCount[this.withdraw.selector]++;
        ghost_calls++;

        uint256 bal = strategy.balanceOf();
        if (bal < 1e6) return;

        amount = bound(amount, 1e6, bal);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(amount);

        ghost_totalWithdrawn += withdrawn;
    }

    function emergencyWithdraw() external {
        ghost_callCount[this.emergencyWithdraw.selector]++;
        ghost_calls++;

        uint256 bal = strategy.balanceOf();
        if (bal == 0) return;

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        ghost_totalWithdrawn += withdrawn;
    }

    function warpTime(uint256 seconds_) external {
        ghost_callCount[this.warpTime.selector]++;
        ghost_calls++;

        seconds_ = bound(seconds_, 1 hours, 30 days);
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + seconds_ / 12);
    }

    function recallSubVault(uint256 vaultSeed) external {
        ghost_callCount[this.recallSubVault.selector]++;
        ghost_calls++;

        uint256 idx = vaultSeed % subVaults.length;

        vm.prank(adminAddr);
        try strategy.recallSubVault(subVaults[idx]) {} catch {}

        // Unfreeze so future allocations can work
        if (strategy.depositFrozenSubVaults(subVaults[idx])) {
            vm.prank(adminAddr);
            try strategy.unfreezeSubVaultDeposits(subVaults[idx]) {} catch {}
        }
    }

    function freezeUnfreezeSubVault(uint256 vaultSeed) external {
        ghost_callCount[this.freezeUnfreezeSubVault.selector]++;
        ghost_calls++;

        uint256 idx = vaultSeed % subVaults.length;

        vm.prank(adminAddr);
        try strategy.freezeSubVaultDeposits(subVaults[idx]) {} catch {}

        vm.prank(adminAddr);
        try strategy.unfreezeSubVaultDeposits(subVaults[idx]) {} catch {}
    }

    function callSummary() external {
        emit log_named_uint("Total calls", ghost_calls);
        emit log_named_uint("  deposit", ghost_callCount[this.deposit.selector]);
        emit log_named_uint("  allocate", ghost_callCount[this.allocate.selector]);
        emit log_named_uint("  deallocate", ghost_callCount[this.deallocate.selector]);
        emit log_named_uint("  withdraw", ghost_callCount[this.withdraw.selector]);
        emit log_named_uint("  emergencyWithdraw", ghost_callCount[this.emergencyWithdraw.selector]);
        emit log_named_uint("  warpTime", ghost_callCount[this.warpTime.selector]);
        emit log_named_uint("  recallSubVault", ghost_callCount[this.recallSubVault.selector]);
        emit log_named_uint("  freezeUnfreezeSubVault", ghost_callCount[this.freezeUnfreezeSubVault.selector]);
        emit log_named_uint("Ghost deposited", ghost_totalDeposited);
        emit log_named_uint("Ghost withdrawn", ghost_totalWithdrawn);
    }
}

/// @notice Invariant tests for ERC4626MultiStrategy.
contract ERC4626StrategyInvariantTest is Test {
    using SafeERC20 for IERC20;

    ERC4626MultiStrategy strategy;
    ERC4626StrategyHandler handler;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new ERC4626MultiStrategy(USDC, vaultAddr, adminAddr, "ERC4626 Invariant", 64, new address[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(STEAKHOUSE_USDC);
        strategy.addSubVault(GAUNTLET_USDC_CORE);
        vm.stopPrank();

        // Seed initial deposit
        deal(USDC, vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), type(uint256).max);
        strategy.deposit(500_000e6);
        vm.stopPrank();

        // Create handler
        address[] memory vaults = new address[](2);
        vaults[0] = STEAKHOUSE_USDC;
        vaults[1] = GAUNTLET_USDC_CORE;
        handler = new ERC4626StrategyHandler(strategy, vaultAddr, adminAddr, keeperAddr, vaults);

        targetContract(address(handler));

        // Initialize ghost state
        handler.deposit(0); // deposits minimum 1e6
    }

    // ====== Invariant: balanceOf == idle + sum(subVault balances) ======

    function invariant_balanceOf_eq_idle_plus_subVaults() public view {
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 svA = strategy.subVaultBalance(STEAKHOUSE_USDC);
        uint256 svB = strategy.subVaultBalance(GAUNTLET_USDC_CORE);

        uint256 computed = idle + svA + svB;
        uint256 reported = strategy.balanceOf();

        assertApproxEqAbs(reported, computed, 3, "balanceOf must equal idle + sub-vaults");
    }

    // ====== Invariant: availableLiquidity <= balanceOf ======

    function invariant_availableLiquidity_leq_balanceOf() public view {
        uint256 bal = strategy.balanceOf();
        uint256 avail = strategy.availableLiquidity();

        assertLe(avail, bal, "availableLiquidity must be <= balanceOf");
    }

    // ====== Invariant: solvency ======

    function invariant_solvency() public view {
        uint256 deposited = handler.ghost_totalDeposited() + 500_000e6;
        uint256 withdrawn = handler.ghost_totalWithdrawn();
        uint256 currentBal = strategy.balanceOf();

        uint256 totalValue = withdrawn + currentBal;
        assertGe(totalValue + 100, deposited, "Solvency: total value >= deposited");
    }

    // ====== Invariant: idle <= total balance ======

    function invariant_idleLeqTotal() public view {
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 bal = strategy.balanceOf();

        assertLe(idle, bal, "Idle should not exceed total balance");
    }

    // ====== Invariant: sub-vault count consistent ======

    function invariant_subVaultCount_consistent() public view {
        assertEq(strategy.subVaultCount(), 2, "Sub-vault count should stay at 2");
    }

    // ====== Summary ======

    function invariant_callSummary() public {
        handler.callSummary();
    }
}
