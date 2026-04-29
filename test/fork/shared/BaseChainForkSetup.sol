// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TezoroV1_2} from "../../../src/TezoroV1_2.sol";
import {AaveV3StrategyV1_2} from "../../../src/strategies/AaveV3StrategyV1_2.sol";
import {CompoundV3StrategyV1_2} from "../../../src/strategies/CompoundV3StrategyV1_2.sol";
import {MorphoBlueMultiStrategyV1_2} from "../../../src/strategies/MorphoBlueMultiStrategyV1_2.sol";
import {FluidStrategyV1_2} from "../../../src/strategies/FluidStrategyV1_2.sol";
import {IMorpho, MarketParams, Id} from "../../../src/interfaces/IMorpho.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {RewardsModuleV1_2} from "../../../src/RewardsModuleV1_2.sol";

/// @notice Abstract base: deploys vault + strategies, funds users.
///         Child test contracts inherit test modules built on top of this.
abstract contract BaseChainForkSetup is Test {
    using SafeERC20 for IERC20;

    // --- To be set by child contracts ---
    string internal forkRpc; // foundry.toml rpc alias
    address internal token; // the vault asset (USDC, USDT, WETH, WBTC)
    string internal tokenSymbol;
    address internal aavePool; // address(0) = not available
    address internal aaveAToken; // 0 = fetch dynamically from pool
    address internal compoundComet; // address(0) = not available
    address internal sparkPool; // address(0) = not available
    address internal morpho; // address(0) = not available
    bytes32 internal morphoMarketId; // Morpho Blue market ID
    address internal fluidFToken; // address(0) = not available

    // Rewards infrastructure
    address internal aaveRewardsController; // address(0) = none
    address internal sparkRewardsController; // address(0) = none
    address internal cometRewards; // address(0) = none
    address internal compRewardToken; // address(0) = none

    // Swap infrastructure (for RewardsModuleV1_2 swap tests)
    address internal uniswapRouter; // address(0) = skip swap tests
    bytes internal swapPath; // Uniswap V3 encoded path: tokenIn | fee | ... | tokenOut
    address internal uniV2Router; // Uniswap V2 / SushiSwap, address(0) = skip V2 tests
    address internal wrappedNative; // WETH / WBNB, for V2 path construction

    // Amounts (set by child, token-appropriate)
    uint256 internal depositAmount; // standard deposit (e.g. 100_000e6 for USDC, 50e18 for WETH)
    uint256 internal userBalance; // dealt to each user (>= 3x depositAmount)

    // --- Deployed in setUp ---
    TezoroV1_2 public vault;
    AaveV3StrategyV1_2 public aaveStrategy;
    CompoundV3StrategyV1_2 public compoundStrategy;
    AaveV3StrategyV1_2 public sparkStrategy;
    MorphoBlueMultiStrategyV1_2 public morphoStrategy;
    FluidStrategyV1_2 public fluidStrategy;

    address public admin = makeAddr("admin");
    address public keeper = makeAddr("keeper");
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 internal strategyCount;

    function setUp() public virtual {
        _configure(); // child sets all addresses and amounts
        vm.createSelectFork(forkRpc);

        // Deploy vault
        vault = new TezoroV1_2(
            IERC20(token),
            string.concat("Tezoro ", tokenSymbol, "-A"),
            string.concat("t", tokenSymbol, "-A"),
            admin,
            feeRecipient,
            1_500, // 15% performance fee
            300 // 3% idle buffer
        );

        // Deploy strategies for available protocols
        if (aavePool != address(0)) {
            if (aaveAToken == address(0)) {
                aaveAToken = _getAToken(aavePool, token);
            }
            aaveStrategy = new AaveV3StrategyV1_2(token, aavePool, aaveAToken, address(vault), aaveRewardsController);
        }

        if (compoundComet != address(0)) {
            compoundStrategy = new CompoundV3StrategyV1_2(token, compoundComet, address(vault), cometRewards, compRewardToken);
        }

        if (sparkPool != address(0)) {
            address spToken = _getAToken(sparkPool, token);
            sparkStrategy = new AaveV3StrategyV1_2(token, sparkPool, spToken, address(vault), sparkRewardsController);
        }

        if (morpho != address(0)) {
            morphoStrategy = new MorphoBlueMultiStrategyV1_2(token, morpho, address(vault), admin, "Morpho Multi", 64, new MarketParams[](0));
        }

        if (fluidFToken != address(0)) {
            fluidStrategy = new FluidStrategyV1_2(token, fluidFToken, address(vault));
        }

        // Add available strategies with equal allocation
        strategyCount = 0;
        if (address(aaveStrategy) != address(0)) strategyCount++;
        if (address(compoundStrategy) != address(0)) strategyCount++;
        if (address(sparkStrategy) != address(0)) strategyCount++;
        if (address(morphoStrategy) != address(0)) strategyCount++;
        if (address(fluidStrategy) != address(0)) strategyCount++;

        vm.startPrank(admin);

        // Configure morpho multi-strategy (must be done as admin before vault operations)
        if (address(morphoStrategy) != address(0)) {
            MarketParams memory mp = IMorpho(morpho).idToMarketParams(Id.wrap(morphoMarketId));
            morphoStrategy.addMarket(mp);
            morphoStrategy.setKeeper(keeper);
        }

        uint256 remainingBps = 9_700; // 97% (3% idle buffer)
        uint256 perStrategyBps = strategyCount > 0 ? remainingBps / strategyCount : 0;

        // Add strategies
        if (address(aaveStrategy) != address(0)) vault.addStrategy(IStrategy(address(aaveStrategy)));
        if (address(compoundStrategy) != address(0)) vault.addStrategy(IStrategy(address(compoundStrategy)));
        if (address(sparkStrategy) != address(0)) vault.addStrategy(IStrategy(address(sparkStrategy)));
        if (address(morphoStrategy) != address(0)) vault.addStrategy(IStrategy(address(morphoStrategy)));
        if (address(fluidStrategy) != address(0)) vault.addStrategy(IStrategy(address(fluidStrategy)));

        // Set allocations via rebalance
        if (strategyCount > 0) {
            IStrategy[] memory strats = new IStrategy[](strategyCount);
            uint256[] memory bps = new uint256[](strategyCount);
            uint256 idx = 0;
            if (address(aaveStrategy) != address(0)) { strats[idx] = IStrategy(address(aaveStrategy)); bps[idx] = perStrategyBps; idx++; }
            if (address(compoundStrategy) != address(0)) { strats[idx] = IStrategy(address(compoundStrategy)); bps[idx] = perStrategyBps; idx++; }
            if (address(sparkStrategy) != address(0)) { strats[idx] = IStrategy(address(sparkStrategy)); bps[idx] = perStrategyBps; idx++; }
            if (address(morphoStrategy) != address(0)) { strats[idx] = IStrategy(address(morphoStrategy)); bps[idx] = perStrategyBps; idx++; }
            if (address(fluidStrategy) != address(0)) { strats[idx] = IStrategy(address(fluidStrategy)); bps[idx] = perStrategyBps; idx++; }
            // Give the last strategy the remainder to reach exactly remainingBps
            bps[strategyCount - 1] = remainingBps - perStrategyBps * (strategyCount - 1);
            vault.rebalance(strats, bps);
        }

        vault.setKeeper(keeper);
        vm.stopPrank();

        // Morpho multi-strategy: allocate idle funds to market (keeper operation)
        if (address(morphoStrategy) != address(0)) {
            uint256 idle = IERC20(token).balanceOf(address(morphoStrategy));
            if (idle > 0) {
                vm.prank(keeper);
                morphoStrategy.allocate(Id.wrap(morphoMarketId), idle);
            }
        }

        // Give users tokens
        deal(token, alice, userBalance);
        deal(token, bob, userBalance);

        vm.prank(alice);
        IERC20(token).forceApprove(address(vault), type(uint256).max);
        vm.prank(bob);
        IERC20(token).forceApprove(address(vault), type(uint256).max);
    }

    /// @dev Child contract sets forkRpc, token, amounts, and protocol addresses
    function _configure() internal virtual;

    // =========================================================================
    // Helpers
    // =========================================================================

    function _getAToken(address pool, address asset_) internal view returns (address aToken) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("getReserveData(address)", asset_));
        require(success, "getReserveData failed");
        assembly {
            aToken := mload(add(data, 288)) // 32 + 8*32
        }
    }

    function _getCometSupplySpeed(address comet_) internal view returns (uint256 speed) {
        (bool success, bytes memory data) =
            comet_.staticcall(abi.encodeWithSignature("baseTrackingSupplySpeed()"));
        if (success && data.length >= 32) {
            speed = abi.decode(data, (uint256));
        }
    }

    /// @dev Returns true only when Compound rewards are actually distributable:
    ///      supply speed > 0 AND the CometRewards contract holds reward tokens.
    function _compRewardsActive() internal view returns (bool) {
        if (cometRewards == address(0) || compRewardToken == address(0) || compoundComet == address(0)) {
            return false;
        }
        if (_getCometSupplySpeed(compoundComet) == 0) return false;
        return IERC20(compRewardToken).balanceOf(cometRewards) > 0;
    }
}
