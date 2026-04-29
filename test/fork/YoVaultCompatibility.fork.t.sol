// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;

/// @notice Fork test: YO.xyz vault compatibility with ERC4626MultiStrategyV1_2.
///         YO vaults don't implement withdraw() — only redeem().
///         Tests verify the redeem-fallback in the strategy handles this correctly.
contract YoVaultCompatibilityTest is Test {
    using SafeERC20 for IERC20;

    IERC4626 yoVault = IERC4626(YO_USD);
    IERC20 usdc = IERC20(USDC);

    address user = makeAddr("user");
    uint256 constant AMOUNT = 10_000e6; // 10k USDC

    function setUp() public {
        vm.createSelectFork("ethereum");
        deal(USDC, user, AMOUNT * 2);
    }

    // ========== Raw vault checks ==========

    function test_basicInfo() public view {
        assertEq(yoVault.asset(), USDC, "asset should be USDC");
        assertGt(yoVault.totalAssets(), 0, "should have TVL");

        uint256 sharePrice = yoVault.convertToAssets(1e6);
        assertGe(sharePrice, 1e6, "share price should be >= 1:1");
    }

    function test_deposit() public {
        vm.startPrank(user);
        usdc.approve(YO_USD, AMOUNT);
        uint256 shares = yoVault.deposit(AMOUNT, user);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        assertEq(yoVault.balanceOf(user), shares, "balance should match");
    }

    function test_withdraw_reverts() public {
        vm.startPrank(user);
        usdc.approve(YO_USD, AMOUNT);
        yoVault.deposit(AMOUNT, user);

        uint256 maxW = yoVault.maxWithdraw(user);
        assertGt(maxW, 0, "maxWithdraw reports available liquidity");

        // But withdraw() itself reverts — YO doesn't implement it
        vm.expectRevert();
        yoVault.withdraw(maxW, user, user);
        vm.stopPrank();
    }

    function test_redeem_works() public {
        vm.startPrank(user);
        usdc.approve(YO_USD, AMOUNT);
        uint256 shares = yoVault.deposit(AMOUNT, user);

        uint256 balBefore = usdc.balanceOf(user);
        yoVault.redeem(shares, user, user);
        uint256 received = usdc.balanceOf(user) - balBefore;
        vm.stopPrank();

        assertGt(received, 0, "should receive assets via redeem");
    }

    // ========== ERC4626MultiStrategyV1_2 integration ==========

    function test_strategy_fullLifecycle() public {
        address vaultAddr = makeAddr("vault");
        address adminAddr = makeAddr("admin");
        address keeperAddr = makeAddr("keeper");

        // Deploy strategy with YO vault as sub-vault
        ERC4626MultiStrategyV1_2 strategy = new ERC4626MultiStrategyV1_2(
            USDC, vaultAddr, adminAddr, "YO USD", 8, new address[](0)
        );

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(YO_USD);
        vm.stopPrank();

        // Fund and deposit
        deal(USDC, vaultAddr, AMOUNT);
        vm.startPrank(vaultAddr);
        usdc.forceApprove(address(strategy), type(uint256).max);
        strategy.deposit(AMOUNT);
        vm.stopPrank();

        assertEq(strategy.balanceOf(), AMOUNT, "balance should match deposit");

        // Keeper allocates to YO vault
        vm.prank(keeperAddr);
        strategy.allocate(YO_USD, AMOUNT);

        uint256 balAfterAllocate = strategy.balanceOf();
        assertGe(balAfterAllocate, AMOUNT - 1e6, "most funds should be tracked");

        // Vault withdraws — this triggers the redeem fallback since YO doesn't support withdraw()
        uint256 vaultBalBefore = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(AMOUNT);
        uint256 vaultReceived = usdc.balanceOf(vaultAddr) - vaultBalBefore;

        // Should get most of the funds back (some rounding loss acceptable)
        // YO vault charges a variable exit fee (~1-3%), so use 96% tolerance
        assertGe(vaultReceived, AMOUNT * 96 / 100, "should recover >= 96% via redeem fallback");
    }

    function test_strategy_deallocate() public {
        address vaultAddr = makeAddr("vault");
        address adminAddr = makeAddr("admin");
        address keeperAddr = makeAddr("keeper");

        ERC4626MultiStrategyV1_2 strategy = new ERC4626MultiStrategyV1_2(
            USDC, vaultAddr, adminAddr, "YO USD", 8, new address[](0)
        );

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(YO_USD);
        vm.stopPrank();

        deal(USDC, vaultAddr, AMOUNT);
        vm.startPrank(vaultAddr);
        usdc.forceApprove(address(strategy), type(uint256).max);
        strategy.deposit(AMOUNT);
        vm.stopPrank();

        vm.prank(keeperAddr);
        strategy.allocate(YO_USD, AMOUNT);

        // Deallocate — should use redeem fallback
        uint256 idleBefore = usdc.balanceOf(address(strategy));
        vm.prank(keeperAddr);
        strategy.deallocate(YO_USD, AMOUNT / 2);
        uint256 idleAfter = usdc.balanceOf(address(strategy));

        uint256 deallocated = idleAfter - idleBefore;
        // YO vault charges a variable exit fee (~1-3%), so use 96% tolerance
        assertGe(deallocated, AMOUNT / 2 * 96 / 100, "should deallocate >= 96% via redeem fallback");
    }
}
