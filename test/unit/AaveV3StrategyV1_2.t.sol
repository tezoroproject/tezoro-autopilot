// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3StrategyV1_2} from "../../src/strategies/AaveV3StrategyV1_2.sol";

// Aave reserve config bitmap helpers (subset used by the strategy).
// See AaveV3 ReserveConfiguration: bit 56 = ACTIVE, bit 57 = FROZEN, bit 60 = PAUSED.
uint256 constant ACTIVE_BIT = uint256(1) << 56;
uint256 constant FROZEN_BIT = uint256(1) << 57;
uint256 constant PAUSED_BIT = uint256(1) << 60;

// ---- Mock asset ----

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---- Mock aToken ----
//
// Holds the underlying asset on its own balance (matches real aToken behavior:
// the aToken contract is the custodian of the supply-side reserves the pool
// can pay out from). Only the registered pool may mint, burn, or move
// underlying out.
contract MockAToken is ERC20 {
    address public pool;
    address public underlying;

    error NotPool();

    constructor(address pool_, address underlying_) ERC20("Aave USDC", "aUSDC") {
        pool = pool_;
        underlying = underlying_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != pool) revert NotPool();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != pool) revert NotPool();
        _burn(from, amount);
    }

    /// @notice Pool-only escape hatch to move underlying out of the aToken.
    function payOut(address to, uint256 amount) external {
        if (msg.sender != pool) revert NotPool();
        IERC20(underlying).transfer(to, amount);
    }
}

// ---- Mock Aave V3 pool ----
//
// We deliberately do NOT inherit IAaveV3Pool: the interface declares
// getReserveData with 15 named returns, which trips Solidity's stack-too-deep
// limit even when the body is empty. The strategy interacts with the pool via
// IAaveV3Pool dispatch on the address, so duck-typing on selector matches is
// sufficient and the strategy never calls getReserveData post audit-fix(7).
contract MockAavePool {
    address public asset;
    MockAToken public aToken;
    uint256 public config; // reserve configuration bitmap

    constructor(address asset_) {
        asset = asset_;
        aToken = new MockAToken(address(this), asset_);
        // Default: ACTIVE, not FROZEN, not PAUSED.
        config = ACTIVE_BIT;
    }

    function setConfig(uint256 newConfig) external {
        config = newConfig;
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        require(asset_ == asset, "asset mismatch");
        IERC20(asset).transferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        require(asset_ == asset, "asset mismatch");
        // Aave: type(uint256).max means "withdraw everything I have".
        uint256 cap = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max || amount > cap) amount = cap;
        // Hard-fail on insufficient pool liquidity — matches Aave's behavior
        // when reserves are illiquid, and is the surface that audit-fix(18)
        // protects against by capping the requested amount upstream.
        uint256 poolLiquidity = IERC20(asset).balanceOf(address(aToken));
        require(poolLiquidity >= amount, "insufficient liquidity");
        aToken.burn(msg.sender, amount);
        aToken.payOut(to, amount);
        return amount;
    }

    function getConfiguration(address) external view returns (uint256) {
        return config;
    }
}

// ---- Tests ----

contract AaveV3StrategyV1_2Test is Test {
    MockUSDC token;
    MockAavePool pool;
    MockAToken aToken;
    AaveV3StrategyV1_2 strategy;

    address vaultAddr = makeAddr("vault");
    uint256 constant SUPPLY = 100_000e6;

    function setUp() public {
        token = new MockUSDC();
        pool = new MockAavePool(address(token));
        aToken = pool.aToken();

        strategy = new AaveV3StrategyV1_2(address(token), address(pool), address(aToken), vaultAddr, address(0));

        // Seed the strategy with assets via the vault path.
        token.mint(vaultAddr, SUPPLY);
        vm.prank(vaultAddr);
        token.approve(address(strategy), type(uint256).max);
        vm.prank(vaultAddr);
        strategy.deposit(SUPPLY);
    }

    // =========================================================================
    // Audit fix #7 (Oak 2026-04-24): availableLiquidity respects PAUSED/inactive
    // =========================================================================

    function test_auditFix7_availableLiquidityIsZeroWhenPaused() public {
        assertGt(strategy.availableLiquidity(), 0, "precondition: liquidity available");

        pool.setConfig(ACTIVE_BIT | PAUSED_BIT);

        assertEq(
            strategy.availableLiquidity(),
            0,
            "paused reserve must report 0 liquidity"
        );
    }

    function test_auditFix7_availableLiquidityIsZeroWhenInactive() public {
        // Drop the ACTIVE bit (deprecated reserve).
        pool.setConfig(0);

        assertEq(
            strategy.availableLiquidity(),
            0,
            "inactive reserve must report 0 liquidity"
        );
    }

    function test_auditFix7_availableLiquidityIgnoresFrozenForWithdrawals() public {
        // Frozen blocks deposits but not withdrawals — withdrawals must still
        // see the live reserves.
        pool.setConfig(ACTIVE_BIT | FROZEN_BIT);

        assertGt(
            strategy.availableLiquidity(),
            0,
            "frozen reserve must still report withdrawal liquidity"
        );
    }

    // =========================================================================
    // Audit fix #8 (Oak 2026-04-24): isHealthy false on inactive/frozen/paused
    // =========================================================================

    function test_auditFix8_isHealthyFalseWhenFrozen() public {
        assertTrue(strategy.isHealthy(), "precondition: healthy");

        pool.setConfig(ACTIVE_BIT | FROZEN_BIT);

        assertFalse(
            strategy.isHealthy(),
            "frozen reserve must not be healthy (deposits disallowed)"
        );
    }

    function test_auditFix8_isHealthyFalseWhenPaused() public {
        pool.setConfig(ACTIVE_BIT | PAUSED_BIT);
        assertFalse(strategy.isHealthy(), "paused reserve must not be healthy");
    }

    function test_auditFix8_isHealthyFalseWhenInactive() public {
        pool.setConfig(0);
        assertFalse(strategy.isHealthy(), "inactive reserve must not be healthy");
    }

    // =========================================================================
    // Audit fix #18 (Oak 2026-04-24): emergencyWithdraw capped to liquid reserves
    // =========================================================================

    /// @notice Pre-fix, emergencyWithdraw called pool.withdraw(asset, type(uint).max, vault).
    ///         If the reserve was paused, that call reverted and the entire emergency
    ///         exit aborted — even though the strategy's tracked balance might still
    ///         be recoverable later. Post-fix, the strategy caps the request to
    ///         availableLiquidity, so a paused reserve returns 0 instead of reverting.
    function test_auditFix18_emergencyWithdrawReturnsZeroOnPausedReserve() public {
        pool.setConfig(ACTIVE_BIT | PAUSED_BIT);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();
        assertEq(withdrawn, 0, "paused reserve emergencyWithdraw must not revert and must return 0");
    }

    /// @notice When the reserve has only partial liquidity (e.g. heavily borrowed),
    ///         emergencyWithdraw recovers only the liquid portion instead of
    ///         reverting on insufficient-liquidity.
    function test_auditFix18_emergencyWithdrawCapsToAvailableLiquidity() public {
        // Drain half of the reserve to simulate borrow utilization.
        uint256 drain = SUPPLY / 2;
        // Move asset out of the aToken contract directly. forge's deal cheat
        // adjusts the balance without an actual transfer.
        deal(address(token), address(aToken), token.balanceOf(address(aToken)) - drain);

        uint256 liquid = strategy.availableLiquidity();
        assertEq(liquid, SUPPLY - drain, "precondition: half drained");

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();
        assertEq(withdrawn, SUPPLY - drain, "must recover only the liquid half");

        // Tracked aToken balance still reflects the unrecovered remainder.
        assertEq(
            aToken.balanceOf(address(strategy)),
            drain,
            "unrecovered aToken balance remains for later"
        );
    }
}
