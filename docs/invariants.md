# Invariants

## Stablecoin
- sum of balances for all holders is equal to `totalSupply` of `Stablecoin`
- conservation of `Stablecoin` is maintained

## CDM

- `totalSupply` of `Stablecoin` is less or equal to `globalDebt`
- `globalDebt` is less or equal to `globalDebtCeiling`
- sum of `credit` for all accounts is less or equal to `globalDebt`
- sum of `debt` for all `Vaults` is less or equal to `globalDebt`
- sum of `debt` for a `Vault` is less or equal to `debtCeiling`

## Minter
- `totalSupply` of `Stablecoin` is equal to credit balance of the Minter account
- balance of minter is always positive

## CDPVault

- `balanceOf` collateral `token`'s of a `CDPVault` is greater or equal to the sum of all the `CDPVault`'s `Position`'s `collateral` amounts and the sum of all `cash` balances
- sum of `normalDebt` of all `Positions` is equal to `totalNormalDebt`
- sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions = `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming all PositionIRS's are up to date
- sum of `normalDebt * rateAccumulator - accruedRebate` (debt) across all positions <= `totalNormalDebt * rateAccumulator -  globalAccruedRebate` (totalDebt) - assuming some PositionIRS's are not up to date
- `debt` for all `Positions` is greater than `debtFloor` or zero
- pauseAt should always be set when pausing
- emergency mode should only be triggered if the spot price decreases

## Interest Rate Model

- `rebateFactor` <= 1 (for all positions)
- 1 <= `rateAccumulator`
- sum of `accruedRebate` across all PositionIRS's = `globalAccruedRebate` - assuming all PositionIRS's are up to date
- sum of `accruedRebate` across all PositionIRS's <= `globalAccruedRebate` - assuming some PositionIRS's are not up to date
- `averageRebate` <= `totalNormalDebt`
- `accruedRebate` <= `normalDebt * deltaRateAccumulator`
- `globalAccruedRebate` <= `totalNormalDebt * deltaRateAccumulator`
- `rateAccumulator` at block x <= `rateAccumulator` at block y, if x < y and specifically if `rateAccumulator` was updated in between the blocks x and y
- sum of `rateAccumulator * normalDebt` across all positions = `rateAccumulator * totalNormalDebt` at any block x in which all positions (and their `rateAccumulator`) were updated
- `snapshotRateAccumulator` is equal to `rateAccumulator` post all IRS updates

## Credit Delegation

## Liquidation

- a liquidation should always make the position more safe
- position health after liquidation is smaller or equal to target health factor or fully liquidated
- liquidator should never pay more than `repayAmount`
- credit paid should never be larger than `debt` / `liquidationPenalty`
- `accruedBadDebt` should never exceed the sum of `debt` of liquidated positions
- `position.collateral` should be zero if `position.normalDebt` is zero for a liquidated position
- delta debt should be equal to credit paid * `liquidationPenalty`

## Exchange / Redemptions

- partial redemption should never make the position more unsafe