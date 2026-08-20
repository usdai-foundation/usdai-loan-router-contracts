// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import "./interfaces/ILoanRouterV2.sol";
import "./interfaces/ILoanRouterV2Hooks.sol";
import "./interfaces/IInterestRateModelV2.sol";
import "./interfaces/IDepositTimelock.sol";
import "./interfaces/IEscrowTimelock.sol";
import "./interfaces/IFeeModel.sol";

import "./libs/ExcessivelySafeCall.sol";

import "./ScheduleLogic.sol";

/**
 * @title Loan Logic V2
 * @author USD.AI Foundation
 */
library LoanLogicV2 {
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fixed point scale
     */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /**
     * @notice Hook gas limit (may receive less due to EIP-150)
     */
    uint256 internal constant HOOK_GAS_LIMIT = 500_000;

    /**
     * @notice Supports interface gas limit
     */
    uint256 internal constant SUPPORTS_INTERFACE_GAS_LIMIT = 30_000;

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when a fee is paid
     * @param loanTermsHash Loan terms hash
     * @param kind Fee kind
     * @param recipient Recipient address
     * @param feeModel Fee model address
     * @param amount Amount of fee paid
     */
    event FeePaid(
        bytes32 indexed loanTermsHash,
        ILoanRouterV2.FeeKind indexed kind,
        address indexed recipient,
        address feeModel,
        uint256 amount
    );

    /**
     * @notice Emitted when lender is repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Principal repaid
     * @param interest Interest paid
     * @param prepay Prepayment
     */
    event LenderRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest,
        uint256 prepay
    );

    /**
     * @notice Emitted when lender is liquidation repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Principal repaid
     * @param interest Interest paid
     */
    event LenderLiquidationRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest
    );

    /**
     * @notice Emitted when transfer failed
     * @param token Token address
     * @param recipient Recipient address
     * @param intendedRecipient Intended recipient address
     * @param amount Amount
     */
    event TransferFailed(
        address indexed token, address indexed recipient, address indexed intendedRecipient, uint256 amount
    );

    /**
     * @notice Emitted when hook failed
     * @param reason Reason
     */
    event HookFailed(string reason);

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Liquidation breakdown
     * @param tranchePrincipals Scaled principals per tranche
     * @param trancheInterests Scaled interests per tranche
     * @param remainingProceeds Scaled surplus after distribution
     */
    struct Liquidation {
        uint256[] tranchePrincipals;
        uint256[] trancheInterests;
        uint256 remainingProceeds;
    }

    /**
     * @notice Repayment breakdown
     * @param principalPayment Scaled principal payment due
     * @param interestPayment Scaled interest payment due
     * @param tranchePrincipals Scaled principals per tranche
     * @param trancheInterests Scaled interests per tranche
     * @param tranchePrepayments Scaled prepayments per tranche
     * @param prepayment Scaled prepayment derived from excess
     * @param repaymentFee Scaled repayment fee total
     * @param exitFee Scaled exit fee total
     * @param repayment Scaled total repayment the borrower must transfer
     * @param isStandalonePrepayment True if this a standalone prepayment
     */
    struct Repayment {
        uint256 principalPayment;
        uint256 interestPayment;
        uint256[] tranchePrincipals;
        uint256[] trancheInterests;
        uint256[] tranchePrepayments;
        uint256 prepayment;
        uint256 repaymentFee;
        uint256 exitFee;
        uint256 repayment;
        bool isStandalonePrepayment;
    }

    /*------------------------------------------------------------------------*/
    /* Hash and validate */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Compute loan terms hash from struct
     * @param loanTerms Loan terms
     * @return Loan terms hash
     */
    function hashLoanTerms(
        bytes memory loanTerms
    ) external view returns (bytes32) {
        return _hashLoanTerms(loanTerms);
    }

    /**
     * @notice Validate loan terms
     * @param loanTerms Loan terms
     */
    function validateLoanTerms(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms
    ) external view {
        if (loanTerms.expiration < block.timestamp) revert ILoanRouterV2.InvalidLoanTerms("Expiration");
        if (loanTerms.borrower == address(0)) revert ILoanRouterV2.InvalidLoanTerms("Borrower");
        if (loanTerms.currencyToken == address(0)) revert ILoanRouterV2.InvalidLoanTerms("Currency Token");
        if (loanTerms.collateralToken == address(0)) revert ILoanRouterV2.InvalidLoanTerms("Collateral Token");
        if (loanTerms.collateralTokenIds.length == 0) revert ILoanRouterV2.InvalidLoanTerms("Collateral Token IDs");
        if (loanTerms.interestRateSpec.model == address(0)) {
            revert ILoanRouterV2.InvalidLoanTerms("Interest Rate Model");
        }
        if (loanTerms.trancheSpecs.length == 0) revert ILoanRouterV2.InvalidLoanTerms("Tranche Specs");
        if (loanTerms.trancheSpecs.length > 32) revert ILoanRouterV2.InvalidLoanTerms("Tranche Specs");
        uint256 principal;
        for (uint256 i; i < loanTerms.trancheSpecs.length; i++) {
            if (loanTerms.trancheSpecs[i].rate == 0 || loanTerms.trancheSpecs[i].rate > FIXED_POINT_SCALE) {
                revert ILoanRouterV2.InvalidLoanTerms("Rate");
            }
            if (loanTerms.trancheSpecs[i].lender == address(0)) revert ILoanRouterV2.InvalidLoanTerms("Lender");
            if (loanTerms.trancheSpecs[i].amount == 0) revert ILoanRouterV2.InvalidLoanTerms("Tranche Amount");
            principal += loanTerms.trancheSpecs[i].amount;
        }
        for (uint256 i; i < loanTerms.feeSpecs.length; i++) {
            IFeeModel(loanTerms.feeSpecs[i].model).validateOptions(loanTerms.feeSpecs[i].options);
        }
        if (loanTerms.repaymentSpec.day < 1 || loanTerms.repaymentSpec.day > 31) {
            revert ILoanRouterV2.InvalidLoanTerms("Repayment Day");
        }
        if (loanTerms.repaymentSpec.totalDurationDays == 0 || loanTerms.repaymentSpec.totalDurationDays > 4000) {
            revert ILoanRouterV2.InvalidLoanTerms("Loan Duration Days");
        }
        if (
            loanTerms.repaymentSpec.timezoneOffsetSeconds < -43200 /* UTC-12 */
                || loanTerms.repaymentSpec.timezoneOffsetSeconds > 50400 /* UTC+14 */
        ) {
            revert ILoanRouterV2.InvalidLoanTerms("Timezone Offset");
        }
        (, uint64[] memory loanDeadlines) = ScheduleLogic.deadlines(loanTerms, uint64(block.timestamp));
        if (principal < loanDeadlines.length) {
            revert ILoanRouterV2.InvalidLoanTerms("Principal");
        }
    }

    /**
     * @notice Validate refinance loan terms
     * @param oldLoanTerms Old loan terms
     * @param newLoanTerms New loan terms
     * @param oldLoan Old loan state
     * @param oldLoanTermsHash Old loan terms hash
     */
    function validateRefinanceLoanTerms(
        ILoanRouterV2.LoanTermsV2 calldata oldLoanTerms,
        ILoanRouterV2.LoanTermsV2 calldata newLoanTerms,
        ILoanRouterV2.LoanState storage oldLoan,
        bytes32 oldLoanTermsHash
    ) external view {
        /* New loan terms cannot be expired */
        if (newLoanTerms.expiration < block.timestamp) revert ILoanRouterV2.InvalidLoanTerms("Expiration");

        /* Borrower must not change */
        if (oldLoanTerms.borrower != newLoanTerms.borrower) revert ILoanRouterV2.InvalidLoanTerms("Borrower");

        /* Currency token must not change */
        if (oldLoanTerms.currencyToken != newLoanTerms.currencyToken) {
            revert ILoanRouterV2.InvalidLoanTerms("Currency Token");
        }

        /* Collateral token must not change */
        if (oldLoanTerms.collateralToken != newLoanTerms.collateralToken) {
            revert ILoanRouterV2.InvalidLoanTerms("Collateral Token");
        }

        /* Collateral token IDs must not change */
        if (
            keccak256(abi.encode(oldLoanTerms.collateralTokenIds))
                != keccak256(abi.encode(newLoanTerms.collateralTokenIds))
        ) {
            revert ILoanRouterV2.InvalidLoanTerms("Collateral Token IDs");
        }

        /* Interest rate model must be set */
        if (newLoanTerms.interestRateSpec.model == address(0)) {
            revert ILoanRouterV2.InvalidLoanTerms("Interest Rate Model");
        }

        /* Interest rate model options must be valid */
        IInterestRateModelV2(newLoanTerms.interestRateSpec.model).validateOptions(newLoanTerms.interestRateSpec.options);

        /* Validate tranches */
        uint256 principal;
        for (uint8 i; i < newLoanTerms.trancheSpecs.length; i++) {
            if (newLoanTerms.trancheSpecs[i].rate == 0 || newLoanTerms.trancheSpecs[i].rate > FIXED_POINT_SCALE) {
                revert ILoanRouterV2.InvalidLoanTerms("Rate");
            }
            if (newLoanTerms.trancheSpecs[i].amount == 0) revert ILoanRouterV2.InvalidLoanTerms("Tranche Amount");
            principal += newLoanTerms.trancheSpecs[i].amount;
        }

        /* Validate each new fee spec's options */
        for (uint256 i; i < newLoanTerms.feeSpecs.length; i++) {
            IFeeModel(newLoanTerms.feeSpecs[i].model).validateOptions(newLoanTerms.feeSpecs[i].options);
        }

        /* New principal must cover at least one unit per repayment window */
        (, uint64[] memory loanDeadlines) = ScheduleLogic.deadlines(newLoanTerms, oldLoan.originationTimestamp);
        if (principal < loanDeadlines.length) revert ILoanRouterV2.InvalidLoanTerms("Principal");
    }

    /**
     * @notice Hash loan terms
     * @param loanTerms Loan terms
     * @return Loan terms hash
     */
    function _hashLoanTerms(
        bytes memory loanTerms
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, abi.decode(loanTerms, (ILoanRouterV2.LoanTermsV2))));
    }

    /**
     * @notice Validate approval signatures over a digest
     * @param digest EIP-712 digest
     * @param approvalAddresses Expected signer addresses
     * @param approvalSignatures Signatures over the digest
     */
    function validateApprovals(
        bytes32 digest,
        address[] calldata approvalAddresses,
        bytes[] calldata approvalSignatures
    ) external view {
        /* Validate matching lengths */
        if (approvalAddresses.length != approvalSignatures.length) revert ILoanRouterV2.InvalidLength();

        /* Verify each signature (EOA via ECDSA, contract via ERC-1271) */
        for (uint256 i; i < approvalAddresses.length; i++) {
            if (!SignatureChecker.isValidSignatureNowCalldata(approvalAddresses[i], digest, approvalSignatures[i])) {
                revert ILoanRouterV2.InvalidSignature();
            }
        }
    }

    /*------------------------------------------------------------------------*/
    /* Compute Helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Sum tranche amounts to get loan principal
     * @param loanTerms Loan terms
     * @return principal Unscaled principal
     */
    function computePrincipal(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms
    ) external pure returns (uint256 principal) {
        for (uint256 i; i < loanTerms.trancheSpecs.length; i++) {
            principal += loanTerms.trancheSpecs[i].amount;
        }
    }

    /**
     * @notice Compute fee total
     * @param kind Fee event tag
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param scaledAmount Scaled amount
     * @return scaledFeeTotal Scaled fee total
     */
    function _computeFees(
        ILoanRouterV2.FeeKind kind,
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint256 scaledAmount
    ) internal view returns (uint256 scaledFeeTotal) {
        /* Sum each applicable fee */
        for (uint256 i; i < loanTerms.feeSpecs.length; i++) {
            /* Skip specs whose kind doesn't match the current event */
            if (loanTerms.feeSpecs[i].kind != kind) continue;

            /* Accumulate fee */
            scaledFeeTotal += IFeeModel(loanTerms.feeSpecs[i].model)
                .fee(loanTerms, loan, loanTerms.feeSpecs[i].options, scaledAmount);
        }
    }

    /**
     * @notice Compute total fees for the given event
     * @param kind Fee event tag
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param scaledAmount Scaled amount
     * @return scaledFeeTotal Scaled total fee amount
     */
    function computeFees(
        ILoanRouterV2.FeeKind kind,
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint256 scaledAmount
    ) external view returns (uint256 scaledFeeTotal) {
        return _computeFees(kind, loanTerms, loan, scaledAmount);
    }

    /**
     * @notice Compute the repayment breakdown
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param scaleFactor Scale factor
     * @param scaledAmount Scaled amount paid by the borrower
     * @param scaledPrincipal Scaled principal
     * @return repayment Repayment breakdown
     */
    function computeRepayment(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint256 scaleFactor,
        uint256 scaledAmount,
        uint256 scaledPrincipal
    ) external view returns (Repayment memory repayment) {
        /* Read where this payment sits in the deadline schedule */
        (bool isCurrentWindowRepaid, bool isCurrentWindowOverdue) =
            _repaymentDeadlineStatus(loanTerms, loan, uint64(block.timestamp));

        /* Treat the payment as a prepayment when the current window is already repaid */
        if (isCurrentWindowRepaid) {
            return _computePrepayment(loanTerms, loan, scaleFactor, scaledAmount, scaledPrincipal);
        }

        /* Calculate repayment due */
        (
            repayment.principalPayment,
            repayment.interestPayment,
            repayment.tranchePrincipals,
            repayment.trancheInterests
        ) = IInterestRateModelV2(loanTerms.interestRateSpec.model).repayment(loanTerms, loan, uint64(block.timestamp));

        /* Compute repayment fees before any state update so the model sees the upcoming index */
        repayment.repaymentFee = _computeFees(ILoanRouterV2.FeeKind.Repayment, loanTerms, loan, scaledPrincipal);

        /* Validate base repayment amount (principal + interest + repayment fees) */
        uint256 requiredBase = repayment.principalPayment + repayment.interestPayment + repayment.repaymentFee;

        /* Calculate prepayment from excess, which an overdue loan cannot take until it is current */
        repayment.prepayment = !isCurrentWindowOverdue && scaledAmount > requiredBase
            ? Math.min(loan.balance - repayment.principalPayment, scaledAmount - requiredBase)
            : 0;

        /* Split prepayment across tranches */
        repayment.tranchePrepayments = _splitPrepayment(loanTerms, repayment.prepayment, scaledPrincipal / scaleFactor);

        /* Compute exit fees if this repayment closes the loan */
        if (repayment.principalPayment + repayment.prepayment == loan.balance) {
            repayment.exitFee = _computeFees(ILoanRouterV2.FeeKind.Exit, loanTerms, loan, scaledPrincipal);
        }

        /* Compute scaled total repayment amount */
        repayment.repayment = repayment.principalPayment + repayment.interestPayment + repayment.repaymentFee
            + repayment.exitFee + repayment.prepayment;
    }

    /**
     * @notice Compute the prepayment breakdown for a standalone principal prepayment
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param scaleFactor Scale factor
     * @param scaledAmount Scaled amount paid by the borrower
     * @param scaledPrincipal Scaled principal
     * @return repayment Prepayment breakdown
     */
    function _computePrepayment(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint256 scaleFactor,
        uint256 scaledAmount,
        uint256 scaledPrincipal
    ) internal view returns (Repayment memory repayment) {
        /* Mark the breakdown as a standalone prepayment */
        repayment.isStandalonePrepayment = true;

        /* Cap prepayment at the remaining balance */
        repayment.prepayment = Math.min(loan.balance, scaledAmount);

        /* Allocate empty principal and interest arrays for the lender payout */
        repayment.tranchePrincipals = new uint256[](loanTerms.trancheSpecs.length);
        repayment.trancheInterests = new uint256[](loanTerms.trancheSpecs.length);

        /* Split prepayment across tranches */
        repayment.tranchePrepayments = _splitPrepayment(loanTerms, repayment.prepayment, scaledPrincipal / scaleFactor);

        /* Charge exit fees if this prepayment closes the loan */
        if (repayment.prepayment == loan.balance) {
            repayment.exitFee = _computeFees(ILoanRouterV2.FeeKind.Exit, loanTerms, loan, scaledPrincipal);
        }

        /* Total is the prepayment plus any exit fee */
        repayment.repayment = repayment.prepayment + repayment.exitFee;
    }

    /**
     * @notice Check where a payment made at a timestamp sits in the deadline schedule
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param timestamp Timestamp to evaluate the schedule against
     * @return isCurrentWindowRepaid True when the repayment count runs ahead of the current window
     * @return isCurrentWindowOverdue True when the current window's deadline has already passed
     */
    function _repaymentDeadlineStatus(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint64 timestamp
    ) internal view returns (bool isCurrentWindowRepaid, bool isCurrentWindowOverdue) {
        /* Compute the schedule deadlines */
        (, uint64[] memory loanDeadlines) = ScheduleLogic.deadlines(loanTerms, loan.originationTimestamp);

        /* Current window is repaid when the last paid installment's deadline has not passed */
        isCurrentWindowRepaid = loan.repaymentCount > 0 && loanDeadlines[loan.repaymentCount - 1] >= timestamp;

        /* Current window is overdue once its own deadline has passed */
        isCurrentWindowOverdue = loanDeadlines[loan.repaymentCount] < timestamp;
    }

    /**
     * @notice Split a scaled prepayment across tranches pro-rata to original amounts
     * @param loanTerms Loan terms
     * @param scaledPrepayment Scaled prepayment to distribute
     * @param unscaledPrincipal Unscaled total principal
     * @return tranchePrepayments Scaled prepayment per tranche
     */
    function _splitPrepayment(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        uint256 scaledPrepayment,
        uint256 unscaledPrincipal
    ) private pure returns (uint256[] memory tranchePrepayments) {
        /* Allocate tranche prepayment array */
        tranchePrepayments = new uint256[](loanTerms.trancheSpecs.length);

        /* Track remaining prepayment to assign */
        uint256 scaledPrepaymentRemaining = scaledPrepayment;

        /* Split prepayment across every tranche */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Last tranche takes the remainder to avoid rounding dust */
            uint256 scaledTranchePrepayment = scaledPrepayment != 0
                ? (i == loanTerms.trancheSpecs.length - 1)
                    ? scaledPrepaymentRemaining
                    : Math.mulDiv(scaledPrepayment, loanTerms.trancheSpecs[i].amount, unscaledPrincipal)
                : 0;

            /* Store tranche prepayment */
            tranchePrepayments[i] = scaledTranchePrepayment;

            /* Reduce remaining prepayment */
            scaledPrepaymentRemaining -= scaledTranchePrepayment;
        }
    }

    /**
     * @notice Compute tranche distribution for liquidation proceeds
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param scaledProceedsAvailable Scaled proceeds after liquidation fee
     * @param principal Unscaled principal
     * @return liquidation Liquidation breakdown (scaled)
     */
    function computeLiquidation(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint256 scaledProceedsAvailable,
        uint256 principal
    ) external view returns (Liquidation memory liquidation) {
        /* Compute tranche interests via IRM (defaulted window plus grace period interest) */
        (,,, liquidation.trancheInterests) =
            IInterestRateModelV2(loanTerms.interestRateSpec.model).repayment(loanTerms, loan, uint64(block.timestamp));

        /* Compute tranche principals from remaining balance, pro-rata to original tranche amounts */
        liquidation.tranchePrincipals = new uint256[](loanTerms.trancheSpecs.length);
        {
            uint256 remainingBalance = loan.balance;
            for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
                liquidation.tranchePrincipals[i] = (i == loanTerms.trancheSpecs.length - 1)
                    ? remainingBalance
                    : Math.mulDiv(loan.balance, loanTerms.trancheSpecs[i].amount, principal);
                remainingBalance -= liquidation.tranchePrincipals[i];
            }
        }

        /* Initialize remaining proceeds */
        liquidation.remainingProceeds = scaledProceedsAvailable;

        /* Distribute remaining proceeds to tranche principals */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            liquidation.tranchePrincipals[i] = Math.min(liquidation.tranchePrincipals[i], liquidation.remainingProceeds);
            liquidation.remainingProceeds -= liquidation.tranchePrincipals[i];
        }

        /* Distribute remaining proceeds to tranche interests */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            liquidation.trancheInterests[i] = Math.min(liquidation.trancheInterests[i], liquidation.remainingProceeds);
            liquidation.remainingProceeds -= liquidation.trancheInterests[i];
        }
    }

    /*------------------------------------------------------------------------*/
    /* Quote */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Quote repayment for a loan at a timestamp
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param timestamp Timestamp
     * @param scaledPrincipal Scaled principal
     * @return scaledPrincipalPayment Scaled principal payment
     * @return scaledInterestPayment Scaled interest payment
     * @return scaledFee Scaled fee total
     */
    function quoteRepayment(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        uint64 timestamp,
        uint256 scaledPrincipal
    ) external view returns (uint256, uint256, uint256) {
        /* If loan is not active */
        if (loan.status != ILoanRouterV2.LoanStatus.Active) return (0, 0, 0);

        /* Read the schedule position of a payment at this timestamp */
        (bool isCurrentWindowRepaid,) = _repaymentDeadlineStatus(loanTerms, loan, timestamp);

        /* No scheduled payment is due when the current window is already repaid */
        if (isCurrentWindowRepaid) return (0, 0, 0);

        /* Calculate repayment due */
        (uint256 scaledPrincipalPayment, uint256 scaledInterestPayment,,) =
            IInterestRateModelV2(loanTerms.interestRateSpec.model).repayment(loanTerms, loan, timestamp);

        /* Sum repayment fees plus exit fee (if this repayment closes the loan) */
        uint256 scaledFee = _computeFees(ILoanRouterV2.FeeKind.Repayment, loanTerms, loan, scaledPrincipal);
        if (scaledPrincipalPayment == loan.balance) {
            scaledFee += _computeFees(ILoanRouterV2.FeeKind.Exit, loanTerms, loan, scaledPrincipal);
        }

        return (scaledPrincipalPayment, scaledInterestPayment, scaledFee);
    }

    /*------------------------------------------------------------------------*/
    /* Withdraw Funds */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Pull lender funds for a new loan
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param lenderDepositInfos Lender deposit infos
     * @param depositTimelock Deposit timelock address
     * @param escrowTimelock Escrow timelock address
     * @return offchainAmount Total escrow timelock funds withdrawn
     * @return onchainAmount Total deposit timelock funds withdrawn
     */
    function withdrawFunds(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        ILoanRouterV2.LenderDepositInfo[] calldata lenderDepositInfos,
        address depositTimelock,
        address escrowTimelock
    ) external returns (uint256 offchainAmount, uint256 onchainAmount) {
        /* Withdraw each tranche's funds from its timelock */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            if (lenderDepositInfos[i].depositType == ILoanRouterV2.DepositType.DepositTimelock) {
                /* Withdraw from deposit timelock */
                IDepositTimelock(depositTimelock)
                    .withdraw(
                        loanTerms.trancheSpecs[i].lender,
                        loanTermsHash_,
                        loanTerms.currencyToken,
                        loanTerms.trancheSpecs[i].amount
                    );

                /* Accumulate onchain amount */
                onchainAmount += loanTerms.trancheSpecs[i].amount;
            } else if (lenderDepositInfos[i].depositType == ILoanRouterV2.DepositType.EscrowTimelock) {
                /* Withdraw from escrow timelock */
                IEscrowTimelock(escrowTimelock)
                    .withdraw(loanTermsHash_, loanTerms.currencyToken, loanTerms.trancheSpecs[i].amount);

                /* Accumulate offchain amount */
                offchainAmount += loanTerms.trancheSpecs[i].amount;
            } else {
                /* Invalid deposit type */
                revert ILoanRouterV2.InvalidDepositType();
            }
        }
    }

    /*------------------------------------------------------------------------*/
    /* Pay Fees */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Pay each applicable fee
     * @param kind Fee event tag
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param loanTermsHash_ Loan terms hash
     * @param scaleFactor Scale factor
     * @param defaultFeeRecipient Default fee recipient
     * @param scaledAmount Scaled amount
     * @return scaledFeeTotal Scaled total fee transferred
     */
    function payFees(
        ILoanRouterV2.FeeKind kind,
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        bytes32 loanTermsHash_,
        uint256 scaleFactor,
        address defaultFeeRecipient,
        uint256 scaledAmount
    ) external returns (uint256) {
        return _payFees(kind, loanTerms, loan, loanTermsHash_, scaleFactor, defaultFeeRecipient, scaledAmount);
    }

    /**
     * @notice Pay each applicable fee
     * @param kind Fee event tag
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param loanTermsHash_ Loan terms hash
     * @param scaleFactor Scale factor
     * @param defaultFeeRecipient Default fee recipient
     * @param scaledAmount Scaled amount
     * @return scaledFeeTotal Scaled total fee transferred
     */
    function _payFees(
        ILoanRouterV2.FeeKind kind,
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState storage loan,
        bytes32 loanTermsHash_,
        uint256 scaleFactor,
        address defaultFeeRecipient,
        uint256 scaledAmount
    ) internal returns (uint256 scaledFeeTotal) {
        /* Pay each applicable fee */
        for (uint256 i; i < loanTerms.feeSpecs.length; i++) {
            /* Skip specs whose kind doesn't match the current event */
            if (loanTerms.feeSpecs[i].kind != kind) continue;

            /* Compute scaled fee amount */
            uint256 scaledFee = IFeeModel(loanTerms.feeSpecs[i].model)
                .fee(loanTerms, loan, loanTerms.feeSpecs[i].options, scaledAmount);
            uint256 fee = scaledFee / scaleFactor;

            /* Skip zero-amount fees */
            if (fee == 0) continue;

            /* Resolve recipient, falling back to the router's default fee recipient */
            address recipient =
                loanTerms.feeSpecs[i].recipient != address(0) ? loanTerms.feeSpecs[i].recipient : defaultFeeRecipient;

            /* Transfer fee to recipient otherwise redirect to default fee recipient */
            _transferOrRedirect(IERC20(loanTerms.currencyToken), recipient, fee, defaultFeeRecipient);

            /* Call onLoanFeePaid hook if recipient is a contract and implements ILoanRouterV2Hooks interface */
            if (_supportsHooksInterface(recipient)) {
                try ILoanRouterV2Hooks(recipient).onLoanFeePaid{gas: HOOK_GAS_LIMIT}(
                    loanTerms, loanTermsHash_, uint8(i), fee
                ) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }

            /* Emit fee paid event */
            emit FeePaid(loanTermsHash_, kind, recipient, loanTerms.feeSpecs[i].model, fee);

            /* Accumulate scaled total fee */
            scaledFeeTotal += scaledFee;
        }
    }

    /*------------------------------------------------------------------------*/
    /* Lender repayment */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Distribute lender repayments and call hooks
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param repayment Repayment breakdown
     * @param loanBalance Scaled loan balance after repayment
     * @param scaleFactor Scale factor
     * @param feeRecipient Fallback recipient for rejected transfers
     * @return scaledTotalRepayment Scaled total transferred
     */
    function repayLenders(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        Repayment calldata repayment,
        uint256 loanBalance,
        uint256 scaleFactor,
        address feeRecipient
    ) external returns (uint256) {
        /* Calculate unscaled loan balance */
        uint256 unscaledLoanBalance = loanBalance / scaleFactor;

        /* Repay lenders */
        uint256 totalRepayment;
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Calculate unscaled principal, interest, prepayment, and tranche total */
            uint256 tranchePrincipal = repayment.tranchePrincipals[i] / scaleFactor;
            uint256 interest = repayment.trancheInterests[i] / scaleFactor;
            uint256 prepayment = repayment.tranchePrepayments[i] / scaleFactor;
            uint256 trancheRepayment = tranchePrincipal + interest + prepayment;

            /* Accumulate unscaled total repayment */
            totalRepayment += trancheRepayment;

            /* Get tranche owner from ERC721 token holder */
            address owner = IERC721(address(this)).ownerOf(_tokenId(loanTermsHash_, i));

            /* Transfer unscaled repayment amount from this contract to token owner, falling back to fee recipient */
            if (trancheRepayment > 0) {
                _transferOrRedirect(IERC20(loanTerms.currencyToken), owner, trancheRepayment, feeRecipient);
            }

            /* Call onLoanRepayment hook if lender is a contract and implements ILoanRouterV2Hooks interface */
            if (_supportsHooksInterface(owner)) {
                try ILoanRouterV2Hooks(owner).onLoanRepayment{gas: HOOK_GAS_LIMIT}(
                    loanTerms, loanTermsHash_, i, unscaledLoanBalance, tranchePrincipal, interest, prepayment
                ) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }

            /* Emit lender repaid event */
            emit LenderRepaid(loanTermsHash_, owner, i, tranchePrincipal, interest, prepayment);
        }

        return totalRepayment * scaleFactor;
    }

    /**
     * @notice Distribute liquidation repayments and call hooks
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param liquidation Liquidation breakdown
     * @param scaleFactor Scale factor
     * @param feeRecipient Fallback recipient for rejected transfers
     */
    function repayLendersLiquidation(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        Liquidation calldata liquidation,
        uint256 scaleFactor,
        address feeRecipient
    ) external {
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Calculate unscaled principal, interest, and tranche total */
            uint256 principal = liquidation.tranchePrincipals[i] / scaleFactor;
            uint256 interest = liquidation.trancheInterests[i] / scaleFactor;
            uint256 trancheRepayment = principal + interest;

            /* Get tranche owner from ERC721 token holder */
            address owner = IERC721(address(this)).ownerOf(_tokenId(loanTermsHash_, i));

            /* Transfer unscaled repayment amount from this contract to token owner, falling back to fee recipient */
            if (trancheRepayment > 0) {
                _transferOrRedirect(IERC20(loanTerms.currencyToken), owner, trancheRepayment, feeRecipient);
            }

            /* Call onLoanCollateralLiquidated hook if lender supports it */
            if (_supportsHooksInterface(owner)) {
                try ILoanRouterV2Hooks(owner).onLoanCollateralLiquidated{gas: HOOK_GAS_LIMIT}(
                    loanTerms, loanTermsHash_, i, principal, interest
                ) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }

            /* Emit lender liquidation repaid event */
            emit LenderLiquidationRepaid(loanTermsHash_, owner, i, principal, interest);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Refinance */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Settle a refinance fee and cash movements and notify lenders
     * @param oldLoanTerms Old loan terms
     * @param newLoanTerms New loan terms
     * @param newLoan New loan state
     * @param oldLoanTermsHash Old loan terms hash
     * @param newLoanTermsHash New loan terms hash
     * @param oldBalance Scaled outstanding balance of the old loan and the refinance fee basis
     * @param scaleFactor Scale factor
     * @param depositTimelock Deposit timelock address
     * @param feeRecipient Default fee recipient and fallback recipient for rejected transfers
     * @return cashOut Net unscaled cash-out to the borrower, zero when the refinance is cash-in
     * @return cashIn Net unscaled cash-in from the borrower, zero when the refinance is cash-out
     * @return refinanceFee Unscaled refinance fee
     */
    function refinance(
        ILoanRouterV2.LoanTermsV2 calldata oldLoanTerms,
        ILoanRouterV2.LoanTermsV2 calldata newLoanTerms,
        ILoanRouterV2.LoanState storage newLoan,
        bytes32 oldLoanTermsHash,
        bytes32 newLoanTermsHash,
        uint256 oldBalance,
        uint256 scaleFactor,
        address depositTimelock,
        address feeRecipient
    ) external returns (uint256, uint256, uint256) {
        /* Calculate cash-out amount from the first tranche */
        uint256 cashOut = newLoanTerms.trancheSpecs[0].amount - oldLoanTerms.trancheSpecs[0].amount;

        /* Withdraw the lender's cash-out from the deposit timelock */
        if (cashOut > 0) {
            IDepositTimelock(depositTimelock)
                .withdraw(newLoanTerms.trancheSpecs[0].lender, newLoanTermsHash, newLoanTerms.currencyToken, cashOut);
        }

        /* Calculate cash-out amount for the second tranche from direct transfer by caller */
        if (oldLoanTerms.trancheSpecs.length == 1 && newLoanTerms.trancheSpecs.length == 2) {
            cashOut += newLoanTerms.trancheSpecs[1].amount;
        }

        /* Compute the scaled refinance fee on the old balance */
        uint256 scaledRefinanceFee = _computeFees(ILoanRouterV2.FeeKind.Refinance, newLoanTerms, newLoan, oldBalance);

        /* Compute unscaled refinance fee */
        uint256 refinanceFee =
            (scaledRefinanceFee % scaleFactor == 0
                ? scaledRefinanceFee / scaleFactor
                : scaledRefinanceFee / scaleFactor + 1);

        /* Transfer cash-out to the borrower */
        IERC20(newLoanTerms.currencyToken).safeTransfer(newLoanTerms.borrower, cashOut - refinanceFee);

        /* Pay the refinance fee */
        _payFees(
            ILoanRouterV2.FeeKind.Refinance,
            newLoanTerms,
            newLoan,
            newLoanTermsHash,
            scaleFactor,
            feeRecipient,
            oldBalance
        );

        /* Call onLoanRefinanced hook */
        ILoanRouterV2Hooks(newLoanTerms.trancheSpecs[0].lender).onLoanRefinanced{gas: HOOK_GAS_LIMIT}(
            oldLoanTerms,
            newLoanTerms,
            oldLoanTermsHash,
            newLoanTermsHash,
            0,
            newLoanTerms.trancheSpecs[0].amount - oldLoanTerms.trancheSpecs[0].amount,
            0
        );

        return (cashOut, 0, refinanceFee);
    }

    /*------------------------------------------------------------------------*/
    /* Liquidation */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Transfer collateral NFTs to liquidator and call onLoanLiquidated hooks
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param recipient Recipient of the collateral NFTs
     */
    function liquidateLoan(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        address recipient
    ) external {
        /* Transfer each collateral NFT to recipient */
        for (uint256 i; i < loanTerms.collateralTokenIds.length; i++) {
            IERC721(loanTerms.collateralToken)
                .safeTransferFrom(address(this), recipient, loanTerms.collateralTokenIds[i]);
        }

        /* Call onLoanLiquidated hook for each tranche */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Get tranche owner from ERC721 token holder */
            address owner = IERC721(address(this)).ownerOf(_tokenId(loanTermsHash_, i));

            if (_supportsHooksInterface(owner)) {
                try ILoanRouterV2Hooks(owner).onLoanLiquidated{gas: HOOK_GAS_LIMIT}(loanTerms, loanTermsHash_, i) {}
                catch (bytes memory reason) {
                    /* Emit hook failed event */
                    emit HookFailed(string(reason));
                }
            }
        }
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Compute lender position token ID
     */
    function _tokenId(
        bytes32 loanTermsHash_,
        uint8 trancheIndex
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(loanTermsHash_, trancheIndex)));
    }

    /**
     * @notice Redirect a failed transfer to the fee recipient
     * @param token Token address
     * @param intendedRecipient Intended recipient address
     * @param amount Unscaled amount
     * @param feeRecipient Fee recipient address
     */
    function _redirectRepayment(
        IERC20 token,
        address intendedRecipient,
        uint256 amount,
        address feeRecipient
    ) internal {
        /* Transfer to fee recipient if the intended recipient is not the fee recipient */
        if (intendedRecipient != feeRecipient) token.safeTransfer(feeRecipient, amount);

        emit TransferFailed(address(token), feeRecipient, intendedRecipient, amount);
    }

    /**
     * @notice Transfer to a recipient, redirecting to the fee recipient on failure
     * @param token Token address
     * @param recipient Recipient address
     * @param amount Unscaled amount
     * @param feeRecipient Fee recipient address
     */
    function _transferOrRedirect(
        IERC20 token,
        address recipient,
        uint256 amount,
        address feeRecipient
    ) internal {
        /* Transfer to recipient, falling back to the fee recipient on rejection */
        try token.transfer(recipient, amount) returns (bool success) {
            if (!success) _redirectRepayment(token, recipient, amount, feeRecipient);
        } catch {
            _redirectRepayment(token, recipient, amount, feeRecipient);
        }
    }

    /**
     * @notice Check if target implements ILoanRouterV2Hooks
     */
    function _supportsHooksInterface(
        address target
    ) internal view returns (bool) {
        if (target.code.length == 0) return false;
        (bool success, bytes memory returnData) = ExcessivelySafeCall.excessivelySafeStaticCall(
            target,
            SUPPORTS_INTERFACE_GAS_LIMIT,
            32,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterV2Hooks).interfaceId)
        );
        return success && returnData.length == 32 && uint256(bytes32(returnData)) == 1;
    }
}
