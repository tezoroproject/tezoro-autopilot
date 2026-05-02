// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CompoundV3StrategyV1_2} from "../../src/strategies/CompoundV3StrategyV1_2.sol";
import {ICompoundV3Comet} from "../../src/interfaces/ICompoundV3Comet.sol";

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

// ---- Mock Comet (Compound V3) ----
//
// Tracks per-account base-token positions (1:1 with supply, ignoring interest)
// and exposes the supply/withdraw pause flags the strategy reads. Holds the
// underlying asset directly — the strategy's availableLiquidity reads
// IERC20(asset).balanceOf(address(comet)).
contract MockComet is ICompoundV3Comet {
    address public override baseToken;
    bool public override isSupplyPaused;
    bool public override isWithdrawPaused;
    mapping(address => uint256) internal _bal;

    constructor(address baseToken_) {
        baseToken = baseToken_;
    }

    function setSupplyPaused(bool v) external {
        isSupplyPaused = v;
    }

    function setWithdrawPaused(bool v) external {
        isWithdrawPaused = v;
    }

    function supply(address asset_, uint256 amount) external override {
        require(asset_ == baseToken, "asset mismatch");
        require(!isSupplyPaused, "supply paused");
        IERC20(baseToken).transferFrom(msg.sender, address(this), amount);
        _bal[msg.sender] += amount;
    }

    function withdraw(address asset_, uint256 amount) external override {
        require(asset_ == baseToken, "asset mismatch");
        require(!isWithdrawPaused, "withdraw paused");
        require(_bal[msg.sender] >= amount, "insufficient position");
        require(IERC20(baseToken).balanceOf(address(this)) >= amount, "insufficient liquidity");
        _bal[msg.sender] -= amount;
        IERC20(baseToken).transfer(msg.sender, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _bal[account];
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }
}

// ---- Tests ----

contract CompoundV3StrategyV1_2Test is Test {
    MockUSDC token;
    MockComet comet;
    CompoundV3StrategyV1_2 strategy;

    address vaultAddr = makeAddr("vault");
    uint256 constant SUPPLY = 100_000e6;

    function setUp() public {
        token = new MockUSDC();
        comet = new MockComet(address(token));
        strategy = new CompoundV3StrategyV1_2(
            address(token),
            address(comet),
            vaultAddr,
            address(0), // no rewards
            address(0)
        );

        token.mint(vaultAddr, SUPPLY);
        vm.prank(vaultAddr);
        token.approve(address(strategy), type(uint256).max);
        vm.prank(vaultAddr);
        strategy.deposit(SUPPLY);
    }

    // =========================================================================
    // AvailableLiquidity respects withdraw pause
    // =========================================================================

    /// @notice Pre-fix, the strategy reported a non-zero availableLiquidity
    ///         even when Comet's withdraw flag was paused. The parent vault's
    ///         maxWithdraw/maxRedeem then over-promised, and a downstream
    ///         user redeem reverted at the Comet boundary.
    function test_availableLiquidityIsZeroWhenWithdrawPaused() public {
        assertGt(strategy.availableLiquidity(), 0, "precondition: liquidity available");

        comet.setWithdrawPaused(true);

        assertEq(
            strategy.availableLiquidity(),
            0,
            "withdraw-paused Comet must report 0 liquidity"
        );
    }

    /// @notice isHealthy must reflect both pause flags so the parent vault's
    ///         rebalancer skips deposits while either side is paused.
    function test_isHealthyFalseWhenSupplyPaused() public {
        assertTrue(strategy.isHealthy(), "precondition: healthy");
        comet.setSupplyPaused(true);
        assertFalse(strategy.isHealthy(), "supply-paused Comet must be unhealthy");
    }

    function test_isHealthyFalseWhenWithdrawPaused() public {
        comet.setWithdrawPaused(true);
        assertFalse(strategy.isHealthy(), "withdraw-paused Comet must be unhealthy");
    }

    // =========================================================================
    // Constructor validates Comet baseToken
    // =========================================================================

    /// @notice Pre-fix, deploying the strategy with a Comet whose baseToken
    ///         doesn't match `asset_` would silently push deposits down the
    ///         collateral path inside Comet, while the strategy's withdraw
    ///         and balanceOf paths (which assume base-supply) returned zero.
    ///         Funds stranded. Post-fix, the constructor reverts.
    function test_constructorRevertsOnBaseTokenMismatch() public {
        MockUSDC otherAsset = new MockUSDC();
        MockComet wrongBaseComet = new MockComet(address(otherAsset));

        vm.expectRevert(CompoundV3StrategyV1_2.BaseTokenMismatch.selector);
        new CompoundV3StrategyV1_2(
            address(token),
            address(wrongBaseComet),
            vaultAddr,
            address(0),
            address(0)
        );
    }

    /// @notice Sanity: matching baseToken passes — same construction the
    ///         setUp() already exercises, asserted explicitly so a future
    ///         tightening doesn't accidentally close the happy path.
    function test_constructorAcceptsMatchingBaseToken() public {
        // Reuse the existing comet — its baseToken == address(token).
        CompoundV3StrategyV1_2 ok = new CompoundV3StrategyV1_2(
            address(token),
            address(comet),
            vaultAddr,
            address(0),
            address(0)
        );
        assertEq(ok.asset(), address(token));
    }
}
