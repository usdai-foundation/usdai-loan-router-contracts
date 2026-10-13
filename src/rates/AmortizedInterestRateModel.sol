// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IFeeModel.sol";
import "../interfaces/IInterestRateModelV2.sol";
import "../interfaces/ILoanRouterV2.sol";

import "../ScheduleLogic.sol";

/**
 * @title Amortized Interest Rate Model
 * @author USD.AI Foundation
 */
contract AmortizedInterestRateModel is IInterestRateModelV2 {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid options
     */
    error InvalidOptions();

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fixed point scale
     */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /**
     * @notice Max per-second grace period interest rate (1e18-scaled), 100% APR over a 365 day year
     */
    uint256 internal constant MAX_GRACE_PERIOD_RATE = 31_709_791_983;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Decoded interest rate model options
     * @param principalAndInterestStubPayment When true, the first stub window pays principal and interest instead of
     * interest only
     * @param gracePeriodDuration Grace period duration after repayment deadline in seconds
     * @param gracePeriodRate Per-second grace period interest rate (1e18-scaled)
     */
    struct Options {
        bool principalAndInterestStubPayment;
        uint64 gracePeriodDuration;
        uint256 gracePeriodRate;
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    constructor() {}

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Decode the IRM options blob
     */
    function _decodeOptions(
        ILoanRouterV2.LoanTermsV2 calldata terms
    ) internal pure returns (Options memory) {
        return abi.decode(terms.interestRateSpec.options, (Options));
    }

    /**
     * @notice Compute the level total payment that amortizes the balance over the remaining windows
     * @param state Loan state
     * @param blendedRate Blended per-second interest and fee rate (1e18-scaled)
     * @param deadlines Full deadline schedule
     * @return Level total repayment per window, 1e18-scaled
     */
    function _computeLevelPayment(
        ILoanRouterV2.LoanState calldata state,
        uint256 blendedRate,
        uint64[] memory deadlines
    ) internal pure returns (uint256) {
        /* Sum of suffix growth products across the remaining windows */
        uint256 discountSum;

        /* Product of growth factors for the windows processed so far */
        uint256 runningProduct = FIXED_POINT_SCALE;

        /* Walk the remaining windows from the last one back to the current window */
        for (uint256 r = deadlines.length; r > state.repaymentCount; r--) {
            /* Window being processed */
            uint256 index = r - 1;

            /* Window duration in seconds */
            uint256 duration = deadlines[index] - (index == 0 ? state.originationTimestamp : deadlines[index - 1]);

            /* Accumulate the suffix product for this window */
            discountSum += runningProduct;

            /* Fold this window's growth factor into the running product */
            runningProduct = Math.mulDiv(runningProduct, FIXED_POINT_SCALE + blendedRate * duration, FIXED_POINT_SCALE);
        }

        /* Level payment amortizes the balance to zero over the remaining windows */
        return Math.mulDiv(state.balance, runningProduct, discountSum);
    }

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function INTEREST_RATE_MODEL_NAME() external pure returns (string memory) {
        return "AmortizedInterestRateModel";
    }

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function INTEREST_RATE_MODEL_VERSION() external pure returns (string memory) {
        return "2.1";
    }

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function validateOptions(
        bytes calldata data
    ) external pure {
        /* Reverts if the data is not a valid Options struct */
        Options memory options = abi.decode(data, (Options));

        /* Validate grace period rate is not more than max grace period rate */
        if (options.gracePeriodRate > MAX_GRACE_PERIOD_RATE) revert InvalidOptions();
    }

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function gracePeriodEnd(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state
    ) external pure returns (uint64) {
        /* Decode options */
        Options memory options = _decodeOptions(terms);

        /* Look up the deadline schedule */
        (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, state.originationTimestamp);

        /* Return current deadline plus grace period */
        return deadlines[state.repaymentCount] + options.gracePeriodDuration;
    }

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function repayment(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state,
        uint64 timestamp
    )
        external
        view
        returns (
            uint256 scaledPrincipalPayment,
            uint256 scaledInterestPayment,
            uint256[] memory scaledTranchePrincipals,
            uint256[] memory scaledTrancheInterests
        )
    {
        /* Decode options */
        Options memory options = _decodeOptions(terms);

        /* Compute rate-weighted metrics and the unscaled principal from the tranche specs */
        uint256 totalWeightedRate;
        uint256 principal;
        for (uint256 i; i < terms.trancheSpecs.length; i++) {
            totalWeightedRate += terms.trancheSpecs[i].rate * terms.trancheSpecs[i].amount;
            principal += terms.trancheSpecs[i].amount;
        }

        /* Blend the rate against the principal */
        uint256 blendedRate = totalWeightedRate / principal;

        /* Compute deadlines */
        (bool hasStub, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, state.originationTimestamp);

        /* Deadline for the current repayment window */
        uint64 currentDeadline = deadlines[state.repaymentCount];

        /* Window duration in seconds */
        uint256 windowDuration = currentDeadline
            - (state.repaymentCount == 0 ? state.originationTimestamp : deadlines[state.repaymentCount - 1]);

        /* Compute interest payment for the window */
        scaledInterestPayment =
            Math.mulDiv(state.balance * blendedRate, windowDuration, FIXED_POINT_SCALE, Math.Rounding.Ceil);

        /* Compute principal payment */
        if (state.repaymentCount == 0 && hasStub && !options.principalAndInterestStubPayment && deadlines.length > 1) {
            /* Stub first payment is interest only */
            scaledPrincipalPayment = 0;
        } else if (deadlines.length - state.repaymentCount == 1) {
            /* Last payment sweeps the remaining balance */
            scaledPrincipalPayment = state.balance;
        } else {
            /* Calculate scaled principal */
            uint256 scaledPrincipal = principal * 10 ** (18 - IERC20Metadata(terms.currencyToken).decimals());

            /* Sum repayment fees charged on this window */
            uint256 scaledRepaymentFees;
            for (uint256 i; i < terms.feeSpecs.length; i++) {
                if (terms.feeSpecs[i].kind != ILoanRouterV2.FeeKind.Repayment) continue;

                scaledRepaymentFees += IFeeModel(terms.feeSpecs[i].model)
                    .fee(terms, state, terms.feeSpecs[i].options, scaledPrincipal);
            }

            /* Calculate repayment fees as a per-second rate on the balance, so
            the level payment covers them in every window */
            uint256 feeRate = (state.balance != 0)
                ? Math.mulDiv(scaledRepaymentFees, FIXED_POINT_SCALE, state.balance * windowDuration)
                : 0;

            /* Compute level payment that covers all components (interest, fees, and principal) */
            uint256 levelPayment = _computeLevelPayment(state, blendedRate + feeRate, deadlines);

            /* Principal is whatever the level payment leaves after interest and fees */
            scaledPrincipalPayment = Math.min(
                (levelPayment > scaledInterestPayment + scaledRepaymentFees)
                    ? (levelPayment - scaledInterestPayment - scaledRepaymentFees)
                    : 0,
                state.balance
            );
        }

        /* Compute grace period interest, if past the current window's deadline */
        if (timestamp > currentDeadline) {
            scaledInterestPayment += Math.mulDiv(
                state.balance * options.gracePeriodRate,
                Math.min(timestamp - currentDeadline, options.gracePeriodDuration),
                FIXED_POINT_SCALE,
                Math.Rounding.Ceil
            );
        }

        /* Allocate per-tranche output arrays */
        scaledTranchePrincipals = new uint256[](terms.trancheSpecs.length);
        scaledTrancheInterests = new uint256[](terms.trancheSpecs.length);

        /* Split principal and interest across tranches, tracking rounding dust */
        uint256 remainingScaledPrincipal = scaledPrincipalPayment;
        uint256 remainingScaledInterest = scaledInterestPayment;
        for (uint256 i; i < terms.trancheSpecs.length; i++) {
            scaledTranchePrincipals[i] = Math.mulDiv(scaledPrincipalPayment, terms.trancheSpecs[i].amount, principal);
            scaledTrancheInterests[i] = Math.mulDiv(
                scaledInterestPayment, terms.trancheSpecs[i].rate * terms.trancheSpecs[i].amount, totalWeightedRate
            );
            remainingScaledPrincipal -= scaledTranchePrincipals[i];
            remainingScaledInterest -= scaledTrancheInterests[i];
        }

        /* Add dust to first tranche */
        if (remainingScaledPrincipal != 0) scaledTranchePrincipals[0] += remainingScaledPrincipal;
        if (remainingScaledInterest != 0) scaledTrancheInterests[0] += remainingScaledInterest;
    }
}
