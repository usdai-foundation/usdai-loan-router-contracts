// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILoanRouterV2} from "./ILoanRouterV2.sol";

/**
 * @title Loan Router V2 Callback Hooks
 * @author USD.AI Foundation
 */
interface ILoanRouterV2Hooks {
    /**
     * @notice Called when loan is originated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    function onLoanOriginated(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex
    ) external;

    /**
     * @notice Called when lender is repaid
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     * @param loanBalance Loan balance
     * @param principal Principal repaid
     * @param interest Interest paid
     * @param prepay Prepayment
     */
    function onLoanRepayment(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex,
        uint256 loanBalance,
        uint256 principal,
        uint256 interest,
        uint256 prepay
    ) external;

    /**
     * @notice Called when loan fee is paid
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param feeSpecIndex Fee specification index
     * @param fee Fee paid
     */
    function onLoanFeePaid(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 feeSpecIndex,
        uint256 fee
    ) external;

    /**
     * @notice Called when loan is liquidated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    function onLoanLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex
    ) external;

    /**
     * @notice Called when loan collateral is liquidated
     * @param loanTerms Loan terms
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     * @param principal Principal repaid
     * @param interest Interest paid
     */
    function onLoanCollateralLiquidated(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash,
        uint8 trancheIndex,
        uint256 principal,
        uint256 interest
    ) external;

    /**
     * @notice Called when loan is refinanced
     * @param oldLoanTerms Old loan terms
     * @param newLoanTerms New loan terms
     * @param oldLoanTermsHash Old loan terms hash
     * @param newLoanTermsHash New loan terms hash
     * @param trancheIndex Old tranche index
     * @param cashOut Cash out amount
     * @param cashIn Cash in amount
     */
    function onLoanRefinanced(
        ILoanRouterV2.LoanTermsV2 calldata oldLoanTerms,
        ILoanRouterV2.LoanTermsV2 calldata newLoanTerms,
        bytes32 oldLoanTermsHash,
        bytes32 newLoanTermsHash,
        uint8 trancheIndex,
        uint256 cashOut,
        uint256 cashIn
    ) external;
}
