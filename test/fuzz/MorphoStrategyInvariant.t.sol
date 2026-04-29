// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {IMorpho, MarketParams, MorphoMarket, Position, Id} from "../../src/interfaces/IMorpho.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

bytes32 constant USDC_WSTETH_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
bytes32 constant USDC_WBTC_MARKET = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;
bytes32 constant USDC_CBBTC_MARKET = 0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64;

/// @notice Handler contract that performs random operations on MorphoBlueMultiStrategyV1_2.
///         Foundry calls these functions in random sequences to find invariant violations.
contract MorphoStrategyHandler is Test {
    using SafeERC20 for IERC20;

    MorphoBlueMultiStrategyV1_2 public strategy;
    IMorpho public morpho;
    address public vaultAddr;
    address public adminAddr;
    address public keeperAddr;

    Id[] public marketIds;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_calls;
    mapping(bytes4 => uint256) public ghost_callCount;

    constructor(
        MorphoBlueMultiStrategyV1_2 strategy_,
        address vault_,
        address admin_,
        address keeper_,
        Id[] memory mids_
    ) {
        strategy = strategy_;
        morpho = strategy_.morpho();
        vaultAddr = vault_;
        adminAddr = admin_;
        keeperAddr = keeper_;

        for (uint256 i = 0; i < mids_.length; i++) {
            marketIds.push(mids_[i]);
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

    function allocate(uint256 marketSeed, uint256 amount) external {
        ghost_callCount[this.allocate.selector]++;
        ghost_calls++;

        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        if (idle < 1e6) return;

        amount = bound(amount, 1e6, idle);
        uint256 idx = marketSeed % marketIds.length;

        vm.prank(keeperAddr);
        try strategy.allocate(marketIds[idx], amount) {} catch {}
    }

    function deallocate(uint256 marketSeed, uint256 pct) external {
        ghost_callCount[this.deallocate.selector]++;
        ghost_calls++;

        uint256 idx = marketSeed % marketIds.length;
        uint256 mBal = strategy.marketBalance(marketIds[idx]);
        if (mBal < 2) return;

        pct = bound(pct, 1, 99);
        uint256 amount = mBal * pct / 100;
        if (amount == 0) return;

        vm.prank(keeperAddr);
        try strategy.deallocate(marketIds[idx], amount) {} catch {}
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

        // Accrue interest on all markets
        for (uint256 i = 0; i < marketIds.length; i++) {
            MarketParams memory mp = morpho.idToMarketParams(marketIds[i]);
            try morpho.accrueInterest(mp) {} catch {}
        }
    }

    function recallMarket(uint256 marketSeed) external {
        ghost_callCount[this.recallMarket.selector]++;
        ghost_calls++;

        uint256 idx = marketSeed % marketIds.length;

        vm.prank(adminAddr);
        try strategy.recallMarket(marketIds[idx]) {} catch {}
    }

    function freezeMarket(uint256 marketSeed) external {
        ghost_callCount[this.freezeMarket.selector]++;
        ghost_calls++;

        uint256 idx = marketSeed % marketIds.length;

        vm.prank(adminAddr);
        try strategy.freezeMarketDeposits(marketIds[idx]) {} catch {}
    }

    function unfreezeMarket(uint256 marketSeed) external {
        ghost_callCount[this.unfreezeMarket.selector]++;
        ghost_calls++;

        uint256 idx = marketSeed % marketIds.length;

        vm.prank(adminAddr);
        try strategy.unfreezeMarketDeposits(marketIds[idx]) {} catch {}
    }

    function callSummary() external {
        emit log_named_uint("Total calls", ghost_calls);
        emit log_named_uint("  deposit", ghost_callCount[this.deposit.selector]);
        emit log_named_uint("  allocate", ghost_callCount[this.allocate.selector]);
        emit log_named_uint("  deallocate", ghost_callCount[this.deallocate.selector]);
        emit log_named_uint("  withdraw", ghost_callCount[this.withdraw.selector]);
        emit log_named_uint("  emergencyWithdraw", ghost_callCount[this.emergencyWithdraw.selector]);
        emit log_named_uint("  warpTime", ghost_callCount[this.warpTime.selector]);
        emit log_named_uint("  recallMarket", ghost_callCount[this.recallMarket.selector]);
        emit log_named_uint("  freezeMarket", ghost_callCount[this.freezeMarket.selector]);
        emit log_named_uint("  unfreezeMarket", ghost_callCount[this.unfreezeMarket.selector]);
        emit log_named_uint("Ghost deposited", ghost_totalDeposited);
        emit log_named_uint("Ghost withdrawn", ghost_totalWithdrawn);
    }
}

/// @notice Invariant tests for MorphoBlueMultiStrategyV1_2.
///         Foundry calls handler functions in random sequences, then checks invariants.
contract MorphoStrategyInvariantTest is Test {
    using SafeERC20 for IERC20;

    MorphoBlueMultiStrategyV1_2 strategy;
    MorphoStrategyHandler handler;
    IMorpho morpho = IMorpho(MORPHO);

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    Id midA;
    Id midB;
    Id midC;

    function setUp() public {
        vm.createSelectFork("ethereum");

        strategy = new MorphoBlueMultiStrategyV1_2(USDC, MORPHO, vaultAddr, adminAddr, "Morpho Invariant", 64, new MarketParams[](0));

        midA = Id.wrap(USDC_WSTETH_MARKET);
        midB = Id.wrap(USDC_WBTC_MARKET);
        midC = Id.wrap(USDC_CBBTC_MARKET);

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addMarket(morpho.idToMarketParams(midA));
        strategy.addMarket(morpho.idToMarketParams(midB));
        strategy.addMarket(morpho.idToMarketParams(midC));
        vm.stopPrank();

        // Seed initial deposit so the strategy has funds to work with
        deal(USDC, vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        IERC20(USDC).forceApprove(address(strategy), type(uint256).max);
        strategy.deposit(500_000e6);
        vm.stopPrank();

        // Create handler
        Id[] memory mids = new Id[](3);
        mids[0] = midA;
        mids[1] = midB;
        mids[2] = midC;
        handler = new MorphoStrategyHandler(strategy, vaultAddr, adminAddr, keeperAddr, mids);

        // Set handler as the only target for invariant testing
        targetContract(address(handler));

        // Track initial deposit in ghost
        handler.deposit(0); // Will deposit 1e6 (minimum) -- just to initialize
    }

    // ====== Invariant: balanceOf == idle + sum(market balances) ======

    function invariant_balanceOf_eq_idle_plus_markets() public view {
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 mA = strategy.marketBalance(midA);
        uint256 mB = strategy.marketBalance(midB);
        uint256 mC = strategy.marketBalance(midC);

        uint256 computed = idle + mA + mB + mC;
        uint256 reported = strategy.balanceOf();

        // Allow 3 units tolerance (1 per market from share rounding)
        assertApproxEqAbs(reported, computed, 3, "balanceOf must equal idle + markets");
    }

    // ====== Invariant: availableLiquidity <= balanceOf ======

    function invariant_availableLiquidity_leq_balanceOf() public view {
        uint256 bal = strategy.balanceOf();
        uint256 avail = strategy.availableLiquidity();

        assertLe(avail, bal, "availableLiquidity must be <= balanceOf");
    }

    // ====== Invariant: solvency -- withdrawn <= deposited + yield ======

    function invariant_solvency() public view {
        uint256 deposited = handler.ghost_totalDeposited() + 500_000e6; // initial seed
        uint256 withdrawn = handler.ghost_totalWithdrawn();
        uint256 currentBal = strategy.balanceOf();

        // Total value (withdrawn + remaining) should be >= deposited
        // (yield can make it more, but should never be less within rounding)
        uint256 totalValue = withdrawn + currentBal;
        assertGe(totalValue + 100, deposited, "Solvency: total value >= deposited");
    }

    // ====== Invariant: no negative idle ======

    function invariant_nonNegativeIdle() public view {
        // This can't underflow in Solidity, but we verify the strategy's
        // idle is a sane value relative to the total
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 bal = strategy.balanceOf();

        assertLe(idle, bal, "Idle should not exceed total balance");
    }

    // ====== Invariant: market count matches approved markets ======

    function invariant_marketCount_consistent() public view {
        assertEq(strategy.marketCount(), 3, "Market count should stay at 3");
    }

    // ====== Invariant: marketBalance views do not revert ======

    function invariant_marketBalance_doesNotRevert() public view {
        // The call itself is the test -- if marketBalance reverts, this invariant fails.
        // Verify that the sum of per-market balances + idle matches the reported total.
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        uint256 mA = strategy.marketBalance(midA);
        uint256 mB = strategy.marketBalance(midB);
        uint256 mC = strategy.marketBalance(midC);

        uint256 summed = idle + mA + mB + mC;
        uint256 reported = strategy.balanceOf();

        assertApproxEqAbs(reported, summed, 3, "balanceOf must match idle + market balances");
    }

    // ====== Summary (runs after each sequence) ======

    function invariant_callSummary() public {
        handler.callSummary();
    }
}
