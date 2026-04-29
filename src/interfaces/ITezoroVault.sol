// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ITezoroVault
/// @notice Minimal interface for RewardsModuleV1_2 to interact with the vault.
interface ITezoroVault {
    function asset() external view returns (address);
    function depositRewards(uint256 amount) external;
}
