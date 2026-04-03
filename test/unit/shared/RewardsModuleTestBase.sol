// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";

// ========================================================================
// Shared mock contracts for RewardsModule test suites.
// Single source of truth — no duplicate mocks across test files.
// ========================================================================

contract MockUSDCToken is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockRewardToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override asset;
    uint256 internal _balance;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256 amount) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balance += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        uint256 toSend = amount > _balance ? _balance : amount;
        _balance -= toSend;
        IERC20(asset).safeTransfer(msg.sender, toSend);
        return toSend;
    }

    function emergencyWithdraw() external override returns (uint256) {
        uint256 bal = _balance;
        _balance = 0;
        IERC20(asset).safeTransfer(msg.sender, bal);
        return bal;
    }

    function balanceOf() external view override returns (uint256) {
        return _balance;
    }

    function availableLiquidity() external view override returns (uint256) {
        return _balance;
    }

    function isHealthy() external pure override returns (bool) {
        return true;
    }

    function harvest(address) external pure override returns (uint256) {
        return 0;
    }

    function sweepReward(address token, address to) external override returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}

contract MockDexRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    uint256 public usdcOut;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function setUsdcOut(uint256 amount) external {
        usdcOut = amount;
    }

    function doSwap(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(usdc).safeTransfer(msg.sender, usdcOut);
    }
}

/// @dev For 2-leaf merkle trees. Simple, correct, auditor-friendly.
library MerkleHelper {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return uint256(a) < uint256(b)
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function rootOf2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return hashPair(a, b);
    }

    function proofFor0(bytes32, bytes32 b) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = b;
    }

    function proofFor1(bytes32 a, bytes32) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = a;
    }
}
