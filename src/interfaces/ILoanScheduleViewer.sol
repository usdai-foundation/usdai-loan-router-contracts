// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ILoanRouterV2.sol";

/**
 * @title Loan Schedule Viewer Interface
 * @author USD.AI Foundation
 */
interface ILoanScheduleViewer {
    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Projected repayment window
     * @param deadline Window deadline
     * @param scaledPrincipal Scaled principal payment
     * @param scaledInterest Scaled interest payment
     * @param scaledFee Scaled fees payment
     * @param scaledTotal Scaled total payment
     * @param scaledRemainingBalance Scaled balance remaining after the payment
     */
    struct RepaymentWindow {
        uint64 deadline;
        uint256 scaledPrincipal;
        uint256 scaledInterest;
        uint256 scaledFee;
        uint256 scaledTotal;
        uint256 scaledRemainingBalance;
    }

    /**
     * @notice Projected repayment schedule
     * @param hasStub True when the calendar opens with a stub window
     * @param repayments Remaining repayment windows
     * @param scaledTotalPrincipal Scaled total principal over the remaining windows
     * @param scaledTotalInterest Scaled total interest over the remaining windows
     * @param scaledTotalFees Scaled total fees over the remaining windows
     */
    struct RepaymentSchedule {
        bool hasStub;
        RepaymentWindow[] repayments;
        uint256 scaledTotalPrincipal;
        uint256 scaledTotalInterest;
        uint256 scaledTotalFees;
    }

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid repayment count
     */
    error InvalidRepaymentCount();

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get loan router address
     * @return Loan router address
     */
    function loanRouter() external view returns (address);

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Project the full forward repayment schedule from the current loan state
     * @param loanTerms Loan terms
     * @return Full projected repayment schedule
     */
    function paymentSchedule(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms
    ) external view returns (RepaymentSchedule memory);

    /**
     * @notice Project the full forward repayment schedule from ABI-encoded loan terms
     * @param encodedLoanTerms ABI-encoded LoanTermsV2
     * @return Full projected repayment schedule
     */
    function paymentSchedule(
        bytes calldata encodedLoanTerms
    ) external view returns (RepaymentSchedule memory);

    /**
     * @notice Project the full forward repayment schedule from an explicit state
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param timestamp Reference timestamp
     * @return Full projected repayment schedule
     */
    function paymentSchedule(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState calldata loan,
        uint64 timestamp
    ) external view returns (RepaymentSchedule memory);

    /**
     * @notice Quote repayment for loan at the current timestamp (ABI-encoded loan terms)
     * @param encodedLoanTerms ABI-encoded LoanTermsV2
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feePayment Fees payment
     */
    function quote(
        bytes calldata encodedLoanTerms
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment);

    /**
     * @notice Quote repayment for loan at a given timestamp (ABI-encoded loan terms)
     * @param encodedLoanTerms ABI-encoded LoanTermsV2
     * @param timestamp Timestamp
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feePayment Fees payment
     */
    function quote(
        bytes calldata encodedLoanTerms,
        uint64 timestamp
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment);
}
