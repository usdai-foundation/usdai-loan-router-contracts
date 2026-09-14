// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./interfaces/ILoanScheduleViewer.sol";
import "./interfaces/ILoanRouterV2.sol";
import "./interfaces/IInterestRateModelV2.sol";
import "./interfaces/IFeeModel.sol";
import "./ScheduleLogic.sol";

/**
 * @title Loan Schedule Viewer
 * @author USD.AI Foundation
 * @notice Stateless view contract that projects the full forward payment
 * schedule for a V2 loan by delegating to the already-deployed ScheduleLogic,
 * IRM, and fee-model contracts.
 */
contract LoanScheduleViewer is Initializable, ILoanScheduleViewer {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan router
     */
    ILoanRouterV2 private immutable _loanRouter;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan Schedule Viewer Constructor
     * @param loanRouter_ Loan router address
     */
    constructor(
        address loanRouter_
    ) {
        _disableInitializers();

        _loanRouter = ILoanRouterV2(loanRouter_);
    }

    /*------------------------------------------------------------------------*/
    /* Initialization */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     */
    function initialize() external initializer {}

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function loanRouter() external view returns (address) {
        return address(_loanRouter);
    }

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function paymentSchedule(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms
    ) external view returns (RepaymentSchedule memory) {
        /* Read onchain loan state */
        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 balance) =
            _loanRouter.loanState(_loanRouter.loanTermsHash(loanTerms));

        return _computeSchedule(
            loanTerms,
            ILoanRouterV2.LoanState({
                status: status,
                repaymentCount: repaymentCount,
                originationTimestamp: originationTimestamp,
                balance: balance
            }),
            uint64(block.timestamp)
        );
    }

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function paymentSchedule(
        bytes calldata encodedLoanTerms
    ) external view returns (RepaymentSchedule memory) {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = abi.decode(encodedLoanTerms, (ILoanRouterV2.LoanTermsV2));

        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 balance) =
            _loanRouter.loanState(_loanRouter.loanTermsHash(loanTerms));

        return _computeSchedule(
            loanTerms,
            ILoanRouterV2.LoanState({
                status: status,
                repaymentCount: repaymentCount,
                originationTimestamp: originationTimestamp,
                balance: balance
            }),
            uint64(block.timestamp)
        );
    }

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function paymentSchedule(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        ILoanRouterV2.LoanState calldata loan,
        uint64 timestamp
    ) external view returns (RepaymentSchedule memory) {
        return _computeSchedule(loanTerms, loan, timestamp);
    }

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function quote(
        bytes calldata encodedLoanTerms
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) {
        return quote(encodedLoanTerms, uint64(block.timestamp));
    }

    /**
     * @inheritdoc ILoanScheduleViewer
     */
    function quote(
        bytes calldata encodedLoanTerms,
        uint64 timestamp
    ) public view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = abi.decode(encodedLoanTerms, (ILoanRouterV2.LoanTermsV2));
        return _loanRouter.quote(loanTerms, timestamp);
    }

    /*------------------------------------------------------------------------*/
    /* Internal */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Sum tranche amounts to get loan principal
     * @param loanTerms Loan terms
     * @return principal Unscaled principal
     */
    function _computePrincipal(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal pure returns (uint256 principal) {
        for (uint256 i; i < loanTerms.trancheSpecs.length; i++) {
            principal += loanTerms.trancheSpecs[i].amount;
        }
    }

    /**
     * @notice Compute total fees for a given kind
     * @param kind Fee kind
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param windowIndex Window index
     * @param scaledAmount Scaled amount
     * @return scaledFeeTotal Scaled fee total
     */
    function _computeFees(
        ILoanRouterV2.FeeKind kind,
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        ILoanRouterV2.LoanState memory loan,
        uint256 windowIndex,
        uint256 scaledAmount
    ) internal view returns (uint256 scaledFeeTotal) {
        for (uint256 i; i < loanTerms.feeSpecs.length; i++) {
            if (loanTerms.feeSpecs[i].kind != kind) continue;

            scaledFeeTotal += IFeeModel(loanTerms.feeSpecs[i].model)
                .fee(
                    loanTerms,
                    ILoanRouterV2.LoanState({
                        status: loan.status,
                        repaymentCount: uint16(windowIndex),
                        originationTimestamp: loan.originationTimestamp,
                        balance: loan.balance
                    }),
                    loanTerms.feeSpecs[i].options,
                    scaledAmount
                );
        }
    }

    /**
     * @notice Compute the full forward repayment schedule
     * @param loanTerms Loan terms
     * @param loan Loan state
     * @param timestamp Reference timestamp, floors each window's payment time
     * @return schedule Full projected repayment schedule
     */
    function _computeSchedule(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        ILoanRouterV2.LoanState memory loan,
        uint64 timestamp
    ) internal view returns (RepaymentSchedule memory schedule) {
        /* Return an empty schedule for non-Active loans */
        if (loan.status != ILoanRouterV2.LoanStatus.Active) return schedule;

        if (loanTerms.trancheSpecs.length == 0) return schedule;

        /* Scale factor for the currency */
        uint256 scaleFactor = 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());

        /* Scaled principal */
        uint256 scaledPrincipal = _computePrincipal(loanTerms) * scaleFactor;

        /* Compute the deadline calendar */
        (bool hasStub, uint64[] memory deadlines) = ScheduleLogic.deadlines(loanTerms, loan.originationTimestamp);
        schedule.hasStub = hasStub;

        /* Reject state that is past the end of the calendar */
        if (loan.repaymentCount > deadlines.length) revert InvalidRepaymentCount();

        /* Number of remaining windows */
        uint256 remaining = deadlines.length - loan.repaymentCount;
        schedule.repayments = new RepaymentWindow[](remaining);

        /* Simulate each payment window */
        for (uint256 i; i < remaining; i++) {
            uint256 windowIndex = loan.repaymentCount + i;

            /* Floor the window payment time at the reference timestamp */
            uint64 windowTimestamp = deadlines[windowIndex] > timestamp ? deadlines[windowIndex] : timestamp;

            /* Query the IRM for this window's principal and interest */
            (uint256 scaledPrincipalPayment, uint256 scaledInterestPayment,,) = IInterestRateModelV2(
                    loanTerms.interestRateSpec.model
                )
                .repayment(
                    loanTerms,
                    ILoanRouterV2.LoanState({
                        status: loan.status,
                        repaymentCount: uint16(windowIndex),
                        originationTimestamp: loan.originationTimestamp,
                        balance: loan.balance
                    }),
                    windowTimestamp
                );

            /* Compute repayment fees */
            uint256 scaledFee =
                _computeFees(ILoanRouterV2.FeeKind.Repayment, loanTerms, loan, windowIndex, scaledPrincipal);

            /* Add exit fee if this payment closes the loan */
            if (scaledPrincipalPayment == loan.balance) {
                scaledFee += _computeFees(ILoanRouterV2.FeeKind.Exit, loanTerms, loan, windowIndex, scaledPrincipal);
            }

            /* Record the window */
            schedule.repayments[i] = RepaymentWindow({
                deadline: deadlines[windowIndex],
                scaledPrincipal: scaledPrincipalPayment,
                scaledInterest: scaledInterestPayment,
                scaledFee: scaledFee,
                scaledTotal: scaledPrincipalPayment + scaledInterestPayment + scaledFee,
                scaledRemainingBalance: loan.balance - scaledPrincipalPayment
            });

            /* Accumulate totals */
            schedule.scaledTotalPrincipal += scaledPrincipalPayment;
            schedule.scaledTotalInterest += scaledInterestPayment;
            schedule.scaledTotalFees += scaledFee;

            /* Simulate state transition */
            loan.balance -= scaledPrincipalPayment;
        }
    }
}
