# Tezoro Aggregator Contracts

Solidity smart contracts for the Tezoro Aggregator yield vault.

## Overview

Tezoro Aggregator is an ERC-4626 compliant vault that allocates user deposits across multiple DeFi lending protocols (Aave V3, Compound V3, Spark, Morpho Blue, Fluid, and any ERC-4626 vault). A keeper rebalances allocations; a performance fee is charged on yield above a high water mark. Withdrawals are always open regardless of pause state.

## Repository Structure

```
TezoroV1_1.sol                           Core ERC-4626 vault
RewardsModule.sol                      Claims executor, swap engine, auto-compounding
interfaces/
    IStrategy.sol                      Universal strategy adapter interface
    ITezoroV1_1.sol                      Vault interface for RewardsModule
    IAaveV3Pool.sol                    Aave V3 lending pool interface
    ICompoundV3Comet.sol               Compound V3 Comet interface
    ICometRewards.sol                  Compound V3 rewards interface
    IMorpho.sol                        Morpho Blue singleton interface
    IRewardsController.sol             Aave/Spark rewards controller interface
strategies/
    AaveV3Strategy.sol                 Aave V3 adapter (also used for Spark)
    CompoundV3Strategy.sol             Compound V3 adapter
    FluidStrategy.sol                  Fluid fToken adapter
    ERC4626MultiStrategy.sol           Multi-vault adapter (distributes across ERC-4626 sub-vaults)
    MorphoBlueMultiStrategy.sol        Multi-market Morpho adapter (distributes across Morpho Blue markets)
```

## Architecture

```
                    +-------------------+
User deposits -->   |   TezoroV1_1.sol    |   <-- ERC-4626 vault
                    | (idle buffer)     |
                    +--------+----------+
                             |
              keeper calls allocate() with bps weights
                             |
         +-------------------+-------------------+
         |         |         |         |         |
      AaveV3  Compound   Fluid    Morpho    ERC4626Multi
      Strategy  Strategy Strategy MultiStrat MultiStrat
         |         |         |         |         |
      Aave V3  Comet V3   fTokens  Morpho    Morpho Vaults,
      (+ Spark)                    Blue      MetaMorpho, etc.
                             |
              +-----------------------------+
              |      RewardsModule.sol       |
              | claim -> swap -> compound    |
              +-----------------------------+
```

### Deposit / Withdraw Flow

1. **Deposit:** User calls `deposit(assets, receiver)`. Vault mints shares, holds assets in idle buffer. Keeper later calls `allocate()` to deploy idle funds to strategies.
2. **Withdraw:** User calls `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)`. Vault first uses idle buffer; if insufficient, executes a waterfall withdrawal from strategies until the amount is covered. Try-catch on each strategy prevents a broken strategy from blocking withdrawals.

### Strategy Interface

All strategies implement `IStrategy`:

```solidity
function deposit(uint256 amount) external;
function withdraw(uint256 amount) external returns (uint256 withdrawn);
function emergencyWithdraw() external returns (uint256 withdrawn);
function balanceOf() external view returns (uint256);
function availableLiquidity() external view returns (uint256);
```

Multi-strategies (`ERC4626MultiStrategy`, `MorphoBlueMultiStrategy`) add sub-position management: the keeper allocates/deallocates across sub-vaults or sub-markets within the strategy.

## Key Mechanisms

### Virtual Shares Offset (Inflation Attack Defense)

`_decimalsOffset()` returns the underlying asset's decimals (read once at construction, stored as immutable). This creates a large virtual share supply that makes first-depositor inflation attacks economically infeasible. The offset scales automatically with the asset (6 for USDC, 18 for DAI, 8 for WBTC).

### Performance Fee (HWM)

- Fee applies only to yield above the all-time high water mark share price.
- Fee is **accrued before every withdrawal** (dodge-proof): `_accruePerformanceFee()` mints fee shares before ERC-4626 conversion in `withdraw()` and `redeem()`.
- Fee shares are minted to `feeRecipient`.
- Fee percentage changes are timelocked when increasing.
- Default: 15%. Range: 0--30%.

### Preview Functions (ERC-4626 Compliance)

All four preview functions (`previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem`) account for pending performance fee shares. This ensures preview values match actual execution outcomes, which is required by the ERC-4626 specification:

- `previewDeposit(x)` returns shares user will receive after fee accrual.
- `previewWithdraw(x)` returns shares that will be burned (>= actual, per spec).
- `previewRedeem(x)` returns assets that will be received (<= actual, per spec).

### maxWithdraw / maxRedeem

Account for pending fee dilution **and** available liquidity across strategies. This ensures `withdraw(maxWithdraw(x))` and `redeem(maxRedeem(x))` never revert. Each strategy's available liquidity is reduced by 2 wei to absorb rounding in underlying protocol withdrawals.

### Deposit Cap

Configurable `depositCap` (0 = unlimited). `maxDeposit()` and `maxMint()` use `previewDeposit()` (fee-aware) to accurately report remaining capacity.

### Idle Buffer

Configurable percentage (max 20%) of total assets held as idle in the vault for instant small withdrawals without strategy interaction. Maintained by keeper during `allocate()`.

### Timelock

Force-redeem operations and fee increases support an optional timelock. When `timelockDelay > 0`:
1. Admin calls `proposeTimelock(operationHash)`.
2. Wait for delay to pass.
3. Execute the operation.

Reducing the timelock delay itself is timelocked (at the current, longer delay). Increasing the delay is immediate (more restrictive = safe). Duplicate proposals for the same hash revert -- cancel first, then re-propose.

### Two-Step Admin Transfer

Admin ownership is transferred via a two-step process (`transferAdmin` + `acceptAdmin`) to prevent accidental transfers to wrong addresses. All contracts (vault, strategies, rewards module) use this pattern.

### Strategy Removal

`removeStrategy()` is non-reentrant. When removing a strategy with tracked funds, the vault attempts an emergency withdrawal. If recovery is partial, the lost amount is emitted via `StrategyRemovalFundsLost` for off-chain tracking. The total allocation is validated after removal to prevent exceeding 100%.

### Force Redeem

Admin can force-redeem users (single or batch up to 50). Uses a dust tolerance per-strategy (2 wei each or 1 bps of the asset amount, whichever is larger) to cover protocol-specific rounding errors in Morpho and Aave.

## Roles

| Role         | Key Permissions |
| ------------ | --------------- |
| **Admin**    | Add/remove/pause strategies, set allocations/caps/fees, freeze deposits, recall to idle, force redeem, transfer admin, set guardian |
| **Guardian** | Pause strategies and vault, freeze strategy deposits. Cannot unpause or unfreeze (one-way emergency brake). |
| **Keeper**   | Rebalance (`allocate`), reconcile strategy balances, harvest rewards, sweep strategy rewards, collect fees, allocate/deallocate within multi-strategies |
| **User**     | Deposit (when not frozen/paused, within cap), withdraw and redeem (always open, even when paused) |

## Reward Flow

```
1. harvestAll()              Aave/Compound claim directly to RewardsModule
2. executeClaim()            Merkle claims (Morpho URD, Merkl) land on strategy
3. sweepStrategyReward()     Forward from strategy to RewardsModule
4. swap()                    Swap reward token to base asset via whitelisted DEX router
5. sweepToVault()            Deposit base asset back into vault (auto-compounding)
```

The RewardsModule holds reward tokens; swaps happen in isolation from the vault. DEX routers are admin-whitelisted.

## Supported Protocols

| Protocol        | Strategy                  | Rewards Mechanism               | Chains          |
| --------------- | ------------------------- | ------------------------------- | --------------- |
| Aave V3         | `AaveV3Strategy`          | ARB via RewardsController       | Ethereum, Arbitrum |
| Compound V3     | `CompoundV3Strategy`      | COMP via CometRewards           | Ethereum, Arbitrum |
| Spark           | `AaveV3Strategy` (shared) | via RewardsController           | Ethereum        |
| Morpho Blue     | `MorphoBlueMultiStrategy` | MORPHO via URD + sweepReward    | Ethereum        |
| Fluid           | `FluidStrategy`           | via Merkl + sweepReward         | Ethereum, Arbitrum |
| ERC-4626 vaults | `ERC4626MultiStrategy`    | Protocol-dependent              | Ethereum, Arbitrum |

## Multi-Strategy Details

### ERC4626MultiStrategy

Distributes funds across whitelisted ERC-4626 sub-vaults (e.g., MetaMorpho, Morpho Vaults). Keeper calls `allocate(subVault, amount)` / `deallocate(subVault, amount)`. Sub-vaults can be added/removed by admin (removal requires zero position). All external calls are non-reentrant.

### MorphoBlueMultiStrategy

Distributes funds across whitelisted Morpho Blue markets (supply-side only). Keeper calls `allocate(marketId, amount)` / `deallocate(marketId, amount)`. Provides `accrueAllInterest()` for accurate balance reporting before vault reconciliation. Market removal requires zero position. All external calls are non-reentrant.

## Security Properties

### Invariants

- **Withdrawals never blocked:** `withdraw()` and `redeem()` work even when `paused == true`. Only deposits are frozen.
- **Fee-dodge impossible:** `_accruePerformanceFee()` runs inside `withdraw()`, `redeem()`, `forceRedeem()`, and `batchForceRedeem()` before share conversion.
- **Broken strategy cannot DoS:** All strategy calls in withdraw waterfall, rebalance, reconcile, and harvest use try-catch. A reverting strategy is skipped, not blocking.
- **No reentrancy:** `ReentrancyGuard` on all state-changing vault functions and all strategy entry points.
- **No unsafe transfers:** `SafeERC20` used for all token transfers.

### Attack Mitigations

| Attack Vector | Defense |
| ------------- | ------- |
| First-depositor inflation / donation | Virtual shares offset (`_decimalsOffset = assetDecimals`), internal accounting |
| Reentrancy | `ReentrancyGuard` on vault + all strategies |
| Unsafe ERC-20 | `SafeERC20` everywhere |
| Rounding exploits | ERC-4626 rounding in vault's favor, preview functions account for pending fees |
| Excessive deposits | Configurable deposit cap |
| Reward token contamination | Swaps isolated in RewardsModule, never in vault |
| Fee dodging | Performance fee accrued before withdrawal conversion |
| Admin transfer to wrong address | Two-step transfer (`transferAdmin` + `acceptAdmin`) |
| Sudden fee hike | Fee increases are timelocked |
| Timelock delay reduction | Reducing delay is itself timelocked at the current (longer) delay |

### Trust Model

Users trust:
1. The immutable vault contract code.
2. The admin (single address, planned migration to multisig). Admin can add/remove strategies, change allocations, change fees (timelocked), force-redeem users (optional timelock), and pause.
3. The keeper (bounded actions). Keeper can rebalance and harvest but cannot extract funds or change parameters.

Admin **cannot** block withdrawals. The only irreversible admin action is strategy removal with fund loss (emitted as event).

## Compiler Settings

- Solidity `^0.8.26`
- OpenZeppelin Contracts v5.x (`ERC4626`, `ERC20`, `ReentrancyGuard`, `SafeERC20`, `Math`)

## Deployments

### Ethereum Mainnet

| Contract | Address |
| -------- | ------- |
| TezoroV1_1 (tUSDC-A, conservative, v1) | [`0x6992B35d23A0B7732a6b0d6e6Fc10A76c08B3d16`](https://etherscan.io/address/0x6992B35d23A0B7732a6b0d6e6Fc10A76c08B3d16) |
| TezoroV1_1 (tUSDC-A, conservative, v1.1) | [`0x7cc42747862ecACe79FA89BeFcB29C94d2558dEC`](https://etherscan.io/address/0x7cc42747862ecACe79FA89BeFcB29C94d2558dEC) |
| TezoroV1_1 (tUSDC-B, moderate, v1) | [`0x7E441d9b0947bF4CA007770233776476bb539B09`](https://etherscan.io/address/0x7E441d9b0947bF4CA007770233776476bb539B09) |
| TezoroV1_1 (tUSDC-B, moderate, v1.1) | [`0xD0F2812F57D284c0d30Ddd8f73b146Ef0cD5a25c`](https://etherscan.io/address/0xD0F2812F57D284c0d30Ddd8f73b146Ef0cD5a25c) |
| TezoroV1_1 (tUSDC, aggressive, v1) | [`0xD22DC6a8087d1D8507A3FD96d9653613157f1832`](https://etherscan.io/address/0xD22DC6a8087d1D8507A3FD96d9653613157f1832) |
| TezoroV1_1 (tUSDC, aggressive, v1.1) | [`0xa139C6a7dd1Bd76Ae3FBCCF4F8bEbA5C4f26513d`](https://etherscan.io/address/0xa139C6a7dd1Bd76Ae3FBCCF4F8bEbA5C4f26513d) |
