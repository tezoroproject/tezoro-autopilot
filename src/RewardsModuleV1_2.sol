// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITezoroVault} from "./interfaces/ITezoroVault.sol";

/// @title RewardsModuleV1_2
/// @notice Manages reward token claims, swaps, and auto-compounding into the vault.
///         Receives reward tokens from strategies during harvest. Claims merkle-based
///         rewards via whitelisted executeClaim. Swaps to base asset via whitelisted
///         DEX routers. Sweeps base asset back to vault via depositRewards().
/// @dev Security boundary: can ONLY send base asset to the vault. Even if fully
///      compromised, user deposits are safe -- only reward tokens at risk.
contract RewardsModuleV1_2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Immutables ---

    address public immutable vault;
    address public immutable baseAsset;

    // --- State ---

    address public admin;
    address public pendingAdmin;
    address public keeper;
    bool public paused;

    // Claims Executor: target address => function selector => allowed
    mapping(address => mapping(bytes4 => bool)) public claimWhitelist;

    // Swap Engine: router address => allowed
    mapping(address => bool) public allowedRouters;

    // --- Events ---

    event ClaimExecuted(address indexed target, bytes4 indexed selector);
    event Swapped(
        address indexed router, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event SweptToVault(uint256 amount);
    event ClaimWhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event RouterWhitelistUpdated(address indexed router, bool allowed);
    event AdminTransferProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event Paused();
    event Unpaused();

    // --- Errors ---

    error NotAdmin();
    error NotPendingAdmin();
    error NotAdminOrKeeper();
    error ZeroAddress();
    error TargetNotWhitelisted();
    error TargetHasNoCode();
    error RouterNotWhitelisted();
    error InvalidTokenOut();
    error SlippageExceeded();
    error ClaimFailed();
    error NothingToSweep();
    error CannotRescueBaseAsset();
    error CannotSwapBaseAsset();
    error SwapCallFailed();
    /// @dev Thrown when swap is called with minAmountOut == 0. A zero floor
    ///      would disable the only on-chain slippage check, letting a
    ///      benign-but-buggy keeper integration silently lose reward MEV to
    ///      thin liquidity or adverse routing.
    error ZeroMinAmountOut();
    error IsPaused();

    // --- Modifiers ---

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrKeeper() {
        if (msg.sender != admin && msg.sender != keeper) revert NotAdminOrKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // --- Constructor ---

    constructor(address vault_, address admin_) {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        vault = vault_;
        baseAsset = ITezoroVault(vault_).asset();
        admin = admin_;
    }

    // =========================================================================
    // Claims Executor
    // =========================================================================

    /// @notice Selector for Morpho-style Universal Reward Distributor claims.
    ///         claim(address account, address reward, uint256 claimable, bytes32[] proof)
    /// @dev Typed wrapper claimMorphoUrd binds `account` to
    ///      address(this) on-chain, so the URD cannot redirect rewards even
    ///      if its calldata exposed a free recipient field.
    bytes4 public constant MORPHO_URD_CLAIM_SELECTOR =
        bytes4(keccak256("claim(address,address,uint256,bytes32[])"));

    /// @notice Selector for Merkl-style distributor claims.
    ///         claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
    /// @dev Typed wrapper claimMerkl binds every entry of
    ///      `users` to address(this) on-chain.
    bytes4 public constant MERKL_CLAIM_SELECTOR =
        bytes4(keccak256("claim(address[],address[],uint256[],bytes32[][])"));

    /// @notice Execute a claim call on a whitelisted target. Used for any
    ///         claim format that doesn't have a typed wrapper below.
    /// @dev    TRUST BOUNDARY: this path forwards raw calldata. The whitelist
    ///         entry (target+selector) does NOT enforce the recipient field,
    ///         so an admin/keeper relying on this path must add only targets
    ///         whose payout destination is fixed inside verified proof data
    ///         (not exposed as a free parameter). For Morpho URD and Merkl
    ///         flows, prefer claimMorphoUrd / claimMerkl below — they pin
    ///         the recipient to address(this) on-chain.
    /// @param target The contract to call
    /// @param data The calldata (must match a whitelisted selector)
    function executeClaim(address target, bytes calldata data) external onlyAdminOrKeeper whenNotPaused nonReentrant {
        if (target.code.length == 0) revert TargetHasNoCode();
        if (data.length < 4) revert TargetNotWhitelisted();
        bytes4 selector = bytes4(data[:4]);
        if (!claimWhitelist[target][selector]) revert TargetNotWhitelisted();

        (bool success,) = target.call(data);
        if (!success) revert ClaimFailed();

        emit ClaimExecuted(target, selector);
    }

    /// @notice Typed wrapper for Morpho-style URD claims.
    ///         The `account` parameter (claim recipient) is hardcoded to
    ///         address(this); the URD cannot route the reward elsewhere even
    ///         if a future whitelist addition exposed a free recipient field.
    function claimMorphoUrd(
        address urd,
        address rewardToken,
        uint256 claimable,
        bytes32[] calldata proof
    ) external onlyAdminOrKeeper whenNotPaused nonReentrant {
        if (urd.code.length == 0) revert TargetHasNoCode();
        if (!claimWhitelist[urd][MORPHO_URD_CLAIM_SELECTOR]) revert TargetNotWhitelisted();

        (bool success,) = urd.call(
            abi.encodeWithSelector(
                MORPHO_URD_CLAIM_SELECTOR,
                address(this),
                rewardToken,
                claimable,
                proof
            )
        );
        if (!success) revert ClaimFailed();

        emit ClaimExecuted(urd, MORPHO_URD_CLAIM_SELECTOR);
    }

    /// @notice Typed wrapper for Merkl-style distributor claims.
    ///         Every entry of `users` is forced to address(this); the
    ///         distributor cannot route the reward elsewhere.
    function claimMerkl(
        address distributor,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external onlyAdminOrKeeper whenNotPaused nonReentrant {
        if (distributor.code.length == 0) revert TargetHasNoCode();
        if (!claimWhitelist[distributor][MERKL_CLAIM_SELECTOR]) revert TargetNotWhitelisted();

        address[] memory users = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            users[i] = address(this);
        }

        (bool success,) = distributor.call(
            abi.encodeWithSelector(
                MERKL_CLAIM_SELECTOR,
                users,
                tokens,
                amounts,
                proofs
            )
        );
        if (!success) revert ClaimFailed();

        emit ClaimExecuted(distributor, MERKL_CLAIM_SELECTOR);
    }

    /// @notice Add or remove a target+selector pair from the claims whitelist
    function setClaimWhitelist(address target, bytes4 selector, bool allowed) external onlyAdmin {
        claimWhitelist[target][selector] = allowed;
        emit ClaimWhitelistUpdated(target, selector, allowed);
    }

    // =========================================================================
    // Swap Engine
    // =========================================================================

    /// @notice Swap reward tokens to the vault's base asset via a whitelisted router.
    /// @param router The DEX aggregator router (must be whitelisted)
    /// @param tokenIn The reward token to sell
    /// @param tokenOut Must be baseAsset (enforced)
    /// @param amountIn Amount of tokenIn to swap
    /// @param minAmountOut Minimum output (slippage protection)
    /// @param routerData Encoded swap calldata for the router
    function swap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routerData
    ) external onlyAdminOrKeeper whenNotPaused nonReentrant {
        if (!allowedRouters[router]) revert RouterNotWhitelisted();
        if (tokenOut != baseAsset) revert InvalidTokenOut();
        if (tokenIn == baseAsset) revert CannotSwapBaseAsset();
        // Reject zero slippage floor — pre-fix the swap accepted minAmountOut == 0,
        // which disabled the only on-chain output guard and reduced
        // slippage protection to "trust the keeper-supplied calldata".
        if (minAmountOut == 0) revert ZeroMinAmountOut();

        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balanceBefore = IERC20(baseAsset).balanceOf(address(this));

        (bool success,) = router.call(routerData);
        if (!success) revert SwapCallFailed();

        uint256 balanceAfter = IERC20(baseAsset).balanceOf(address(this));
        uint256 amountOut = balanceAfter - balanceBefore;

        if (amountOut < minAmountOut) revert SlippageExceeded();

        // Reset approval for safety
        IERC20(tokenIn).forceApprove(router, 0);

        emit Swapped(router, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Add or remove a router from the swap whitelist
    function setRouterWhitelist(address router, bool allowed) external onlyAdmin {
        allowedRouters[router] = allowed;
        emit RouterWhitelistUpdated(router, allowed);
    }

    // =========================================================================
    // Sweep to Vault
    // =========================================================================

    /// @notice Send all base asset balance to the vault via depositRewards().
    ///         This is the ONLY way assets leave this contract to the vault.
    function sweepToVault() external onlyAdminOrKeeper whenNotPaused nonReentrant {
        uint256 balance = IERC20(baseAsset).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        IERC20(baseAsset).forceApprove(vault, balance);
        ITezoroVault(vault).depositRewards(balance);

        emit SweptToVault(balance);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        emit AdminTransferred(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    function setKeeper(address newKeeper) external onlyAdmin {
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    /// @notice Rescue stuck tokens (e.g., tokens sent accidentally).
    ///         Cannot rescue the base asset -- that goes through sweepToVault().
    function rescueToken(address token, address to, uint256 amount) external onlyAdmin {
        if (token == baseAsset) revert CannotRescueBaseAsset();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
