// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- Polygon PoS addresses --
address constant POLY_AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

address constant POLY_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // native USDC
address constant POLY_USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
address constant POLY_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
address constant POLY_WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

// Compound V3 Comets per base asset
// NOTE: Polygon USDC comet uses bridged USDC.e (0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174),
//       not native USDC, so it's incompatible with our native USDC vault.
address constant POLY_COMPOUND_USDT = 0xaeB318360f27748Acb200CE616E389A6C9409a07;

// Fluid fTokens (ERC-4626)
address constant POLY_FLUID_USDC = 0x571d456b578fDC34E26E6D636736ED7c0CDB9d89;
address constant POLY_FLUID_USDT = 0x6f5e34eFf43D9ab7c977512509C53840B5EfBA85;
address constant POLY_FLUID_WETH = 0xD3154535E4D0e179583ad694859E4e876EB12d24;

// Rewards infrastructure
address constant POLY_AAVE_REWARDS = 0x929EC64c34a17401F460460D4B9390518E5B473e;
address constant POLY_COMET_REWARDS = 0x45939657d1CA34A8FA39A924B71D28Fe8431e581;
address constant POLY_COMP = 0x8505b9d2254A7Ae468c0E9dd10Ccea3A837aef5c;

/// @notice Polygon + USDC: Aave V3 + Fluid (no Compound -- comet uses bridged USDC.e)
contract PolyUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "polygon";
        token = POLY_USDC;
        tokenSymbol = "USDC";
        aavePool = POLY_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = POLY_FLUID_USDC;
        aaveRewardsController = POLY_AAVE_REWARDS;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
    }
}

/// @notice Polygon + USDT: Aave V3 + Compound V3 + Fluid
contract PolyUSDT is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "polygon";
        token = POLY_USDT;
        tokenSymbol = "USDT";
        aavePool = POLY_AAVE_POOL;
        compoundComet = POLY_COMPOUND_USDT;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = POLY_FLUID_USDT;
        aaveRewardsController = POLY_AAVE_REWARDS;
        cometRewards = POLY_COMET_REWARDS;
        compRewardToken = POLY_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
    }
}

/// @notice Polygon + WETH: Aave V3 + Fluid (no Compound WETH comet on Polygon)
contract PolyWETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "polygon";
        token = POLY_WETH;
        tokenSymbol = "WETH";
        aavePool = POLY_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = POLY_FLUID_WETH;
        aaveRewardsController = POLY_AAVE_REWARDS;
        depositAmount = 50e18;
        userBalance = 250e18;
    }
}

/// @notice Polygon + WBTC: Aave V3 only (no Compound/Fluid for WBTC on Polygon)
contract PolyWBTC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "polygon";
        token = POLY_WBTC;
        tokenSymbol = "WBTC";
        aavePool = POLY_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = POLY_AAVE_REWARDS;
        depositAmount = 2e8;
        userBalance = 10e8;
    }
}
