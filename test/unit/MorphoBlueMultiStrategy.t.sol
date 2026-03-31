// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MorphoBlueMultiStrategy} from "../../src/strategies/MorphoBlueMultiStrategy.sol";
import {IMorpho, MarketParams, MorphoMarket, Position, Id} from "../../src/interfaces/IMorpho.sol";

// ---- Mock ERC-20 ----

contract MorphoTestToken is ERC20 {
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

// ---- Mock Morpho with configurable behavior ----

contract TestMockMorpho {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Market {
        address loanToken;
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
    }

    mapping(bytes32 => mapping(address => uint256)) public supplyShares;
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => MarketParams) public storedParams;
    mapping(bytes32 => bool) public withdrawBroken;

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
            storedParams[key] = mp;
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

        if (withdrawBroken[key]) revert("withdraw broken");

        Market storage m = markets[key];

        if (shares > 0) {
            sharesOut = shares;
            assetsOut = uint256(shares).mulDiv(uint256(m.totalSupplyAssets), uint256(m.totalSupplyShares));
        } else {
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
        m.totalBorrowAssets = stored.totalBorrowAssets;
    }

    function idToMarketParams(Id mid) external view returns (MarketParams memory) {
        return storedParams[Id.unwrap(mid)];
    }

    function accrueInterest(MarketParams memory) external {}

    // ---- Test helpers ----

    function setWithdrawBroken(Id mid, bool broken) external {
        withdrawBroken[Id.unwrap(mid)] = broken;
    }

    function simulateYield(Id mid, uint256 amount, address token) external {
        bytes32 key = Id.unwrap(mid);
        MorphoTestToken(token).mint(address(this), amount);
        markets[key].totalSupplyAssets += uint128(amount);
    }

    function simulateBorrows(Id mid, uint128 borrowAmount) external {
        bytes32 key = Id.unwrap(mid);
        markets[key].totalBorrowAssets = borrowAmount;
    }
}

// ---- Tests ----

contract MorphoBlueMultiStrategyTest is Test {
    MorphoTestToken token;
    TestMockMorpho mockMorpho;
    MorphoBlueMultiStrategy strategy;

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

        token = new MorphoTestToken("USD Coin", "USDC", 6);
        mockMorpho = new TestMockMorpho();

        strategy = new MorphoBlueMultiStrategy(
            address(token),
            address(mockMorpho),
            vaultAddr,
            adminAddr,
            "Morpho Multi",
            20,
            new MarketParams[](0)
        );

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

    // ========== Constructor ==========

    function test_constructor_setsImmutables() public view {
        assertEq(strategy.asset(), address(token));
        assertEq(strategy.vault(), vaultAddr);
        assertEq(strategy.admin(), adminAddr);
        assertEq(address(strategy.morpho()), address(mockMorpho));
    }

    function test_constructor_revertsOnZeroAsset() public {
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        new MorphoBlueMultiStrategy(address(0), address(mockMorpho), vaultAddr, adminAddr, "test", 64, new MarketParams[](0));
    }

    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        new MorphoBlueMultiStrategy(address(token), address(0), vaultAddr, adminAddr, "test", 64, new MarketParams[](0));
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        new MorphoBlueMultiStrategy(address(token), address(mockMorpho), address(0), adminAddr, "test", 64, new MarketParams[](0));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        new MorphoBlueMultiStrategy(address(token), address(mockMorpho), vaultAddr, address(0), "test", 64, new MarketParams[](0));
    }

    // ========== Admin: addMarket ==========

    function test_addMarket_works() public view {
        assertTrue(strategy.isApproved(midA));
        assertTrue(strategy.isApproved(midB));
        assertEq(strategy.marketCount(), 2);
    }

    function test_addMarket_revertsIfNotAdmin() public {
        MarketParams memory mp = _makeMarketParams(makeAddr("collC"));
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotAdmin.selector);
        strategy.addMarket(mp);
    }

    function test_addMarket_revertsIfAlreadyApproved() public {
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.MarketAlreadyApproved.selector);
        strategy.addMarket(mpA);
    }

    function test_addMarket_revertsOnLoanTokenMismatch() public {
        MarketParams memory mp = MarketParams({
            loanToken: makeAddr("wrongToken"),
            collateralToken: makeAddr("coll"),
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 900000000000000000
        });
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.LoanTokenMismatch.selector);
        strategy.addMarket(mp);
    }

    function test_addMarket_revertsAtMaxCap() public {
        // Already have 2, add 18 more to hit MAX_MARKETS = 20
        for (uint256 i = 0; i < 18; i++) {
            MarketParams memory mp = _makeMarketParams(makeAddr(string(abi.encodePacked("coll", i))));
            vm.prank(adminAddr);
            strategy.addMarket(mp);
        }
        assertEq(strategy.marketCount(), 20);

        MarketParams memory extra = _makeMarketParams(makeAddr("collExtra"));
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.TooManyMarkets.selector);
        strategy.addMarket(extra);
    }

    // ========== Admin: removeMarket ==========

    function test_removeMarket_works() public {
        vm.prank(adminAddr);
        strategy.removeMarket(midA);

        assertFalse(strategy.isApproved(midA));
        assertEq(strategy.marketCount(), 1);
    }

    function test_removeMarket_revertsIfNotApproved() public {
        Id unknown = Id.wrap(bytes32(uint256(999)));
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.MarketNotApproved.selector);
        strategy.removeMarket(unknown);
    }

    function test_removeMarket_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotAdmin.selector);
        strategy.removeMarket(midA);
    }

    function test_removeMarket_revertsIfActivePosition() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 500e6);

        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.MarketHasActivePosition.selector);
        strategy.removeMarket(midA);
    }

    function test_removeMarket_worksAfterRecall() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 500e6);

        vm.startPrank(adminAddr);
        strategy.recallMarket(midA);
        strategy.removeMarket(midA);
        vm.stopPrank();

        assertFalse(strategy.isApproved(midA));
        assertEq(strategy.marketCount(), 1);
    }

    // ========== Admin: setKeeper ==========

    function test_setKeeper_works() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(adminAddr);
        strategy.setKeeper(newKeeper);
        assertEq(strategy.keeper(), newKeeper);
    }

    function test_setKeeper_revertsOnZero() public {
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        strategy.setKeeper(address(0));
    }

    function test_setKeeper_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotAdmin.selector);
        strategy.setKeeper(makeAddr("x"));
    }

    // ========== Admin: two-step admin transfer ==========

    function test_transferAdmin_works() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(adminAddr);
        strategy.transferAdmin(newAdmin);
        assertEq(strategy.pendingAdmin(), newAdmin);
        assertEq(strategy.admin(), adminAddr);

        vm.prank(newAdmin);
        strategy.acceptAdmin();
        assertEq(strategy.admin(), newAdmin);
        assertEq(strategy.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_revertsIfNotPending() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotPendingAdmin.selector);
        strategy.acceptAdmin();
    }

    function test_transferAdmin_revertsOnZero() public {
        vm.prank(adminAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.ZeroAddress.selector);
        strategy.transferAdmin(address(0));
    }

    function test_transferAdmin_revertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotAdmin.selector);
        strategy.transferAdmin(makeAddr("x"));
    }

    // ========== Vault: deposit ==========

    function test_deposit_holdsIdle() public {
        _fundVaultAndApprove(1000e6);

        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        assertEq(token.balanceOf(address(strategy)), 1000e6);
        assertEq(strategy.balanceOf(), 1000e6);
    }

    function test_deposit_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotVault.selector);
        strategy.deposit(100e6);
    }

    // ========== Keeper: allocate / deallocate ==========

    function test_allocate_movesIdleToMarket() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        assertEq(token.balanceOf(address(strategy)), 400e6);
        assertGe(strategy.marketBalance(midA), 599e6);
    }

    function test_allocate_revertsIfNotKeeper() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotKeeper.selector);
        strategy.allocate(midA, 100e6);
    }

    function test_allocate_revertsIfNotApproved() public {
        Id unknown = Id.wrap(bytes32(uint256(999)));
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.MarketNotApproved.selector);
        strategy.allocate(unknown, 100e6);
    }

    function test_allocate_revertsIfInsufficientIdle() public {
        _fundVaultAndApprove(100e6);
        vm.prank(vaultAddr);
        strategy.deposit(100e6);

        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.InsufficientIdle.selector);
        strategy.allocate(midA, 200e6);
    }

    function test_deallocate_movesBackToIdle() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        vm.prank(keeperAddr);
        strategy.deallocate(midA, 300e6);

        uint256 idle = token.balanceOf(address(strategy));
        assertGe(idle, 699e6);
    }

    function test_deallocate_revertsIfNotKeeper() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotKeeper.selector);
        strategy.deallocate(midA, 100e6);
    }

    function test_deallocate_revertsIfNotApproved() public {
        Id unknown = Id.wrap(bytes32(uint256(999)));
        vm.prank(keeperAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.MarketNotApproved.selector);
        strategy.deallocate(unknown, 100e6);
    }

    // ========== Vault: withdraw ==========

    function test_withdraw_fromIdleOnly() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(500e6);

        assertEq(withdrawn, 500e6);
        assertEq(token.balanceOf(vaultAddr), 500e6);
    }

    function test_withdraw_waterfallFromMarkets() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, 500e6);
        strategy.allocate(midB, 500e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(strategy)), 0);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(700e6);

        assertGe(withdrawn, 699e6);
        assertGe(token.balanceOf(vaultAddr), 699e6);
    }

    function test_withdraw_idlePlusMarkets() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(800e6);

        assertGe(withdrawn, 799e6);
    }

    function test_withdraw_moreThanAvailable() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(1000e6);

        assertEq(withdrawn, 500e6);
    }

    function test_withdraw_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotVault.selector);
        strategy.withdraw(100e6);
    }

    function test_withdraw_emitsWithdrawFailed_onBrokenMarket() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, 400e6);
        strategy.allocate(midB, 400e6);
        vm.stopPrank();

        // Break market A
        mockMorpho.setWithdrawBroken(midA, true);

        // Withdraw more than idle — should emit WithdrawFailed for A, still get B
        vm.prank(vaultAddr);
        vm.expectEmit(true, false, false, false);
        emit MorphoBlueMultiStrategy.WithdrawFailed(midA);
        uint256 withdrawn = strategy.withdraw(800e6);

        // Should get idle (200) + midB (400) = 600
        assertGe(withdrawn, 599e6);
    }

    // ========== Vault: emergencyWithdraw ==========

    function test_emergencyWithdraw_collectsEverything() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, 400e6);
        strategy.allocate(midB, 400e6);
        vm.stopPrank();

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.emergencyWithdraw();

        assertGe(withdrawn, 999e6);
        assertGe(token.balanceOf(vaultAddr), 999e6);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function test_emergencyWithdraw_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotVault.selector);
        strategy.emergencyWithdraw();
    }

    function test_emergencyWithdraw_recoversPartialWhenOneBroken() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.startPrank(keeperAddr);
        strategy.allocate(midA, 400e6);
        strategy.allocate(midB, 400e6);
        vm.stopPrank();

        // Break market A
        mockMorpho.setWithdrawBroken(midA, true);

        vm.prank(vaultAddr);
        vm.expectEmit(true, false, false, false);
        emit MorphoBlueMultiStrategy.WithdrawFailed(midA);
        uint256 withdrawn = strategy.emergencyWithdraw();

        // Should get idle (200) + midB (400) = 600
        assertGe(withdrawn, 599e6);
    }

    // ========== Views: balanceOf, availableLiquidity, isHealthy ==========

    function test_balanceOf_idlePlusMarkets() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 300e6);

        assertGe(strategy.balanceOf(), 999e6);
    }

    function test_availableLiquidity_idlePlusPool() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 500e6);

        assertGe(strategy.availableLiquidity(), 999e6);
    }

    function test_availableLiquidity_cappedByPoolLiquidity() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 500e6);

        // Simulate high utilization: totalBorrowAssets close to totalSupplyAssets
        mockMorpho.simulateBorrows(midA, 490e6);

        uint256 avail = strategy.availableLiquidity();
        // Pool liquidity = 500 - 490 = 10, plus idle 500 = 510
        assertLe(avail, 520e6);
    }

    function test_isHealthy_falseWhenNoMarketActivity() public view {
        assertFalse(strategy.isHealthy());
    }

    function test_isHealthy_trueWhenMarketHasSupply() public {
        _fundVaultAndApprove(100e6);
        vm.prank(vaultAddr);
        strategy.deposit(100e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 100e6);

        assertTrue(strategy.isHealthy());
    }

    // ========== sweepReward ==========

    function test_sweepReward_works() public {
        MorphoTestToken reward = new MorphoTestToken("Reward", "RWD", 18);
        reward.mint(address(strategy), 50e18);

        address rewardsModule = makeAddr("rewardsModule");

        vm.prank(vaultAddr);
        uint256 swept = strategy.sweepReward(address(reward), rewardsModule);

        assertEq(swept, 50e18);
        assertEq(reward.balanceOf(rewardsModule), 50e18);
    }

    function test_sweepReward_revertsOnAsset() public {
        vm.prank(vaultAddr);
        vm.expectRevert(MorphoBlueMultiStrategy.CannotSweepAsset.selector);
        strategy.sweepReward(address(token), makeAddr("to"));
    }

    function test_sweepReward_revertsIfNotVault() public {
        vm.prank(randomUser);
        vm.expectRevert(MorphoBlueMultiStrategy.NotVault.selector);
        strategy.sweepReward(makeAddr("token"), makeAddr("to"));
    }

    // ========== accrueAllInterest ==========

    function test_accrueAllInterest_callable() public {
        // Should not revert — anyone can call it
        strategy.accrueAllInterest();
    }

    // ========== recallMarket fault tolerance ==========

    function test_recallMarket_emitsWithdrawFailedOnBrokenMarket() public {
        _fundVaultAndApprove(1000e6);
        vm.prank(vaultAddr);
        strategy.deposit(1000e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 600e6);

        // Break market A
        mockMorpho.setWithdrawBroken(midA, true);

        // recallMarket should not revert, should emit WithdrawFailed and still freeze
        vm.prank(adminAddr);
        vm.expectEmit(true, false, false, false);
        emit MorphoBlueMultiStrategy.WithdrawFailed(midA);
        strategy.recallMarket(midA);

        assertTrue(strategy.depositFrozenMarkets(midA));
    }

    // ========== View helpers ==========

    function test_getMarketIds_returnsAll() public view {
        Id[] memory ids = strategy.getMarketIds();
        assertEq(ids.length, 2);
    }

    function test_getMarketParams_returnsParams() public view {
        MarketParams memory mp = strategy.getMarketParams(midA);
        assertEq(mp.loanToken, address(token));
    }

    function test_marketBalance_returnsBalance() public {
        _fundVaultAndApprove(500e6);
        vm.prank(vaultAddr);
        strategy.deposit(500e6);

        vm.prank(keeperAddr);
        strategy.allocate(midA, 300e6);

        assertGe(strategy.marketBalance(midA), 299e6);
        assertEq(strategy.marketBalance(midB), 0);
    }

    function test_harvest_returnsZero() public {
        vm.prank(vaultAddr);
        uint256 result = strategy.harvest(makeAddr("rewards"));
        assertEq(result, 0);
    }

    // ========== Helpers ==========

    function _fundVaultAndApprove(uint256 amount) internal {
        token.mint(vaultAddr, amount);
        vm.prank(vaultAddr);
        token.approve(address(strategy), amount);
    }

    function _makeMarketParams(address collateral) internal returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(token),
            collateralToken: collateral,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 900000000000000000
        });
    }
}
