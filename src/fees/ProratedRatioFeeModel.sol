// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IFeeModel.sol";
import "../interfaces/ILoanRouterV2.sol";

import "../ScheduleLogic.sol";

/**
 * @title Prorated Ratio Fee Model
 * @author USD.AI Foundation
 */
contract ProratedRatioFeeModel is IFeeModel {
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
     * @notice Fixed-point scale
     */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /**
     * @notice Reference window duration used to prorate each window, 30.41666667 days in seconds, which is
     * 365 / 12 days, the average length of a monthly window
     */
    uint256 internal constant REFERENCE_WINDOW_DURATION = 2_628_000;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Decoded fee model options
     * @param windowRate Per-window rate (1e18-scaled) applied to the loan balance
     */
    struct Options {
        uint256 windowRate;
    }

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    constructor() {}

    /*------------------------------------------------------------------------*/
    /* API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IFeeModel
     */
    function FEE_MODEL_NAME() external pure returns (string memory) {
        return "ProratedRatioFeeModel";
    }

    /**
     * @inheritdoc IFeeModel
     */
    function FEE_MODEL_VERSION() external pure returns (string memory) {
        return "1.0";
    }

    /**
     * @inheritdoc IFeeModel
     */
    function validateOptions(
        bytes calldata data
    ) external pure {
        /* Decode and revert on malformed payloads */
        Options memory options = abi.decode(data, (Options));

        /* Validate per-window rate is below 100% */
        if (options.windowRate > FIXED_POINT_SCALE) revert InvalidOptions();
    }

    /**
     * @inheritdoc IFeeModel
     */
    function fee(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        ILoanRouterV2.LoanState calldata state,
        bytes calldata options,
        uint256
    ) external view returns (uint256) {
        Options memory options_ = abi.decode(options, (Options));

        /* Return 0 when there is no rate or no balance to charge against */
        if (options_.windowRate == 0 || state.balance == 0) return 0;

        /* Look up the deadline schedule */
        (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, state.originationTimestamp);

        /* Length of the window this payment covers */
        uint256 windowDuration = deadlines[state.repaymentCount]
            - (state.repaymentCount == 0 ? state.originationTimestamp : deadlines[state.repaymentCount - 1]);

        /* Prorate the window against an average month, rounding up in favor of the fee recipient */
        return Math.mulDiv(
            state.balance,
            options_.windowRate * windowDuration,
            FIXED_POINT_SCALE * REFERENCE_WINDOW_DURATION,
            Math.Rounding.Ceil
        );
    }
}
