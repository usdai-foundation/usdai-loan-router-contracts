# AGENTS.md

## Accepted loan configurations

Only `ORIGINATOR_ROLE` can call `originate()` and `refinance()`. This role sets all loan terms, which includes the interest rate model (IRM), the IRM options and the fee specs. A borrower or a third party cannot select these values.

The contracts do not enforce the pairings below. The originator applies them off-chain. A report that needs a configuration that is not in these tables is a trusted-role misconfiguration and is out of scope.

### Interest rate models

| IRM                          | Accepted repayment fee model                           | Notes                                                                                                                                                           |
| ---------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SimpleInterestRateModel`    | `ProratedRatioFeeModel`, `RatioFeeModel(Mode.Balance)` | `RatioFeeModel(Mode.Balance)` does not prorate the fee by window duration. It charges the full window fee on a short stub window.                               |
| `AmortizedInterestRateModel` | `ProratedRatioFeeModel`                                | The level payment converts the repayment fee into a per-second rate on the balance. This is correct only when the fee is linear in balance and window duration. |

### Fee models by fee kind

| Fee kind      | `scaledAmount` input | Accepted fee model                                                                         | Not accepted, and why                                                                                                                                                                                                                                                                                                   |
| ------------- | -------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Origination` | Principal            | `RatioFeeModel(Mode.Amount)`                                                               | `ProratedRatioFeeModel`: the fee changes with the stub window length. `AbsoluteFeeModel` larger than the principal: origination reverts.                                                                                                                                                                                |
| `Repayment`   | Principal            | `ProratedRatioFeeModel`, `RatioFeeModel(Mode.Balance)` with `SimpleInterestRateModel` only | `RatioFeeModel(Mode.Amount)` and `AbsoluteFeeModel`: the fee does not decrease with the balance. `RatioFeeModel(Mode.Balance)` with `AmortizedInterestRateModel`: the fee is not linear in window duration. With `AmortizedInterestRateModel`, these models cause overflow after a large prepayment or on a short stub. |
| `Exit`        | Principal            | `AbsoluteFeeModel`                                                                         | `RatioFeeModel(Mode.Balance)` and `ProratedRatioFeeModel`: a prepayment before the close reduces the fee.                                                                                                                                                                                                               |
| `Liquidation` | Liquidation proceeds | `RatioFeeModel(Mode.Amount)`                                                               | `AbsoluteFeeModel`, `RatioFeeModel(Mode.Balance)` and `ProratedRatioFeeModel`: the fee can be larger than the proceeds. Then `depositLiquidationProceeds()` underflows.                                                                                                                                                 |
| `Refinance`   | Old loan balance     | `RatioFeeModel(Mode.Amount)`, `AbsoluteFeeModel`                                           | `ProratedRatioFeeModel`: the fee changes with the length of the current window.                                                                                                                                                                                                                                         |

### Fee model reference

| Fee model                     | Fee formula                                         |
| ----------------------------- | --------------------------------------------------- |
| `AbsoluteFeeModel`            | `amount`                                            |
| `RatioFeeModel(Mode.Amount)`  | `rate * scaledAmount`                               |
| `RatioFeeModel(Mode.Balance)` | `rate * balance`                                    |
| `ProratedRatioFeeModel`       | `windowRate * balance * windowDuration / 2_628_000` |

`RatioFeeModel` and `ProratedRatioFeeModel` reject a rate larger than `1e18`.

## Lender hooks that revert

The router calls `ILoanRouterV2Hooks` functions on lenders and fee recipients. Some calls catch a revert. `onLoanOriginated()` and `onLoanRefinanced()` do not catch a revert, so a hook revert stops the transaction.

A report that only says "the hook can revert" is not a valid finding. This includes a PoC that deploys a mock hook, or that uses `vm.mockCallRevert()` or a similar cheat to force the revert. All lenders are KYB'ed counterparties. The originator selects them. A lender that reverts its own hook only blocks a loan that it agreed to fund. This is self-griefing and is out of scope.

A hook report is valid only if it does all of these:

- It uses the real hook contract that is deployed, for example `StakedUSDai`.
- It shows the inputs or state that make that contract revert, through a path that a third party can reach.
- It shows a loss to a party other than the lender that owns the hook.

## Intended design

The items below are intended behavior. A report about them is not a valid finding.

- Liquidation sends the surplus proceeds to the fee recipient. The borrower does not receive the surplus.
- `LIQUIDATOR_ROLE` can call `setLoanBreach()` on an active loan. Then `liquidate()` can liquidate the loan before the grace period ends.
- `refinance()` does not require a signature from the borrower or the lenders. Only `ORIGINATOR_ROLE` can call it.
- The pause does not apply to all functions. A report about a function that the pause does or does not stop is not a valid finding.
