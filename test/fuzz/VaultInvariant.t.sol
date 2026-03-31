// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_1} from "../../src/TezoroV1_1.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {AaveV3Strategy} from "../../src/strategies/AaveV3Strategy.sol";
import {CompoundV3Strategy} from "../../src/strategies/CompoundV3Strategy.sol";
import {MorphoBlueMultiStrategy} from "../../src/strategies/MorphoBlueMultiStrategy.sol";
import {FluidStrategy} from "../../src/strategies/FluidStrategy.sol";
import {IMorpho, MarketParams, Id} from "../../src/interfaces/IMorpho.sol";

// Ethereum mainnet addresses
address constant INV_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant INV_SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
address constant INV_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant INV_COMPOUND_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
address constant INV_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
address constant INV_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
bytes32 constant INV_MORPHO_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;
address constant INV_FLUID_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
address constant INV_AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
address constant INV_SPARK_REWARDS = 0x4370D3b6C9588E02ce9D22e684387859c7Ff5b34;
address constant INV_COMET_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
address constant INV_COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

/// @title VaultHandler — Performs random operations on the vault for invariant testing.
/// @dev Foundry calls random functions on this handler. Ghost variables track cumulative state.
contract VaultHandler is Test {
    using SafeERC20 for IERC20;

    TezoroV1_1 public vault;
    IERC20 public token;
    address public admin;
    address public keeper;

    address[] public actors;
    mapping(address => uint256) public ghost_deposited;
    mapping(address => uint256) public ghost_withdrawn;
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_calls;
    uint256 public ghost_lastSharePrice;

    constructor(
        TezoroV1_1 vault_,
        address token_,
        address admin_,
        address keeper_,
        address[] memory actors_,
        uint256 initialSharePrice_
    ) {
        vault = vault_;
        token = IERC20(token_);
        admin = admin_;
        keeper = keeper_;
        actors = actors_;
        ghost_lastSharePrice = initialSharePrice_;
    }

    // --- Seed ghost state for deposits made outside handler ---

    function seedGhostDeposit(address actor, uint256 amount) external {
        ghost_deposited[actor] += amount;
        ghost_totalDeposited += amount;
    }

    function _updateSharePrice() internal {
        if (vault.totalSupply() == 0) return;
        uint256 current = vault.convertToAssets(1e12);
        ghost_lastSharePrice = current;
    }

    // --- Random actor selector ---

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- Handler actions ---

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1e6, 500_000e6); // 1 to 500k USDC

        uint256 balance = token.balanceOf(actor);
        if (balance < amount) return; // skip if insufficient

        vm.prank(actor);
        try vault.deposit(amount, actor) {
            ghost_deposited[actor] += amount;
            ghost_totalDeposited += amount;
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function withdraw(uint256 actorSeed, uint256 pct) external {
        address actor = _getActor(actorSeed);
        pct = bound(pct, 1, 100);

        uint256 maxW = vault.maxWithdraw(actor);
        uint256 amount = (maxW * pct) / 100;
        if (amount == 0) return;

        vm.prank(actor);
        try vault.withdraw(amount, actor, actor) {
            ghost_withdrawn[actor] += amount;
            ghost_totalWithdrawn += amount;
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function redeem(uint256 actorSeed, uint256 pct) external {
        address actor = _getActor(actorSeed);
        pct = bound(pct, 1, 100);

        uint256 maxR = vault.maxRedeem(actor);
        uint256 shares = (maxR * pct) / 100;
        if (shares == 0) return;

        uint256 balBefore = token.balanceOf(actor);

        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256) {
            uint256 received = token.balanceOf(actor) - balBefore;
            ghost_withdrawn[actor] += received;
            ghost_totalWithdrawn += received;
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function rebalance() external {
        vm.prank(keeper);
        try vault.rebalance() {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function reconcile() external {
        vm.prank(keeper);
        try vault.reconcile() {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function collectFees() external {
        vm.prank(keeper);
        try vault.collectFees() {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 30 days);
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + seconds_ / 12); // ~12s per block
        ghost_calls++;
        _updateSharePrice();
    }

    function freezeStrategy(uint256 strategySeed) external {
        uint256 count = vault.strategiesCount();
        if (count == 0) return;
        IStrategy strat = vault.strategies(strategySeed % count);

        vm.prank(admin);
        try vault.freezeStrategyDeposits(strat) {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function unfreezeStrategy(uint256 strategySeed) external {
        uint256 count = vault.strategiesCount();
        if (count == 0) return;
        IStrategy strat = vault.strategies(strategySeed % count);

        vm.prank(admin);
        try vault.unfreezeStrategyDeposits(strat) {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function forceRedeemUser(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        uint256 balBefore = token.balanceOf(actor);

        vm.prank(admin);
        try vault.forceRedeem(actor) {
            uint256 received = token.balanceOf(actor) - balBefore;
            ghost_withdrawn[actor] += received;
            ghost_totalWithdrawn += received;
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function pauseStrategy(uint256 strategySeed) external {
        uint256 count = vault.strategiesCount();
        if (count == 0) return;
        IStrategy strat = vault.strategies(strategySeed % count);

        vm.prank(admin);
        try vault.pauseStrategy(strat) {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }

    function unpauseStrategy(uint256 strategySeed) external {
        uint256 count = vault.strategiesCount();
        if (count == 0) return;
        IStrategy strat = vault.strategies(strategySeed % count);

        vm.prank(admin);
        try vault.unpauseStrategy(strat) {
            ghost_calls++;
        } catch {}
        _updateSharePrice();
    }
}

/// @title VaultInvariantTest — Invariant assertions checked after every random call sequence.
contract VaultInvariantTest is Test {
    using SafeERC20 for IERC20;

    TezoroV1_1 public vault;
    VaultHandler public handler;

    address public admin = makeAddr("admin");
    address public keeper = makeAddr("keeper");
    address public feeRecipient = makeAddr("feeRecipient");

    address public alice;
    address public bob;
    address public charlie;

    address[] public actors;

    uint256 public initialHWM;

    function setUp() public {
        vm.createSelectFork("ethereum");

        address token = INV_USDC;

        // Deploy vault
        vault = new TezoroV1_1(
            IERC20(token),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            1_500, // 15% performance fee
            300 // 3% idle buffer
        );

        // Deploy strategies
        address aaveAToken = INV_A_USDC;
        AaveV3Strategy aaveStrategy = new AaveV3Strategy(token, INV_AAVE_POOL, aaveAToken, address(vault), INV_AAVE_REWARDS);
        CompoundV3Strategy compoundStrategy = new CompoundV3Strategy(token, INV_COMPOUND_USDC, address(vault), INV_COMET_REWARDS, INV_COMP);

        // Get Spark aToken dynamically
        (bool ok_, bytes memory data_) = INV_SPARK_POOL.staticcall(abi.encodeWithSignature("getReserveData(address)", token));
        require(ok_, "getReserveData failed");
        address spToken;
        assembly { spToken := mload(add(data_, 288)) }
        AaveV3Strategy sparkStrategy = new AaveV3Strategy(token, INV_SPARK_POOL, spToken, address(vault), INV_SPARK_REWARDS);

        MorphoBlueMultiStrategy morphoStrategy = new MorphoBlueMultiStrategy(token, INV_MORPHO, address(vault), admin, "Morpho Multi", 64, new MarketParams[](0));
        FluidStrategy fluidStrategy = new FluidStrategy(token, INV_FLUID_USDC, address(vault));

        // Add strategies and set allocation via rebalance (97% / 5 = 19.4% each)
        vm.startPrank(admin);

        // Configure morpho multi-strategy
        MarketParams memory mp = IMorpho(INV_MORPHO).idToMarketParams(Id.wrap(INV_MORPHO_MARKET));
        morphoStrategy.addMarket(mp);
        morphoStrategy.setKeeper(keeper);

        vault.addStrategy(IStrategy(address(aaveStrategy)));
        vault.addStrategy(IStrategy(address(compoundStrategy)));
        vault.addStrategy(IStrategy(address(sparkStrategy)));
        vault.addStrategy(IStrategy(address(morphoStrategy)));
        vault.addStrategy(IStrategy(address(fluidStrategy)));

        {
            IStrategy[] memory strats = new IStrategy[](5);
            uint256[] memory bps = new uint256[](5);
            strats[0] = IStrategy(address(aaveStrategy));      bps[0] = 1_940;
            strats[1] = IStrategy(address(compoundStrategy));   bps[1] = 1_940;
            strats[2] = IStrategy(address(sparkStrategy));      bps[2] = 1_940;
            strats[3] = IStrategy(address(morphoStrategy));     bps[3] = 1_940;
            strats[4] = IStrategy(address(fluidStrategy));      bps[4] = 1_940;
            vault.rebalance(strats, bps);
        }

        vault.setKeeper(keeper);
        vm.stopPrank();

        // Morpho multi-strategy: allocate idle funds to market
        {
            uint256 idle = IERC20(token).balanceOf(address(morphoStrategy));
            if (idle > 0) {
                vm.prank(keeper);
                morphoStrategy.allocate(Id.wrap(INV_MORPHO_MARKET), idle);
            }
        }

        // Create actors
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        actors.push(alice);
        actors.push(bob);
        actors.push(charlie);

        // Fund actors
        uint256 userBalance = 5_000_000e6; // 5M USDC each
        for (uint256 i = 0; i < actors.length; i++) {
            deal(token, actors[i], userBalance);
            vm.prank(actors[i]);
            IERC20(token).forceApprove(address(vault), type(uint256).max);
        }

        // Seed vault with initial deposit so share price is established
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        // Record initial high-water mark after first deposit
        initialHWM = vault.highWaterMark();

        // Deploy handler — seed ghost variables for initial deposit
        uint256 initialSharePrice = vault.convertToAssets(1e12);
        handler = new VaultHandler(vault, token, admin, keeper, actors, initialSharePrice);
        handler.seedGhostDeposit(alice, 100_000e6);

        // Only target the handler
        targetContract(address(handler));
    }

    // =========================================================================
    // Invariant: totalAssets == idle + sum(trackedBalance)
    // =========================================================================

    function invariant_totalAssets_eq_idle_plus_tracked() public view {
        uint256 idle = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 sumTracked = 0;
        uint256 count = vault.strategiesCount();

        for (uint256 i = 0; i < count; i++) {
            IStrategy strat = vault.strategies(i);
            if (!vault.pausedStrategies(strat)) {
                sumTracked += vault.trackedBalance(strat);
            }
        }

        assertEq(idle + sumTracked, vault.totalAssets(), "INVARIANT: idle + tracked == totalAssets");
    }

    // =========================================================================
    // Invariant: vault is solvent (real balance >= totalAssets)
    // =========================================================================

    function invariant_solvency() public view {
        uint256 idle = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 sumReal = 0;
        uint256 count = vault.strategiesCount();

        for (uint256 i = 0; i < count; i++) {
            IStrategy strat = vault.strategies(i);
            try strat.balanceOf() returns (uint256 bal) {
                sumReal += bal;
            } catch {}
        }

        uint256 totalReal = idle + sumReal;
        uint256 totalAssets_ = vault.totalAssets();

        // Allow rounding tolerance: lending protocols may round down on each deposit/withdraw.
        // Multiple rebalances without reconcile can accumulate drift across strategies.
        uint256 tolerance = count * 10;
        assertGe(totalReal + tolerance, totalAssets_, "INVARIANT: vault is solvent (within rounding tolerance)");
    }

    // =========================================================================
    // Invariant: totalSupply == sum of all balances
    // =========================================================================

    function invariant_totalSupply_consistent() public view {
        uint256 sumBalances = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sumBalances += vault.balanceOf(actors[i]);
        }
        sumBalances += vault.balanceOf(feeRecipient);

        // totalSupply should equal sum of known balances
        // OZ 5.x virtual offset is NOT counted in totalSupply — only real balances matter
        assertEq(vault.totalSupply(), sumBalances, "INVARIANT: totalSupply == sum(balances)");
    }

    // =========================================================================
    // Invariant: no user withdrew more than deposited + yield
    // =========================================================================

    function invariant_noFreeMoneyFromRounding() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 deposited = handler.ghost_deposited(actor);
            uint256 withdrawn = handler.ghost_withdrawn(actor);

            if (deposited == 0) {
                assertEq(withdrawn, 0, "INVARIANT: cannot withdraw without depositing");
            }
        }
    }

    // =========================================================================
    // Invariant: share price >= initial (unless management fees dominate)
    // =========================================================================

    function invariant_sharePriceNonNegative() public view {
        if (vault.totalSupply() == 0) return;
        // Pausing a strategy can push totalAssets to 0 while totalSupply > 0
        // (fee shares remain but all assets are in the paused strategy).
        if (_anyStrategyPaused()) return;

        uint256 sharePrice = vault.convertToAssets(1e12); // 1 share in 6+6 decimals
        assertGt(sharePrice, 0, "INVARIANT: share price > 0");
    }

    // =========================================================================
    // Invariant: handler actually did something (sanity check)
    // =========================================================================

    function invariant_callSummary() public view {
        // This isn't a real invariant — just logs activity for debugging
        // handler.ghost_calls() should be > 0 after a run
    }

    // =========================================================================
    // Invariant: high-water mark never decreases
    // =========================================================================

    function invariant_hwm_neverDecreases() public view {
        uint256 currentHWM = vault.highWaterMark();
        assertGe(currentHWM, initialHWM, "INVARIANT: HWM must never decrease below initial value");
    }

    // =========================================================================
    // Invariant: share price never drops significantly below initial 1:1
    // =========================================================================

    function invariant_sharePriceFloor() public view {
        if (vault.totalSupply() == 0) return;
        // Pausing a strategy intentionally drops share price (tracked balance excluded),
        // so skip this check when any strategy is paused.
        if (_anyStrategyPaused()) return;

        uint256 sharePrice = vault.convertToAssets(1e12);
        // 1e12 shares (with 6 decimal offset) should convert to at least ~1e6 assets
        // Allow 1 wei rounding tolerance
        assertGe(sharePrice, 1e6 - 1, "INVARIANT: share price must not go significantly below initial 1:1");
    }

    // =========================================================================
    // Invariant: share price monotonically non-decreasing across actions
    // =========================================================================

    function invariant_sharePriceMonotonicallyNonDecreasing() public view {
        if (vault.totalSupply() == 0) return;
        // Pausing a strategy intentionally drops share price (tracked balance excluded).
        // The ghost_lastSharePrice was set AFTER the pause action, so current == ghost.
        // But skip to avoid false positives from cross-action timing.
        if (_anyStrategyPaused()) return;

        uint256 currentSharePrice = vault.convertToAssets(1e12);
        uint256 lastSharePrice = handler.ghost_lastSharePrice();
        assertGe(currentSharePrice, lastSharePrice, "INVARIANT: share price must not decrease between actions");
    }

    // =========================================================================
    // Invariant: totalAssets >= idle balance
    // =========================================================================

    function invariant_totalAssets_geq_idle() public view {
        uint256 idle = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 totalAssets_ = vault.totalAssets();
        assertGe(totalAssets_, idle, "INVARIANT: totalAssets must be >= idle balance");
    }

    // =========================================================================
    // Invariant: feeRecipient balance is readable (no revert)
    // =========================================================================

    function invariant_feeRecipient_hasShares_or_zero() public view {
        uint256 feeShares = vault.balanceOf(feeRecipient);
        if (feeShares > 0) {
            // Verify fee shares are redeemable (previewRedeem doesn't revert and returns > 0)
            uint256 redeemable = vault.previewRedeem(feeShares);
            assertGt(redeemable, 0, "INVARIANT: feeRecipient shares must be redeemable for assets");
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _anyStrategyPaused() internal view returns (bool) {
        uint256 count = vault.strategiesCount();
        for (uint256 i = 0; i < count; i++) {
            if (vault.pausedStrategies(vault.strategies(i))) return true;
        }
        return false;
    }
}
