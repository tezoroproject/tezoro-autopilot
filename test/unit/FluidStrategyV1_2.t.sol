// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {FluidStrategyV1_2} from "../../src/strategies/FluidStrategyV1_2.sol";

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

// ---- Mock fToken with Liquidity-layer cap ----
//
// Fluid's fTokens are ERC-4626 vaults but assets sit in a separate Liquidity
// layer, not in the fToken itself. The Liquidity layer enforces a per-tx
// withdrawal/redeem cap (utilisation, paused asset). We model that cap via
// `liquidityLayerCap`: maxRedeem caps to it, and redeem reverts when the
// requested share amount would exceed it.
contract MockFToken is ERC4626 {
    uint256 public liquidityLayerCap = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Fluid USDC", "fUSDC") {}

    function setLiquidityLayerCap(uint256 cap) external {
        liquidityLayerCap = cap;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 shares = balanceOf(owner);
        return shares > liquidityLayerCap ? liquidityLayerCap : shares;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(shares <= liquidityLayerCap, "Liquidity-layer cap");
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        require(convertToShares(assets) <= liquidityLayerCap, "Liquidity-layer cap");
        return super.withdraw(assets, receiver, owner);
    }
}

// ---- Tests ----

contract FluidStrategyV1_2Test is Test {
    MockUSDC token;
    MockFToken fToken;
    FluidStrategyV1_2 strategy;

    address vaultAddr = makeAddr("vault");
    uint256 constant SUPPLY = 100_000e6;

    function setUp() public {
        token = new MockUSDC();
        fToken = new MockFToken(IERC20(address(token)));
        strategy = new FluidStrategyV1_2(address(token), address(fToken), vaultAddr);

        token.mint(vaultAddr, SUPPLY);
        vm.prank(vaultAddr);
        token.approve(address(strategy), type(uint256).max);
        vm.prank(vaultAddr);
        strategy.deposit(SUPPLY);
    }

    // =========================================================================
    // Audit fix #20 (Oak 2026-04-24): emergencyWithdraw caps to maxRedeem
    // =========================================================================

    /// @notice Pre-fix, emergencyWithdraw redeemed the full share balance
    ///         unconditionally. A temporary Liquidity-layer cap (Fluid utilisation
    ///         spike, paused asset) caused fToken.redeem to revert and the
    ///         entire emergency exit aborted — removeStrategy then surfaced
    ///         the cap as StrategyRemovalFundsLost even though the position
    ///         was recoverable in stages. Post-fix we cap to maxRedeem and
    ///         recover whatever the protocol can service this transaction.
    function test_auditFix20_emergencyWithdrawCapsToMaxRedeem() public {
        uint256 sharesHeld = fToken.balanceOf(address(strategy));
        // Cap recovery to half — models a Liquidity-layer at 50% utilisation.
        uint256 cap = sharesHeld / 2;
        fToken.setLiquidityLayerCap(cap);

        uint256 vaultBefore = token.balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        // Recovered roughly half the position (1:1 share/asset rate at start).
        assertApproxEqAbs(withdrawn, SUPPLY / 2, 2, "must recover the capped half");
        assertEq(
            token.balanceOf(vaultAddr) - vaultBefore,
            withdrawn,
            "vault must receive the recovered amount"
        );
        // Residual position remains for a follow-up call when liquidity returns.
        assertGt(fToken.balanceOf(address(strategy)), 0, "residual must remain");
    }

    /// @notice When the Liquidity-layer cap is zero (asset paused), the call
    ///         must return 0 instead of reverting — same defensive shape as
    ///         AaveV3StrategyV1_2.emergencyWithdraw post audit-fix(18).
    function test_auditFix20_emergencyWithdrawReturnsZeroWhenFullyCapped() public {
        fToken.setLiquidityLayerCap(0);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertEq(withdrawn, 0, "fully-capped fToken emergencyWithdraw must not revert");
    }

    /// @notice Happy path: when no cap is set, emergencyWithdraw still drains
    ///         the full position. Guards against a regression where the new
    ///         min() math accidentally clipped the unconstrained case.
    function test_auditFix20_emergencyWithdrawDrainsWhenUncapped() public {
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertApproxEqAbs(withdrawn, SUPPLY, 2);
        assertEq(fToken.balanceOf(address(strategy)), 0, "position fully drained");
    }

    // =========================================================================
    // Audit fix #26 (Oak 2026-04-24): constructor validates fToken asset
    // =========================================================================

    /// @notice Pre-fix the constructor accepted asset_ and fToken_ as
    ///         independent inputs. Mismatched fToken would deploy cleanly,
    ///         enter production, and only fail at the first live deposit
    ///         (atomic revert; no silent loss, but a broken configuration
    ///         shipped to operations). Post-fix, fail fast at deployment.
    function test_auditFix26_constructorRevertsOnFTokenAssetMismatch() public {
        MockUSDC otherAsset = new MockUSDC();
        MockFToken wrongFToken = new MockFToken(IERC20(address(otherAsset)));

        vm.expectRevert(FluidStrategyV1_2.FluidTokenMismatch.selector);
        new FluidStrategyV1_2(address(token), address(wrongFToken), vaultAddr);
    }

    /// @notice Sanity / happy path: a matching fToken passes the new check.
    function test_auditFix26_constructorAcceptsMatchingFToken() public {
        // Reuse the existing fToken — its asset() == address(token).
        FluidStrategyV1_2 ok = new FluidStrategyV1_2(address(token), address(fToken), vaultAddr);
        assertEq(ok.asset(), address(token));
    }
}
