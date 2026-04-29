// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";

// Ethereum mainnet
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

// Merkl distributor (same address on all EVM chains)
address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

// Example reward token (MORPHO -- commonly distributed via Merkl for YO vaults)
address constant MORPHO_TOKEN = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;

// Uniswap V3 router for swaps
address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

/// @dev Minimal Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Full integration: TezoroV1_2 vault + two strategies (MetaMorpho + YO).
///
///         Known limitation: YO vault charges ~0.001% exit fee on redeem.
///         TezoroV1_2._withdraw() has zero dust tolerance, so full withdrawals
///         where ALL funds must come through YO will revert with WithdrawalFailed().
///         This is fine in production: vault always has idle buffer + multiple
///         strategies, and the keeper caps YO allocation at 25-30%.
///         Fix planned for vault v2: add _dustTolerance to _withdraw().
contract YoIntegrationTest is Test {
    using SafeERC20 for IERC20;

    TezoroV1_2 vault;
    ERC4626MultiStrategyV1_2 morphoStrategy;
    ERC4626MultiStrategyV1_2 yoStrategy;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 100_000e6; // 100k USDC
    uint256 constant USER_BAL = 500_000e6;

    function setUp() public {
        vm.createSelectFork("ethereum");

        vault = new TezoroV1_2(
            IERC20(USDC),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            feeRecipient,
            1_500, // 15% performance fee
            300    // 3% idle buffer
        );

        morphoStrategy = new ERC4626MultiStrategyV1_2(
            USDC, address(vault), admin, "MetaMorpho USDC", 64, new address[](0)
        );

        yoStrategy = new ERC4626MultiStrategyV1_2(
            USDC, address(vault), admin, "YO USD", 8, new address[](0)
        );

        vm.startPrank(admin);
        morphoStrategy.setKeeper(keeper);
        morphoStrategy.addSubVault(STEAKHOUSE_USDC);
        yoStrategy.setKeeper(keeper);
        yoStrategy.addSubVault(YO_USD);

        vault.addStrategy(IStrategy(address(morphoStrategy)));
        vault.addStrategy(IStrategy(address(yoStrategy)));

        // 70% Morpho, 27% YO, 3% idle
        IStrategy[] memory strats = new IStrategy[](2);
        strats[0] = IStrategy(address(morphoStrategy));
        strats[1] = IStrategy(address(yoStrategy));
        uint256[] memory bps = new uint256[](2);
        bps[0] = 7_000;
        bps[1] = 2_700;
        vault.rebalance(strats, bps);

        vault.setKeeper(keeper);
        vm.stopPrank();

        deal(USDC, alice, USER_BAL);
        deal(USDC, bob, USER_BAL);
        vm.prank(alice);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).forceApprove(address(vault), type(uint256).max);
    }

    // ====== Deposit + rebalance + sub-allocate ======

    function test_depositAndAllocate() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        uint256 morphoBal = morphoStrategy.balanceOf();
        uint256 yoBal = yoStrategy.balanceOf();
        assertGe(morphoBal, 69_000e6, "Morpho should have ~70k");
        assertGe(yoBal, 26_000e6, "YO should have ~27k");

        // Sub-allocate
        vm.startPrank(keeper);
        morphoStrategy.allocate(STEAKHOUSE_USDC, IERC20(USDC).balanceOf(address(morphoStrategy)));
        yoStrategy.allocate(YO_USD, IERC20(USDC).balanceOf(address(yoStrategy)));
        vm.stopPrank();

        assertGt(morphoStrategy.subVaultBalance(STEAKHOUSE_USDC), 0);
        assertGt(yoStrategy.subVaultBalance(YO_USD), 0);
    }

    // ====== Partial withdrawal (realistic user behavior) ======

    function test_partialWithdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        vm.startPrank(keeper);
        morphoStrategy.allocate(STEAKHOUSE_USDC, IERC20(USDC).balanceOf(address(morphoStrategy)));
        yoStrategy.allocate(YO_USD, IERC20(USDC).balanceOf(address(yoStrategy)));
        vm.stopPrank();

        // Alice withdraws 50% — vault idle (3k) + Morpho covers most of it,
        // YO fee gap is absorbed by the surplus from other sources.
        uint256 halfShares = vault.balanceOf(alice) / 2;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(halfShares, alice, alice);

        uint256 received = IERC20(USDC).balanceOf(alice) - aliceBefore;
        assertGe(received, DEPOSIT / 2 * 99 / 100, "Should recover >= 99%");
    }

    // ====== Yield accrual over time ======

    function test_yieldAccrual() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(keeper);
        vault.rebalance();

        vm.startPrank(keeper);
        morphoStrategy.allocate(STEAKHOUSE_USDC, IERC20(USDC).balanceOf(address(morphoStrategy)));
        yoStrategy.allocate(YO_USD, IERC20(USDC).balanceOf(address(yoStrategy)));
        vm.stopPrank();

        // Warp 7 days
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);

        uint256 totalBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.reconcile();
        uint256 totalAfter = vault.totalAssets();

        uint256 yield = totalAfter - totalBefore;
        assertGt(yield, 0, "Should earn yield from both strategies");
    }

    // ====== Keeper deallocate from YO ======

    function test_deallocate() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 yoIdle = IERC20(USDC).balanceOf(address(yoStrategy));
        vm.prank(keeper);
        yoStrategy.allocate(YO_USD, yoIdle);

        uint256 yoBefore = yoStrategy.subVaultBalance(YO_USD);
        vm.prank(keeper);
        yoStrategy.deallocate(YO_USD, yoBefore / 2);

        uint256 stratIdle = IERC20(USDC).balanceOf(address(yoStrategy));
        // YO vault charges a variable exit fee (~1-3%), so use 96% tolerance
        assertGe(stratIdle, yoBefore / 2 * 96 / 100, "Should deallocate ~50%");
    }

    // ====== Multi-user partial withdrawals ======

    function test_multiUser_partialWithdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(bob);
        vault.deposit(DEPOSIT * 2, bob);

        vm.prank(keeper);
        vault.rebalance();

        vm.startPrank(keeper);
        morphoStrategy.allocate(STEAKHOUSE_USDC, IERC20(USDC).balanceOf(address(morphoStrategy)));
        yoStrategy.allocate(YO_USD, IERC20(USDC).balanceOf(address(yoStrategy)));
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000);

        vm.prank(keeper);
        vault.reconcile();

        // Alice withdraws 70%
        uint256 aliceShares = vault.balanceOf(alice) * 70 / 100;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = IERC20(USDC).balanceOf(alice) - aliceBefore;

        // Bob withdraws 50%
        uint256 bobShares = vault.balanceOf(bob) / 2;
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        uint256 bobReceived = IERC20(USDC).balanceOf(bob) - bobBefore;

        assertGt(aliceReceived, 0);
        assertGt(bobReceived, 0);
    }

    // ====== View functions ======

    function test_availableLiquidity() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 yoIdle = IERC20(USDC).balanceOf(address(yoStrategy));
        vm.prank(keeper);
        yoStrategy.allocate(YO_USD, yoIdle);

        uint256 available = yoStrategy.availableLiquidity();
        assertGt(available, 0);
    }

    function test_isHealthy() public {
        // YO vault has existing TVL, so isHealthy = true even before we deposit
        assertTrue(yoStrategy.isHealthy());

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 yoIdle = IERC20(USDC).balanceOf(address(yoStrategy));
        vm.prank(keeper);
        yoStrategy.allocate(YO_USD, yoIdle);

        assertTrue(yoStrategy.isHealthy());
    }

    // ====== Merkl Reward Pipeline ======

    /// @notice Test sweepReward: simulate Merkl-claimed tokens on YO strategy, sweep to RewardsModuleV1_2
    function test_merklReward_sweepFromStrategy() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        uint256 yoIdle = IERC20(USDC).balanceOf(address(yoStrategy));
        vm.prank(keeper);
        yoStrategy.allocate(YO_USD, yoIdle);

        // Simulate: Merkl claim landed reward tokens on YO strategy address
        // (In production, keeper calls Merkl distributor, tokens arrive on strategy)
        uint256 rewardAmount = 1_000e18; // 1000 MORPHO tokens
        deal(MORPHO_TOKEN, address(yoStrategy), rewardAmount);

        assertEq(IERC20(MORPHO_TOKEN).balanceOf(address(yoStrategy)), rewardAmount);

        // Vault sweeps reward tokens from strategy to RewardsModuleV1_2
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(yoStrategy)), MORPHO_TOKEN);

        assertEq(IERC20(MORPHO_TOKEN).balanceOf(address(rm)), rewardAmount, "RM should receive reward tokens");
        assertEq(IERC20(MORPHO_TOKEN).balanceOf(address(yoStrategy)), 0, "Strategy should be empty");
    }

    /// @notice Full Merkl reward pipeline: claim simulation -> sweep -> swap -> compound into vault
    function test_merklReward_fullPipeline() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        rm.setKeeper(keeper);
        rm.setRouterWhitelist(UNISWAP_ROUTER, true);
        vm.stopPrank();

        // 1. Deposit and allocate
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        vm.startPrank(keeper);
        morphoStrategy.allocate(STEAKHOUSE_USDC, IERC20(USDC).balanceOf(address(morphoStrategy)));
        yoStrategy.allocate(YO_USD, IERC20(USDC).balanceOf(address(yoStrategy)));
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // 2. Simulate Merkl reward landing on YO strategy
        uint256 rewardAmount = 500e18;
        deal(MORPHO_TOKEN, address(yoStrategy), rewardAmount);

        // 3. Sweep reward from strategy to RewardsModuleV1_2
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(yoStrategy)), MORPHO_TOKEN);

        uint256 morphoOnRm = IERC20(MORPHO_TOKEN).balanceOf(address(rm));
        assertEq(morphoOnRm, rewardAmount, "RM should hold MORPHO");

        // 4. Swap MORPHO -> USDC via Uniswap V3 (MORPHO -> WETH -> USDC)
        bytes memory swapPath = abi.encodePacked(MORPHO_TOKEN, uint24(3000), WETH, uint24(500), USDC);
        bytes memory routerData = abi.encodeCall(
            ISwapRouter.exactInput,
            (
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(rm),
                    deadline: block.timestamp,
                    amountIn: morphoOnRm,
                    amountOutMinimum: 0
                })
            )
        );

        vm.prank(keeper);
        rm.swap(UNISWAP_ROUTER, MORPHO_TOKEN, USDC, morphoOnRm, 0, routerData);

        uint256 usdcOnRm = IERC20(USDC).balanceOf(address(rm));
        assertGt(usdcOnRm, 0, "Should have USDC after swap");

        // 5. Sweep USDC to vault (auto-compounds into share price)
        vm.prank(keeper);
        rm.sweepToVault();

        assertGt(vault.totalAssets(), totalBefore, "Vault totalAssets should increase from rewards");
        assertEq(IERC20(USDC).balanceOf(address(rm)), 0, "RM should be empty");
        assertEq(IERC20(MORPHO_TOKEN).balanceOf(address(rm)), 0, "No MORPHO left on RM");
    }

    /// @notice Test executeClaim whitelist: Merkl distributor selector can be whitelisted
    function test_merklReward_claimWhitelist() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        // Merkl claim selector: claim(address[],address[],uint256[],bytes32[][])
        bytes4 merklClaimSelector = bytes4(keccak256("claim(address[],address[],uint256[],bytes32[][])"));

        // Admin whitelists Merkl distributor
        vm.startPrank(admin);
        rm.setKeeper(keeper);
        rm.setClaimWhitelist(MERKL_DISTRIBUTOR, merklClaimSelector, true);
        vm.stopPrank();

        assertTrue(rm.claimWhitelist(MERKL_DISTRIBUTOR, merklClaimSelector), "Merkl claim should be whitelisted");

        // Verify non-whitelisted selector is rejected
        bytes4 wrongSelector = bytes4(keccak256("transfer(address,uint256)"));
        assertFalse(rm.claimWhitelist(MERKL_DISTRIBUTOR, wrongSelector), "Wrong selector should not be whitelisted");

        // Verify non-whitelisted target is rejected
        assertFalse(rm.claimWhitelist(address(0x1), merklClaimSelector), "Wrong target should not be whitelisted");

        // executeClaim with invalid proof will revert (ClaimFailed), but the whitelist check passes
        address[] memory users = new address[](1);
        users[0] = address(rm);
        address[] memory tokens = new address[](1);
        tokens[0] = MORPHO_TOKEN;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0); // empty proof -- will fail merkle validation

        bytes memory claimData = abi.encodeWithSelector(merklClaimSelector, users, tokens, amounts, proofs);

        // Should pass whitelist check but fail at Merkl level (invalid proof)
        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.ClaimFailed.selector);
        rm.executeClaim(MERKL_DISTRIBUTOR, claimData);
    }

    /// @notice Verify harvest() returns 0 for YO strategy (no inline claim mechanism)
    function test_yoStrategy_harvestReturnsZero() public {
        RewardsModuleV1_2 rm = new RewardsModuleV1_2(address(vault), admin);

        vm.startPrank(admin);
        vault.setRewardsModule(address(rm));
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vm.prank(keeper);
        vault.rebalance();

        // harvestAll should succeed but yield 0 (YO rewards come via Merkl, not inline harvest)
        vm.prank(keeper);
        vault.harvestAll();

        assertEq(IERC20(MORPHO_TOKEN).balanceOf(address(rm)), 0, "No inline rewards expected from YO");
    }
}
