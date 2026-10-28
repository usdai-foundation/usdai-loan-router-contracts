* AmortizedInterestRateModel v2.1 - 10/28/2026
    * Cap grace period rate at 100% APR.
    * Combine repayment fees into level payment.

* SimpleInterestRateModel v2.1 - 10/28/2026
    * Cap grace period rate at 100% APR.

* LoanRouterV2 v1.4 - 10/28/2026
    * Cap tranche rate at 100% APR.
    * Remove support for legacy loans in `refinance()` API.
    * Revert on lender hook failure in `refinance()` API.

* EscrowTimelock v1.1 - 10/28/2026
    * Cap deposit rate at 100% APR.

* LoanScheduleViewer v1.0 - 09/23/2026
    * Initial release.

* ReserveAccount v1.1 - 09/23/2026
    * Use actual repayment amount in `RepaymentForwarded` event.

* LoanRouter v1.3 - 09/23/2026
    * Fix prepayment calculation for overdue loans.
    * Add repayment amount return to `repay()` API.
    * Add support for cash-in and multi-tranche to `refinance()` API.
    * Add support for legacy pre-EscrowTimelock loans to `refinance()` API.

* LoanRouter v1.2 - 07/28/2026
    * Add cash-out support to `refinance()` API.
    * Add encoded loan terms to `LoanOriginated` event.

* ReserveAccountFactory v1.0 - 07/09/2026
    * Initial release.

* LoanRouterV2 v1.1 - 07/09/2026
    * Remove migration logic for LoanRouter v1.
    * Add support for standalone prepayment after repayment.
    * Add initial `refinance()` API.

* LoanRouterV2 v1.0 - 06/25/2026
    * Initial release.

* SimpleInterestRateModel v2.0 - 06/25/2026
    * Initial release.

* AmortizedInterestRateModel v2.0 - 06/25/2026
    * Initial release.

* PercentageFeeModel v1.0 - 06/25/2026
    * Initial release.

* AbsoluteFeeModel v1.0 - 06/25/2026
    * Initial release.

* ReserveAccount v1.0 - 06/25/2026
    * Initial release.

* CollateralTimelock v1.0 - 06/25/2026
    * Initial release.

* EscrowTimelock v1.0 - 06/25/2026
    * Initial release.

* DepositTimelock v1.2 - 06/25/2026
    * Remove swap adapters.
    * Reorder `depositor` and `context` parameters for `withdraw()` API.

* LoanRouter v1.1 - 03/03/2026
    * Fix elapsed tranche interest calculation in collateral liquidation.
    * Fix return data sanitization in `_supportsHooksInterface()` to prevent
      DoS by malicious lender.
    * Add `pause()` and `unpause()` APIs.

* DepositTimelock v1.1 - 01/23/2026
    * Add depositor `onDepositWithdrawn()` hook to `withdraw()`.

* SimpleInterestRateModel v1.1 - 12/16/2025
    * Fix principal calculation for final repayment.

* LoanRouter v1.0 - 12/03/2025
    * Initial release.

* DepositTimelock v1.0 - 12/03/2025
    * Initial release.
