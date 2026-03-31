// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- BNB Smart Chain addresses --
// NOTE: BSC Aave V3 pool address differs from other chains
address constant BSC_AAVE_POOL = 0x6807dc923806fE8Fd134338EABCA509979a7e0cB;

address constant BSC_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // Binance-Peg USDC
address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955; // Binance-Peg USDT
address constant BSC_ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // Binance-Peg ETH
address constant BSC_BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // Binance-Peg BTCB

// Rewards infrastructure
address constant BSC_AAVE_REWARDS = 0xC206C2764A9dBF27d599613b8F9A63ACd1160ab4;

/// @notice BSC + USDC: Aave V3 only
contract BscUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "bsc";
        token = BSC_USDC;
        tokenSymbol = "USDC";
        aavePool = BSC_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = BSC_AAVE_REWARDS;
        depositAmount = 100_000e18; // BSC USDC is 18 decimals
        userBalance = 500_000e18;
    }
}

/// @notice BSC + USDT: Aave V3 only
contract BscUSDT is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "bsc";
        token = BSC_USDT;
        tokenSymbol = "USDT";
        aavePool = BSC_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = BSC_AAVE_REWARDS;
        depositAmount = 100_000e18; // BSC USDT is 18 decimals
        userBalance = 500_000e18;
    }
}

/// @notice BSC + ETH (Binance-Peg): Aave V3 only
contract BscETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "bsc";
        token = BSC_ETH;
        tokenSymbol = "ETH";
        aavePool = BSC_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = BSC_AAVE_REWARDS;
        depositAmount = 50e18;
        userBalance = 250e18;
    }
}

/// @notice BSC + BTCB: Aave V3 only
contract BscBTCB is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "bsc";
        token = BSC_BTCB;
        tokenSymbol = "BTCB";
        aavePool = BSC_AAVE_POOL;
        compoundComet = address(0);
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = BSC_AAVE_REWARDS;
        depositAmount = 2e18; // BTCB is 18 decimals on BSC
        userBalance = 10e18;
    }
}
