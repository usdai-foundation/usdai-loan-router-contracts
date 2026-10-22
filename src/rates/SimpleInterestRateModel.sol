// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IInterestRateModelV2.sol";
import "../interfaces/ILoanRouterV2.sol";

import "../ScheduleLogic.sol";

/**
 * @title Simple Interest Rate Model
 * @author USD.AI Foundation
 */
contract SimpleInterestRateModel is IInterestRateModelV2 {
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

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IInterestRateModelV2
     */
    function INTEREST_RATE_MODEL_NAME() external pure returns (string memory) {
        return "SimpleInterestRateModel";
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

        /* Previous deadline, or origination time for the first window */
        uint64 previousDeadline =
            state.repaymentCount == 0 ? state.originationTimestamp : deadlines[state.repaymentCount - 1];

        /* Compute principal payment */
        if (state.repaymentCount == 0 && hasStub && !options.principalAndInterestStubPayment && deadlines.length > 1) {
            /* Stub first payment is interest only */
            scaledPrincipalPayment = 0;
        } else {
            /* Equal installment of the remaining balance, last payment sweeps the remainder */
            scaledPrincipalPayment = state.balance / (deadlines.length - state.repaymentCount);
        }

        /* Compute interest payment */
        scaledInterestPayment = Math.mulDiv(
            state.balance * blendedRate, currentDeadline - previousDeadline, FIXED_POINT_SCALE, Math.Rounding.Ceil
        );

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
