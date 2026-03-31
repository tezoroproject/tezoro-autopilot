// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseChainForkTest} from "./shared/BaseChainForkTest.sol";

// -- Ethereum mainnet addresses --
address constant ETH_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
address constant ETH_SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;

address constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant ETH_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

// Compound V3 Comets per base asset
address constant ETH_COMPOUND_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
address constant ETH_COMPOUND_USDT = 0x3Afdc9BCA9213A35503b077a6072F3D0d5AB0840;
address constant ETH_COMPOUND_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
address constant ETH_COMPOUND_WBTC = 0xe85Dc543813B8c2CFEaAc371517b925a166a9293;

// Aave V3 aTokens
address constant ETH_A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

// Morpho Blue
address constant ETH_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
bytes32 constant ETH_MORPHO_USDC_MARKET = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc; // USDC/wstETH 86%
bytes32 constant ETH_MORPHO_USDT_MARKET = 0xa921ef34e2fc7a27ccc50ae7e4b154e16c9799d3387076c421423ef52ac4df99; // USDT/WBTC 86%
bytes32 constant ETH_MORPHO_WETH_MARKET = 0xc54d7acf14de29e0e5527cabd7a576506870346a78a11a6762e2cca66322ec41; // WETH/wstETH 94.5%

// Fluid fTokens (ERC-4626)
address constant ETH_FLUID_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
address constant ETH_FLUID_USDT = 0x5C20B550819128074FD538Edf79791733ccEdd18;
address constant ETH_FLUID_WETH = 0x90551c1795392094FE6D29B758EcCD233cFAa260;

// Rewards infrastructure
address constant ETH_AAVE_REWARDS = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
address constant ETH_SPARK_REWARDS = 0x4370D3b6C9588E02ce9D22e684387859c7Ff5b34;
address constant ETH_COMET_REWARDS = 0x1B0e765F6224C21223AeA2af16c1C46E38885a40;
address constant ETH_COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;

// Uniswap V3
address constant ETH_UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

// Uniswap V2
address constant ETH_UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

/// @notice Ethereum + USDC: Aave V3 + Compound V3 + Spark + Morpho + Fluid
contract EthUSDC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "ethereum";
        token = ETH_USDC;
        tokenSymbol = "USDC";
        aavePool = ETH_AAVE_POOL;
        aaveAToken = ETH_A_USDC;
        compoundComet = ETH_COMPOUND_USDC;
        sparkPool = ETH_SPARK_POOL;
        morpho = ETH_MORPHO;
        morphoMarketId = ETH_MORPHO_USDC_MARKET;
        fluidFToken = ETH_FLUID_USDC;
        aaveRewardsController = ETH_AAVE_REWARDS;
        sparkRewardsController = ETH_SPARK_REWARDS;
        cometRewards = ETH_COMET_REWARDS;
        compRewardToken = ETH_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
        uniswapRouter = ETH_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ETH_COMP, uint24(3000), ETH_WETH, uint24(500), ETH_USDC);
        uniV2Router = ETH_UNISWAP_V2_ROUTER;
        wrappedNative = ETH_WETH;
    }
}

/// @notice Ethereum + USDT: Aave V3 + Compound V3 + Spark + Morpho + Fluid
contract EthUSDT is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "ethereum";
        token = ETH_USDT;
        tokenSymbol = "USDT";
        aavePool = ETH_AAVE_POOL;
        compoundComet = ETH_COMPOUND_USDT;
        sparkPool = ETH_SPARK_POOL;
        morpho = ETH_MORPHO;
        morphoMarketId = ETH_MORPHO_USDT_MARKET;
        fluidFToken = ETH_FLUID_USDT;
        aaveRewardsController = ETH_AAVE_REWARDS;
        sparkRewardsController = ETH_SPARK_REWARDS;
        cometRewards = ETH_COMET_REWARDS;
        compRewardToken = ETH_COMP;
        depositAmount = 100_000e6;
        userBalance = 500_000e6;
        uniswapRouter = ETH_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ETH_COMP, uint24(3000), ETH_WETH, uint24(500), ETH_USDT);
        uniV2Router = ETH_UNISWAP_V2_ROUTER;
        wrappedNative = ETH_WETH;
    }
}

/// @notice Ethereum + WETH: Aave V3 + Compound V3 + Spark + Morpho + Fluid
contract EthWETH is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "ethereum";
        token = ETH_WETH;
        tokenSymbol = "WETH";
        aavePool = ETH_AAVE_POOL;
        compoundComet = ETH_COMPOUND_WETH;
        sparkPool = ETH_SPARK_POOL;
        morpho = ETH_MORPHO;
        morphoMarketId = ETH_MORPHO_WETH_MARKET;
        fluidFToken = ETH_FLUID_WETH;
        aaveRewardsController = ETH_AAVE_REWARDS;
        sparkRewardsController = ETH_SPARK_REWARDS;
        cometRewards = ETH_COMET_REWARDS;
        compRewardToken = ETH_COMP;
        depositAmount = 50e18;
        userBalance = 250e18;
        uniswapRouter = ETH_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ETH_COMP, uint24(3000), ETH_WETH);
        uniV2Router = ETH_UNISWAP_V2_ROUTER;
        wrappedNative = ETH_WETH;
    }
}

/// @notice Ethereum + WBTC: Aave V3 + Compound V3 (no Spark/Morpho/Fluid for WBTC)
contract EthWBTC is BaseChainForkTest {
    function _configure() internal override {
        forkRpc = "ethereum";
        token = ETH_WBTC;
        tokenSymbol = "WBTC";
        aavePool = ETH_AAVE_POOL;
        compoundComet = ETH_COMPOUND_WBTC;
        sparkPool = address(0);
        morpho = address(0);
        fluidFToken = address(0);
        aaveRewardsController = ETH_AAVE_REWARDS;
        cometRewards = ETH_COMET_REWARDS;
        compRewardToken = ETH_COMP;
        depositAmount = 2e8;
        userBalance = 10e8;
        uniswapRouter = ETH_UNISWAP_ROUTER;
        swapPath = abi.encodePacked(ETH_COMP, uint24(3000), ETH_WETH, uint24(3000), ETH_WBTC);
        uniV2Router = ETH_UNISWAP_V2_ROUTER;
        wrappedNative = ETH_WETH;
    }
}
