// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {IMorpho, MarketParams, MorphoMarket, Position, Id} from "../../src/interfaces/IMorpho.sol";

// ---- Mock ERC-20 ----

contract MockToken is ERC20 {
    uint8 internal _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

// ---- Mock ERC-4626 vault ----

contract MockVault4626 is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Vault", "mVAULT") {}
}

// ---- Mock Morpho ----

contract MockMorpho {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Market {
        address loanToken;
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
    }

    // marketId -> supplier -> shares
    mapping(bytes32 => mapping(address => uint256)) public supplyShares;
    mapping(bytes32 => Market) public markets;

    function supply(
        MarketParams memory mp,
        uint256 assets,
        uint256,
        address onBehalf,
        bytes calldata
    ) external returns (uint256 assetsOut, uint256 sharesOut) {
        Id mid = Id.wrap(keccak256(abi.encode(mp)));
        bytes32 key = Id.unwrap(mid);

        IERC20(mp.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        Market storage m = markets[key];
        if (m.loanToken == address(0)) {
            m.loanToken = mp.loanToken;
        }

        // 1:1 shares for simplicity
        sharesOut = assets;
        m.totalSupplyAssets += uint128(assets);
        m.totalSupplyShares += uint128(sharesOut);
        supplyShares[key][onBehalf] += sharesOut;

        return (assets, sharesOut);
    }

    function withdraw(
        MarketParams memory mp,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsOut, uint256 sharesOut) {
        Id mid = Id.wrap(keccak256(abi.encode(mp)));
        bytes32 key = Id.unwrap(mid);
        Market storage m = markets[key];

        if (shares > 0) {
            // Withdraw by shares
            sharesOut = shares;
            assetsOut = uint256(shares).mulDiv(uint256(m.totalSupplyAssets), uint256(m.totalSupplyShares));
        } else {
            // Withdraw by assets
            assetsOut = assets;
            sharesOut = assets.mulDiv(uint256(m.totalSupplyShares), uint256(m.totalSupplyAssets));
        }

        supplyShares[key][onBehalf] -= sharesOut;
        m.totalSupplyAssets -= uint128(assetsOut);
        m.totalSupplyShares -= uint128(sharesOut);

        IERC20(mp.loanToken).safeTransfer(receiver, assetsOut);
        return (assetsOut, sharesOut);
    }

    function position(Id mid, address user) external view returns (Position memory pos) {
        bytes32 key = Id.unwrap(mid);
        pos.supplyShares = uint128(supplyShares[key][user]);
    }

    function market(Id mid) external view returns (MorphoMarket memory m) {
        bytes32 key = Id.unwrap(mid);
        Market storage stored = markets[key];
        m.totalSupplyAssets = stored.totalSupplyAssets;
        m.totalSupplyShares = stored.totalSupplyShares;
        m.totalBorrowAssets = 0;
    }

    function accrueInterest(MarketParams memory) external {}

    // 1:1 shares in this mock, so supply assets == shares
    function expectedSupplyAssets(MarketParams memory mp, address user) external view returns (uint256) {
        Id mid = Id.wrap(keccak256(abi.encode(mp)));
        bytes32 key = Id.unwrap(mid);
        Market storage m = markets[key];
        uint256 shares = supplyShares[key][user];
        if (shares == 0 || m.totalSupplyShares == 0) return 0;
        return Math.mulDiv(shares, uint256(m.totalSupplyAssets), uint256(m.totalSupplyShares));
    }

    function expectedMarketBalances(MarketParams memory mp)
        external
        view
        returns (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares)
    {
        Id mid = Id.wrap(keccak256(abi.encode(mp)));
        bytes32 key = Id.unwrap(mid);
        Market storage m = markets[key];
        return (uint256(m.totalSupplyAssets), uint256(m.totalSupplyShares), 0, 0);
    }
}

// ====================
// ERC4626 Freeze Tests
// ====================

contract ERC4626MultiFreezeTest is Test {
    MockToken token;
    MockVault4626 subVaultA;
    MockVault4626 subVaultB;
    ERC4626MultiStrategyV1_2 strategy;

    address vaultAddr;
    address adminAddr;
    address keeperAddr;
    address randomUser;

    function setUp() public {
        vaultAddr = makeAddr("vault");
        adminAddr = makeAddr("admin");
        keeperAddr = makeAddr("keeper");
        randomUser = makeAddr("random");

        token = new MockToken("USD Coin", "USDC", 6);
        subVaultA = new MockVault4626(IERC20(address(token)));
        subVaultB = new MockVault4626(IERC20(address(token)));

        strategy = new ERC4626MultiStrategyV1_2(address(token), vaultAddr, adminAddr, "ERC4626 Multi", 64, new address[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addSubVault(address(subVaultA));
        strategy.addSubVault(address(subVaultB));
        vm.stopPrank();
    }

    // ========== freezeSubVaultDeposits ==========

    function test_freezeSubVaultDeposits_works() public {
        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        assertTrue(strategy.depositFrozenSubVaults(address(subVaultA)));
        assertFalse(strategy.depositFrozenSubVaults(address(subVaultB)));
    }

    function test_freezeSubVaultDeposits_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.SubVaultDepositFrozen(address(subVaultA));

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));
    }

    function test_freezeSubVaultDeposits_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.freezeSubVaultDeposits(address(subVaultA));
    }

    function test_freezeSubVaultDeposits_revertsIfNotApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.freezeSubVaultDeposits(makeAddr("unknown"));
    }

    function test_freezeSubVaultDeposits_revertsIfAlreadyFrozen() public {
        vm.startPrank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultAlreadyDepositFrozen.selector);
        strategy.freezeSubVaultDeposits(address(subVaultA));
        vm.stopPrank();
    }

    // ========== unfreezeSubVaultDeposits ==========

    function test_unfreezeSubVaultDeposits_works() public {
        vm.startPrank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));
        strategy.unfreezeSubVaultDeposits(address(subVaultA));
        vm.stopPrank();

        assertFalse(strategy.depositFrozenSubVaults(address(subVaultA)));
    }

    function test_unfreezeSubVaultDeposits_emitsEvent() public {
        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.SubVaultDepositUnfrozen(address(subVaultA));

        vm.prank(adminAddr);
        strategy.unfreezeSubVaultDeposits(address(subVaultA));
    }

    function test_unfreezeSubVaultDeposits_revertsIfNotFrozen() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotDepositFrozen.selector);
        strategy.unfreezeSubVaultDeposits(address(subVaultA));
    }

    // ========== allocate reverts if frozen ==========

    function test_allocate_revertsIfFrozen() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(address(subVaultA), 500e6);
    }

    function test_allocate_worksOnUnfrozenSubVault() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        // Sub-vault B should still work
        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultB), 500e6);

        assertGt(strategy.subVaultBalance(address(subVaultB)), 0);
    }

    // ========== withdraw waterfall includes frozen sub-vaults ==========

    function test_withdraw_includesFrozenSubVault() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 800e6);

        // Freeze A
        vm.prank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));

        // Withdraw should still pull from frozen sub-vault A
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(900e6);

        assertGe(withdrawn, 899e6);
    }

    // ========== recallSubVault ==========

    function test_recallSubVault_redeemsAllAndFreezes() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        uint256 totalBefore = strategy.balanceOf();

        vm.prank(adminAddr);
        strategy.recallSubVault(address(subVaultA));

        // Sub-vault A should be empty
        assertEq(strategy.subVaultBalance(address(subVaultA)), 0);
        // Deposit-frozen
        assertTrue(strategy.depositFrozenSubVaults(address(subVaultA)));
        // Total balance roughly unchanged (funds moved to idle)
        assertGe(strategy.balanceOf(), totalBefore - 2);
    }

    function test_recallSubVault_emitsEvents() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        vm.expectEmit(true, false, false, false);
        emit ERC4626MultiStrategyV1_2.SubVaultDepositFrozen(address(subVaultA));

        vm.prank(adminAddr);
        strategy.recallSubVault(address(subVaultA));
    }

    function test_recallSubVault_revertsIfNotAdmin() public {
        vm.prank(keeperAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.NotAdmin.selector);
        strategy.recallSubVault(address(subVaultA));
    }

    function test_recallSubVault_revertsIfNotApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(ERC4626MultiStrategyV1_2.SubVaultNotApproved.selector);
        strategy.recallSubVault(makeAddr("unknown"));
    }

    function test_recallSubVault_noopIfNoShares() public {
        vm.prank(adminAddr);
        strategy.recallSubVault(address(subVaultA));

        assertTrue(strategy.depositFrozenSubVaults(address(subVaultA)));
    }

    function test_recallSubVault_idempotentOnAlreadyFrozen() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(address(subVaultA), 600e6);

        vm.startPrank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));
        strategy.recallSubVault(address(subVaultA));
        vm.stopPrank();

        assertTrue(strategy.depositFrozenSubVaults(address(subVaultA)));
        assertEq(strategy.subVaultBalance(address(subVaultA)), 0);
    }

    // ========== removeSubVault cleans up frozen ==========

    function test_removeSubVault_clearsFrozenFlag() public {
        vm.startPrank(adminAddr);
        strategy.freezeSubVaultDeposits(address(subVaultA));
        assertTrue(strategy.depositFrozenSubVaults(address(subVaultA)));

        strategy.removeSubVault(address(subVaultA));
        assertFalse(strategy.depositFrozenSubVaults(address(subVaultA)));
        vm.stopPrank();
    }

    // ========== Helpers ==========

    function _fundVaultAndApprove(uint256 amount) internal {
        token.mint(vaultAddr, amount);
        vm.prank(vaultAddr);
        token.approve(address(strategy), amount);
    }
}

// ==========================
// Morpho Blue Freeze Tests
// ==========================

contract MorphoBlueMultiFreezeTest is Test {
    MockToken token;
    MockMorpho mockMorpho;
    MorphoBlueMultiStrategyV1_2 strategy;

    MarketParams mpA;
    MarketParams mpB;
    Id midA;
    Id midB;

    address vaultAddr;
    address adminAddr;
    address keeperAddr;
    address randomUser;

    function setUp() public {
        vaultAddr = makeAddr("vault");
        adminAddr = makeAddr("admin");
        keeperAddr = makeAddr("keeper");
        randomUser = makeAddr("random");

        token = new MockToken("USD Coin", "USDC", 6);
        mockMorpho = new MockMorpho();

        strategy = new MorphoBlueMultiStrategyV1_2(
            address(token),
            address(mockMorpho),
            vaultAddr,
            adminAddr,
            "Morpho Multi",
            64,
            new MarketParams[](0)
        );

        // Create two market params
        mpA = MarketParams({
            loanToken: address(token),
            collateralToken: makeAddr("collA"),
            oracle: makeAddr("oracleA"),
            irm: makeAddr("irmA"),
            lltv: 900000000000000000
        });
        mpB = MarketParams({
            loanToken: address(token),
            collateralToken: makeAddr("collB"),
            oracle: makeAddr("oracleB"),
            irm: makeAddr("irmB"),
            lltv: 800000000000000000
        });
        midA = Id.wrap(keccak256(abi.encode(mpA)));
        midB = Id.wrap(keccak256(abi.encode(mpB)));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        strategy.addMarket(mpA);
        strategy.addMarket(mpB);
        vm.stopPrank();
    }

    // ========== freezeMarketDeposits ==========

    function test_freezeMarketDeposits_works() public {
        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        assertTrue(strategy.depositFrozenMarkets(midA));
        assertFalse(strategy.depositFrozenMarkets(midB));
    }

    function test_freezeMarketDeposits_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit MorphoBlueMultiStrategyV1_2.MarketDepositFrozen(midA);

        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);
    }

    function test_freezeMarketDeposits_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.NotAdmin.selector);
        strategy.freezeMarketDeposits(midA);
    }

    function test_freezeMarketDeposits_revertsIfNotApproved() public {
        Id unknown = Id.wrap(bytes32(uint256(999)));
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketNotApproved.selector);
        strategy.freezeMarketDeposits(unknown);
    }

    function test_freezeMarketDeposits_revertsIfAlreadyFrozen() public {
        vm.startPrank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketAlreadyDepositFrozen.selector);
        strategy.freezeMarketDeposits(midA);
        vm.stopPrank();
    }

    // ========== unfreezeMarketDeposits ==========

    function test_unfreezeMarketDeposits_works() public {
        vm.startPrank(adminAddr);
        strategy.freezeMarketDeposits(midA);
        strategy.unfreezeMarketDeposits(midA);
        vm.stopPrank();

        assertFalse(strategy.depositFrozenMarkets(midA));
    }

    function test_unfreezeMarketDeposits_revertsIfNotFrozen() public {
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.MarketNotDepositFrozen.selector);
        strategy.unfreezeMarketDeposits(midA);
    }

    // ========== allocate reverts if frozen ==========

    function test_allocate_revertsIfFrozen() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.DepositsFrozen.selector);
        strategy.allocate(midA, 500e6);
    }

    function test_allocate_worksOnUnfrozenMarket() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        // Market B should still work
        vm.prank(keeperAddr);
        strategy.allocate(midB, 500e6);

        assertGt(strategy.marketBalance(midB), 0);
    }

    // ========== withdraw waterfall includes frozen markets ==========

    function test_withdraw_includesFrozenMarket() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 800e6);

        // Freeze A
        vm.prank(adminAddr);
        strategy.freezeMarketDeposits(midA);

        // Withdraw should still pull from frozen market
        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(900e6);

        assertGe(withdrawn, 899e6);
    }

    // ========== recallMarket ==========

    function test_recallMarket_withdrawsAllAndFreezes() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        uint256 totalBefore = strategy.balanceOf();

        vm.prank(adminAddr);
        strategy.recallMarket(midA);

        // Market A should be empty
        assertEq(strategy.marketBalance(midA), 0);
        // Deposit-frozen
        assertTrue(strategy.depositFrozenMarkets(midA));
        // Total balance roughly unchanged
        assertGe(strategy.balanceOf(), totalBefore - 2);
    }

    function test_recallMarket_emitsEvents() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        vm.expectEmit(true, false, false, false);
        emit MorphoBlueMultiStrategyV1_2.MarketDepositFrozen(midA);

        vm.prank(adminAddr);
        strategy.recallMarket(midA);
    }

    function test_recallMarket_revertsIfNotAdmin() public {
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategyV1_2.NotAdmin.selector);
        strategy.recallMarket(midA);
    }

    function test_recallMarket_noopIfNoShares() public {
        vm.prank(adminAddr);
        strategy.recallMarket(midA);

        assertTrue(strategy.depositFrozenMarkets(midA));
    }

    function test_recallMarket_idempotentOnAlreadyFrozen() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        vm.startPrank(adminAddr);
        strategy.freezeMarketDeposits(midA);
        strategy.recallMarket(midA);
        vm.stopPrank();

        assertTrue(strategy.depositFrozenMarkets(midA));
        assertEq(strategy.marketBalance(midA), 0);
    }

    // ========== removeMarket cleans up frozen ==========

    function test_removeMarket_clearsFrozenFlag() public {
        vm.startPrank(adminAddr);
        strategy.freezeMarketDeposits(midA);
        assertTrue(strategy.depositFrozenMarkets(midA));

        strategy.removeMarket(midA);
        assertFalse(strategy.depositFrozenMarkets(midA));
        vm.stopPrank();
    }

    // ========== Helpers ==========

    function _fundVaultAndApprove(uint256 amount) internal {
        token.mint(vaultAddr, amount);
        vm.prank(vaultAddr);
        token.approve(address(strategy), amount);
    }
}
