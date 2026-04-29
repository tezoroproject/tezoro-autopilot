// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626MultiStrategyV1_2} from "../../src/strategies/ERC4626MultiStrategyV1_2.sol";

// Ethereum mainnet assets
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

// Aave v4 tokenization spokes from the executed Ethereum mainnet activation proposal:
// https://github.com/aave-dao/aave-proposals-v3/blob/main/src/20260319_AaveV4Ethereum_ActivateV4Ethereum/AaveV4EthereumAddresses.sol
address constant AAVE_V4_CORE_USDT = 0x5eC44a70F309854fe04d495cFE1B5dA63DD1cc73;
address constant AAVE_V4_PLUS_USDT = 0x80835EB50694EE0e519743f67e5401e6FD300006;
address constant AAVE_V4_PRIME_USDT = 0x46c588DD8453aC259c1f6a54b4C9A93C2aC3762D;
address constant AAVE_V4_CORE_GHO = 0x58C14a5E061c9bC6926c5b853445290F296C2F7B;
address constant AAVE_V4_PLUS_GHO = 0xA54382db40EC602c0a173A08f9E86Ed40F9D4D10;
address constant AAVE_V4_PRIME_GHO = 0x900fD46d565d1ac8995928c0179052ec02a6D0E1;
bytes4 constant AAVE_V4_ADD_CAP_EXCEEDED_SELECTOR = bytes4(keccak256("AddCapExceeded(uint256)"));

contract AaveV4ERC4626MultiStrategyTrickyAssetsForkTest is Test {
    using SafeERC20 for IERC20;

    address vaultAddr = makeAddr("vault");
    address adminAddr = makeAddr("admin");
    address keeperAddr = makeAddr("keeper");

    uint256 constant ASSET_TOLERANCE = 1e6;
    uint256 constant USDT_PREFERRED_PER_SPOKE = 10_000e6;
    uint256 constant USDT_IDLE_RESERVE = 5000e6;
    uint256 constant GHO_PREFERRED_PER_SPOKE = 10_000e18;
    uint256 constant GHO_IDLE_RESERVE = 5000e18;

    function setUp() public {
        vm.createSelectFork("ethereum");
    }

    function test_usdt_nonStandardApprove_multiHubLifecycle() public {
        address[] memory spokes = _usdtSpokes();
        ERC4626MultiStrategyV1_2 strategy = _deployStrategy(USDT, "Aave V4 USDT", spokes);

        for (uint256 i = 0; i < spokes.length; i++) {
            assertEq(IERC4626(spokes[i]).asset(), USDT);
            assertEq(IERC20(USDT).allowance(address(strategy), spokes[i]), type(uint256).max);
        }

        assertEq(IERC20(USDT).allowance(vaultAddr, address(strategy)), type(uint256).max);

        (uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, spokes, USDT_PREFERRED_PER_SPOKE);
        assertGt(activeCount, 0, "no allocatable USDT spoke");

        uint256 depositAmount = totalAllocation + USDT_IDLE_RESERVE;
        _depositIntoStrategy(strategy, USDT, depositAmount);
        _allocatePlan(strategy, spokes, amounts);

        _assertApproxAssets(strategy.balanceOf(), depositAmount);
        assertEq(IERC20(USDT).balanceOf(address(strategy)), USDT_IDLE_RESERVE);

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(USDT_IDLE_RESERVE + USDT_PREFERRED_PER_SPOKE);

        _assertApproxAssets(withdrawn, USDT_IDLE_RESERVE + USDT_PREFERRED_PER_SPOKE);
        _assertApproxAssets(strategy.balanceOf(), depositAmount - withdrawn);

        vm.prank(vaultAddr);
        uint256 emergencyWithdrawn = strategy.emergencyWithdraw();

        _assertApproxAssets(emergencyWithdrawn, depositAmount - withdrawn);
        assertEq(IERC20(USDT).balanceOf(address(strategy)), 0);
        for (uint256 i = 0; i < spokes.length; i++) {
            assertEq(IERC4626(spokes[i]).balanceOf(address(strategy)), 0);
        }
    }

    function test_usdt_plusSpoke_capOverflow_revertsWithAaveSelector() public {
        address[] memory spokes = new address[](1);
        spokes[0] = AAVE_V4_PLUS_USDT;
        ERC4626MultiStrategyV1_2 strategy = _deployStrategy(USDT, "Aave V4 USDT Plus", spokes);

        uint256 maxDeposit = IERC4626(AAVE_V4_PLUS_USDT).maxDeposit(address(strategy));
        if (maxDeposit == type(uint256).max) return;

        uint256 amount = maxDeposit == 0 ? 1 : maxDeposit + 1;
        _depositIntoStrategy(strategy, USDT, amount);

        vm.prank(keeperAddr);
        (bool success, bytes memory revertData) =
            address(strategy).call(abi.encodeCall(ERC4626MultiStrategyV1_2.allocate, (AAVE_V4_PLUS_USDT, amount)));

        assertFalse(success);
        assertEq(_revertSelector(revertData), AAVE_V4_ADD_CAP_EXCEEDED_SELECTOR);
    }

    function test_gho_18Decimals_multiHubAccountingAndLiquidity() public {
        address[] memory spokes = _ghoSpokes();
        ERC4626MultiStrategyV1_2 strategy = _deployStrategy(GHO, "Aave V4 GHO", spokes);

        for (uint256 i = 0; i < spokes.length; i++) {
            assertEq(IERC4626(spokes[i]).asset(), GHO);
            assertEq(IERC4626(spokes[i]).decimals(), 18);
        }

        (uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount) =
            _plannedAllocations(strategy, spokes, GHO_PREFERRED_PER_SPOKE);
        assertGt(activeCount, 0, "no allocatable GHO spoke");

        uint256 depositAmount = totalAllocation + GHO_IDLE_RESERVE;
        _depositIntoStrategy(strategy, GHO, depositAmount);
        _allocatePlan(strategy, spokes, amounts);

        uint256 expectedBalance = IERC20(GHO).balanceOf(address(strategy)) + _sumDirectVaultAssets(strategy, spokes);
        assertEq(strategy.balanceOf(), expectedBalance);

        uint256 expectedLiquidity = IERC20(GHO).balanceOf(address(strategy));
        for (uint256 i = 0; i < spokes.length; i++) {
            expectedLiquidity += IERC4626(spokes[i]).maxWithdraw(address(strategy));
        }
        assertEq(strategy.availableLiquidity(), expectedLiquidity);
        assertLe(strategy.availableLiquidity(), strategy.balanceOf());

        vm.prank(vaultAddr);
        uint256 withdrawn = strategy.withdraw(GHO_IDLE_RESERVE + (GHO_PREFERRED_PER_SPOKE / 2));

        _assertApproxAssets(withdrawn, GHO_IDLE_RESERVE + (GHO_PREFERRED_PER_SPOKE / 2));
        _assertApproxAssets(strategy.balanceOf(), depositAmount - withdrawn);
    }

    function _deployStrategy(
        address asset,
        string memory strategyName,
        address[] memory spokes
    )
        internal
        returns (ERC4626MultiStrategyV1_2 strategy)
    {
        strategy = new ERC4626MultiStrategyV1_2(asset, vaultAddr, adminAddr, strategyName, 64, new address[](0));

        vm.startPrank(adminAddr);
        strategy.setKeeper(keeperAddr);
        for (uint256 i = 0; i < spokes.length; i++) {
            strategy.addSubVault(spokes[i]);
        }
        vm.stopPrank();

        vm.prank(vaultAddr);
        IERC20(asset).forceApprove(address(strategy), type(uint256).max);
    }

    function _depositIntoStrategy(ERC4626MultiStrategyV1_2 strategy, address asset, uint256 amount) internal {
        deal(asset, vaultAddr, amount);
        vm.prank(vaultAddr);
        strategy.deposit(amount);
    }

    function _plannedAllocations(
        ERC4626MultiStrategyV1_2 strategy,
        address[] memory spokes,
        uint256 preferredPerSpoke
    )
        internal
        view
        returns (uint256[] memory amounts, uint256 totalAllocation, uint256 activeCount)
    {
        amounts = new uint256[](spokes.length);

        for (uint256 i = 0; i < spokes.length; i++) {
            uint256 maxDeposit = IERC4626(spokes[i]).maxDeposit(address(strategy));
            if (maxDeposit == 0) continue;

            uint256 amount = _min(maxDeposit, preferredPerSpoke);
            if (amount == 0) continue;

            amounts[i] = amount;
            totalAllocation += amount;
            activeCount++;
        }
    }

    function _allocatePlan(ERC4626MultiStrategyV1_2 strategy, address[] memory spokes, uint256[] memory amounts) internal {
        vm.startPrank(keeperAddr);
        for (uint256 i = 0; i < spokes.length; i++) {
            if (amounts[i] == 0) continue;
            strategy.allocate(spokes[i], amounts[i]);
        }
        vm.stopPrank();
    }

    function _sumDirectVaultAssets(
        ERC4626MultiStrategyV1_2 strategy,
        address[] memory spokes
    )
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < spokes.length; i++) {
            uint256 shares = IERC4626(spokes[i]).balanceOf(address(strategy));
            if (shares == 0) continue;
            total += IERC4626(spokes[i]).convertToAssets(shares);
        }
    }

    function _usdtSpokes() internal pure returns (address[] memory spokes) {
        spokes = new address[](3);
        spokes[0] = AAVE_V4_CORE_USDT;
        spokes[1] = AAVE_V4_PLUS_USDT;
        spokes[2] = AAVE_V4_PRIME_USDT;
    }

    function _ghoSpokes() internal pure returns (address[] memory spokes) {
        spokes = new address[](3);
        spokes[0] = AAVE_V4_CORE_GHO;
        spokes[1] = AAVE_V4_PLUS_GHO;
        spokes[2] = AAVE_V4_PRIME_GHO;
    }

    function _assertApproxAssets(uint256 actual, uint256 expected) internal pure {
        if (actual > expected) assertLe(actual - expected, ASSET_TOLERANCE);
        else assertLe(expected - actual, ASSET_TOLERANCE);
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
