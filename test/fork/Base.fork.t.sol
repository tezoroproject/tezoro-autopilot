// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- Base mainnet addresses --
address constant BASE_AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // native USDC
address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
address constant BASE_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

// Compound V3 Comets per base asset
address constant BASE_COMPOUND_USDC = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
address constant BASE_COMPOUND_WETH = 0x46e6b214b524310239732D51387075E0e70970bf;

// Aave V3 aTokens
address constant BASE_A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

// Morpho Blue
address constant BASE_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
bytes32 constant BASE_MORPHO_USDC_MARKET = 0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836; // cbBTC/USDC 86%

// Fluid fTokens (ERC-4626)
address constant BASE_FLUID_USDC = 0xf42f5795D9ac7e9D757dB633D693cD548Cfd9169;
address constant BASE_FLUID_WETH = 0x9272D6153133175175Bc276512B2336BE3931CE9;

// Rewards infrastructure
address constant BASE_AAVE_REWARDS = 0xf9cc4F0D883F1a1eb2c253bdb46c254Ca51E1F44;
address constant BASE_COMET_REWARDS = 0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1;
address constant BASE_COMP = 0x9e1028F5F1D5eDE59748FFceE5532509976840E0;

// Uniswap V3
address constant BASE_UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

/// @notice Base + USDC: Aave V3 + Compound V3 + Morpho + Fluid
contract BaseUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "base";
        token = BASE_USDC;
        tokenSymbol = "USDC";
        aavePool = BASE_AAVE_POOL;
        aaveAToken = BASE_A_USDC;
        compoundComet = BASE_COMPOUND_USDC;
        sparkPool = address(0);
        morpho = BASE_MORPHO;
        morphoMarketId = BASE_MORPHO_USDC_MARKET;
        fluidFToken = BASE_FLUID_USDC;
        aaveRewardsController = BASE_AAVE_REWARDS;
        cometRewards = BASE_COMET_REWARDS;
        compRewardToken = BASE_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
    }
}

/// @notice Base + WETH: Aave V3 + Compound V3 + Fluid
contract BaseWETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "base";
        token = BASE_WETH;
        tokenSymbol = "WETH";
        aavePool = BASE_AAVE_POOL;
        compoundComet = BASE_COMPOUND_WETH;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = BASE_FLUID_WETH;
        aaveRewardsController = BASE_AAVE_REWARDS;
        cometRewards = BASE_COMET_REWARDS;
        compRewardToken = BASE_COMP;
        depositAmount = 50e18;
        userBalance = 250e18;
    }
}
