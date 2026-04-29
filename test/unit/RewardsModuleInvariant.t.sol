// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockUSDCToken, MockRewardToken, MockStrategy} from "./shared/RewardsModuleTestBase.sol";

/// @dev Invariant handler router — accepts usdcOut as param (no pre-set state)
contract InvRouter {
    using SafeERC20 for IERC20;

    address public usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function doSwap(address tokenIn, uint256 amountIn, uint256 usdcOut) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(usdc).safeTransfer(msg.sender, usdcOut);
    }
}

// ========================================================================
// Handler: drives random operations on RewardsModuleV1_2
// ========================================================================

contract RewardsModuleHandler is Test {
    using SafeERC20 for IERC20;

    RewardsModuleV1_2 public module;
    TezoroV1_2 public vault;
    MockUSDCToken public usdc;
    MockRewardToken public rwd;
    InvRouter public router;

    address public admin;
    address public keeper;

    // Ghost variables for tracking
    uint256 public totalSwappedToModule; // USDC received via swaps
    uint256 public totalSweptToVault; // USDC sent to vault
    uint256 public totalRewardsMinted; // RWD minted to module
    uint256 public totalRescued; // RWD rescued from module

    constructor(
        RewardsModuleV1_2 module_,
        TezoroV1_2 vault_,
        MockUSDCToken usdc_,
        MockRewardToken rwd_,
        InvRouter router_,
        address admin_,
        address keeper_
    ) {
        module = module_;
        vault = vault_;
        usdc = usdc_;
        rwd = rwd_;
        router = router_;
        admin = admin_;
        keeper = keeper_;
    }

    /// @dev Simulate reward tokens arriving at the module
    function mintRewards(uint256 amount) external {
        amount = bound(amount, 1, 100_000e18);
        rwd.mint(address(module), amount);
        totalRewardsMinted += amount;
    }

    /// @dev Swap reward tokens for USDC
    function swap(uint256 rwdAmount, uint256 usdcAmount) external {
        uint256 available = rwd.balanceOf(address(module));
        if (available == 0) return;

        rwdAmount = bound(rwdAmount, 1, available);
        usdcAmount = bound(usdcAmount, 1, 1_000_000e6);

        // Fund router with USDC to give back
        usdc.mint(address(router), usdcAmount);

        bytes memory data = abi.encodeCall(InvRouter.doSwap, (address(rwd), rwdAmount, usdcAmount));

        vm.prank(keeper);
        module.swap(address(router), address(rwd), address(usdc), rwdAmount, 0, data);

        totalSwappedToModule += usdcAmount;
    }

    /// @dev Sweep USDC to vault
    function sweepToVault() external {
        uint256 balance = usdc.balanceOf(address(module));
        if (balance == 0) return;

        vm.prank(keeper);
        module.sweepToVault();

        totalSweptToVault += balance;
    }

    /// @dev Rescue non-base tokens
    function rescue(uint256 amount) external {
        uint256 available = rwd.balanceOf(address(module));
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(admin);
        module.rescueToken(address(rwd), admin, amount);

        totalRescued += amount;
    }
}

// ========================================================================
// Invariant Test Suite
// ========================================================================

contract RewardsModuleInvariantTest is Test {
    MockUSDCToken usdc;
    MockRewardToken rwd;
    TezoroV1_2 vault;
    RewardsModuleV1_2 module;
    MockStrategy strategy;
    InvRouter router;
    RewardsModuleHandler handler;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDCToken();
        rwd = new MockRewardToken("Reward", "RWD");
        router = new InvRouter(address(usdc));

        vault = new TezoroV1_2(
            IERC20(address(usdc)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            makeAddr("feeRecipient"),
            1_500,
            300
        );

        module = new RewardsModuleV1_2(address(vault), admin);
        strategy = new MockStrategy(address(usdc));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
        vault.setRewardsModule(address(module));
        module.setKeeper(keeper);
        module.setRouterWhitelist(address(router), true);
        vm.stopPrank();

        // Alice deposits so vault has shares
        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, alice);
        vm.stopPrank();

        handler = new RewardsModuleHandler(module, vault, usdc, rwd, router, admin, keeper);

        // Only target the handler
        targetContract(address(handler));
    }

    // =========================================================================
    // Invariant 1: Module USDC balance == swapped - swept
    // =========================================================================

    function invariant_moduleUsdcBalance_matchesGhosts() public view {
        uint256 moduleBalance = usdc.balanceOf(address(module));
        uint256 expected = handler.totalSwappedToModule() - handler.totalSweptToVault();
        assertEq(moduleBalance, expected, "Module USDC must equal swapped - swept");
    }

    // =========================================================================
    // Invariant 2: Module RWD balance <= total minted (never gained from nowhere)
    // =========================================================================

    function invariant_moduleRwdBalance_bounded() public view {
        uint256 moduleRwd = rwd.balanceOf(address(module));
        assertLe(moduleRwd, handler.totalRewardsMinted(), "RWD in module must not exceed total minted");
    }

    // =========================================================================
    // Invariant 3: Vault totalAssets >= initial deposit
    // =========================================================================

    function invariant_vaultTotalAssets_neverDecreasesFromRewards() public view {
        // Vault started with 1M USDC from Alice
        // Sweeps only add, never subtract
        uint256 total = vault.totalAssets();
        assertGe(total, 1_000_000e6, "Vault totalAssets must never decrease from rewards");
    }

    // =========================================================================
    // Invariant 4: Base asset rescue is permanently blocked
    // =========================================================================

    function invariant_baseAssetCannotBeRescued() public view {
        // rescueToken(baseAsset, ...) always reverts — verified by unit tests.
        // Here we just confirm the baseAsset hasn't changed.
        assertEq(module.baseAsset(), address(usdc), "Base asset must remain USDC");
    }

    // =========================================================================
    // Invariant 5: Router approval is always 0 outside of swap execution
    // =========================================================================

    function invariant_routerApprovalAlwaysZero() public view {
        uint256 approval = rwd.allowance(address(module), address(router));
        assertEq(approval, 0, "Router approval must be zero between transactions");
    }

    // =========================================================================
    // Invariant 6: Admin and vault are immutable
    // =========================================================================

    function invariant_vaultIsImmutable() public view {
        assertEq(module.vault(), address(vault), "Vault must never change");
        assertEq(module.baseAsset(), address(usdc), "Base asset must never change");
    }
}
