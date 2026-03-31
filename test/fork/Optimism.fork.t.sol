// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- Optimism addresses --
address constant OPT_AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

address constant OPT_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // native USDC
address constant OPT_USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
address constant OPT_WETH = 0x4200000000000000000000000000000000000006;
address constant OPT_WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

// Compound V3 Comets per base asset
address constant OPT_COMPOUND_USDC = 0x2e44e174f7D53F0212823acC11C01A11d58c5bCB;
address constant OPT_COMPOUND_USDT = 0x995E394b8B2437aC8Ce61Ee0bC610D617962B214;
address constant OPT_COMPOUND_WETH = 0xE36A30D249f7761327fd973001A32010b521b6Fd;

// Aave V3 aTokens
address constant OPT_A_USDC = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5; // aOptUSDCn

// Rewards infrastructure
address constant OPT_AAVE_REWARDS = 0x929EC64c34a17401F460460D4B9390518E5B473e;
address constant OPT_COMET_REWARDS = 0x443EA0340cb75a160F31A440722dec7b5bc3C2E9;
address constant OPT_COMP = 0x7e7d4467112689329f7E06571eD0E8CbAd4910eE;

// Uniswap V3
address constant OPT_UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

/// @notice Optimism + USDC: Aave V3 + Compound V3
contract OptUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "optimism";
        token = OPT_USDC;
        tokenSymbol = "USDC";
        aavePool = OPT_AAVE_POOL;
        aaveAToken = OPT_A_USDC;
        compoundComet = OPT_COMPOUND_USDC;
        sparkPool = address(0);
        aaveRewardsController = OPT_AAVE_REWARDS;
        cometRewards = OPT_COMET_REWARDS;
        compRewardToken = OPT_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
    }
}

/// @notice Optimism + USDT: Aave V3 + Compound V3
contract OptUSDT is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "optimism";
        token = OPT_USDT;
        tokenSymbol = "USDT";
        aavePool = OPT_AAVE_POOL;
        compoundComet = OPT_COMPOUND_USDT;
        sparkPool = address(0);
        aaveRewardsController = OPT_AAVE_REWARDS;
        cometRewards = OPT_COMET_REWARDS;
        compRewardToken = OPT_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
    }
}

/// @notice Optimism + WETH: Aave V3 + Compound V3
contract OptWETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "optimism";
        token = OPT_WETH;
        tokenSymbol = "WETH";
        aavePool = OPT_AAVE_POOL;
        compoundComet = OPT_COMPOUND_WETH;
        sparkPool = address(0);
        aaveRewardsController = OPT_AAVE_REWARDS;
        cometRewards = OPT_COMET_REWARDS;
        compRewardToken = OPT_COMP;
        depositAmount = 50e18;
        userBalance = 250e18;
    }
}

/// @notice Optimism + WBTC: Aave V3 only (no Compound V3 WBTC Comet on OPT)
contract OptWBTC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "optimism";
        token = OPT_WBTC;
        tokenSymbol = "WBTC";
        aavePool = OPT_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        aaveRewardsController = OPT_AAVE_REWARDS;
        depositAmount = 2e8;
        userBalance = 10e8;
    }
}
