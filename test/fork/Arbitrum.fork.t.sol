// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- Arbitrum addresses --
address constant ARB_AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC
address constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant ARB_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

// Compound V3 Comets per base asset
address constant ARB_COMPOUND_USDC = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
address constant ARB_COMPOUND_USDT = 0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07;
address constant ARB_COMPOUND_WETH = 0x6f7D514bbD4aFf3BcD1140B7344b32f063dEe486;

// Aave V3 aTokens
address constant ARB_A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637; // aArbUSDCn

// Fluid fTokens (ERC-4626)
address constant ARB_FLUID_USDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
address constant ARB_FLUID_USDT = 0x4A03F37e7d3fC243e3f99341d36f4b829BEe5E03;
address constant ARB_FLUID_WETH = 0x45Df0656F8aDf017590009d2f1898eeca4F0a205;

// Rewards infrastructure
address constant ARB_AAVE_REWARDS = 0x929EC64c34a17401F460460D4B9390518E5B473e;
address constant ARB_COMET_REWARDS = 0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae;
address constant ARB_COMP = 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;

// Uniswap V3
address constant ARB_UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

/// @notice Arbitrum + USDC: Aave V3 + Compound V3 + Fluid
contract ArbUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "arbitrum";
        token = ARB_USDC;
        tokenSymbol = "USDC";
        aavePool = ARB_AAVE_POOL;
        aaveAToken = ARB_A_USDC;
        compoundComet = ARB_COMPOUND_USDC;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = ARB_FLUID_USDC;
        aaveRewardsController = ARB_AAVE_REWARDS;
        cometRewards = ARB_COMET_REWARDS;
        compRewardToken = ARB_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
        uniswapRouter = ARB_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ARB_COMP, uint24(3000), ARB_WETH, uint24(500), ARB_USDC);
    }
}

/// @notice Arbitrum + USDT: Aave V3 + Compound V3 + Fluid
contract ArbUSDT is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "arbitrum";
        token = ARB_USDT;
        tokenSymbol = "USDT";
        aavePool = ARB_AAVE_POOL;
        compoundComet = ARB_COMPOUND_USDT;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = ARB_FLUID_USDT;
        aaveRewardsController = ARB_AAVE_REWARDS;
        cometRewards = ARB_COMET_REWARDS;
        compRewardToken = ARB_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
        uniswapRouter = ARB_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ARB_COMP, uint24(3000), ARB_WETH, uint24(500), ARB_USDT);
    }
}

/// @notice Arbitrum + WETH: Aave V3 + Compound V3 + Fluid
contract ArbWETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "arbitrum";
        token = ARB_WETH;
        tokenSymbol = "WETH";
        aavePool = ARB_AAVE_POOL;
        compoundComet = ARB_COMPOUND_WETH;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = ARB_FLUID_WETH;
        aaveRewardsController = ARB_AAVE_REWARDS;
        cometRewards = ARB_COMET_REWARDS;
        compRewardToken = ARB_COMP;
        depositAmount = 50e18;
        userBalance = 250e18;
        uniswapRouter = ARB_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ARB_COMP, uint24(3000), ARB_WETH);
    }
}

/// @notice Arbitrum + WBTC: Aave V3 only (no Compound/Morpho/Fluid for WBTC)
contract ArbWBTC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "arbitrum";
        token = ARB_WBTC;
        tokenSymbol = "WBTC";
        aavePool = ARB_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = ARB_AAVE_REWARDS;
        depositAmount = 2e8;
        userBalance = 10e8;
    }
}
