// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "../Base.t.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";

import {ProratedRatioFeeModel} from "src/fees/ProratedRatioFeeModel.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";

contract ProratedRatioFeeModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Origination on the 1st at midnight lands on the repayment-day anchor, so there is no stub */
    uint64 internal constant ANCHOR_ORIGINATION_TS = 1_704_067_200; /* 2024-01-01 00:00:00 UTC */

    /* Origination on the 15th is off the anchor, so the first window is a partial stub */
    uint64 internal constant STUB_ORIGINATION_TS = 1_705_276_800; /* 2024-01-15 00:00:00 UTC */

    /* First anchor after the stub origination */
    uint64 internal constant STUB_FIRST_DEADLINE = 1_706_745_600; /* 2024-02-01 00:00:00 UTC */

    /* 30.41666667 days, which is 365 / 12 days in seconds */
    uint256 internal constant REFERENCE_WINDOW_DURATION = 2_628_000;

    uint256 internal constant BALANCE = 1_000_000 * 1e18;

    uint256 internal constant RATE = 0.002e18;

    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    ProratedRatioFeeModel internal model;

    function setUp() public override {
        super.setUp();
        model = new ProratedRatioFeeModel();
    }

    function _terms() internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(users.lender1, 1_000_000 * 1e6, RATE_10_PCT));

        terms = LoanFixtures.makeTerms(USDC, tranches, "");

        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = 365;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;
    }

    function _state(
        uint256 balance,
        uint16 repaymentCount,
        uint64 originationTimestamp
    ) internal pure returns (LoanRouterV2.LoanState memory) {
        return LoanFixtures.makeState({
            balance: balance, repaymentCount: repaymentCount, originationTimestamp: originationTimestamp
        });
    }

    function _opts(
        uint256 rate
    ) internal pure returns (bytes memory) {
        return abi.encode(ProratedRatioFeeModel.Options({windowRate: rate}));
    }

    /* Premium for a window exactly one reference month long, used as a comparison point */
    function _flatFee(
        uint256 balance,
        uint256 rate
    ) internal pure returns (uint256) {
        return Math.mulDiv(balance, rate, 1e18, Math.Rounding.Ceil);
    }

    /* Premium for a window of the given length, mirroring the model */
    function _proratedFee(
        uint256 balance,
        uint256 rate,
        uint256 windowDuration
    ) internal pure returns (uint256) {
        return Math.mulDiv(balance, rate * windowDuration, 1e18 * REFERENCE_WINDOW_DURATION, Math.Rounding.Ceil);
    }

    /* Length of the window that the given repayment covers */
    function _windowDuration(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp,
        uint16 repaymentCount
    ) internal view returns (uint256) {
        (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, originationTimestamp);

        return deadlines[repaymentCount] - (repaymentCount == 0 ? originationTimestamp : deadlines[repaymentCount - 1]);
    }

    /*------------------------------------------------------------------------*/
    /* Test: metadata */
    /*------------------------------------------------------------------------*/

    function test__FeeModelName_Returns() public view {
        assertEq(model.FEE_MODEL_NAME(), "ProratedRatioFeeModel");
    }

    function test__FeeModelVersion_Returns() public view {
        assertEq(model.FEE_MODEL_VERSION(), "1.0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateOptions */
    /*------------------------------------------------------------------------*/

    function test__ValidateOptions_AcceptsWellFormed() public view {
        model.validateOptions(_opts(0));
        model.validateOptions(_opts(0.002e18));
        model.validateOptions(_opts(1e18));
    }

    function test__ValidateOptions_RevertWhen_RateAboveScale() public {
        vm.expectRevert(ProratedRatioFeeModel.InvalidOptions.selector);
        model.validateOptions(_opts(1e18 + 1));
    }

    function test__ValidateOptions_RevertWhen_Malformed() public {
        vm.expectRevert();
        model.validateOptions(hex"deadbeef");
    }

    /*------------------------------------------------------------------------*/
    /* Test: zero cases */
    /*------------------------------------------------------------------------*/

    function test__Fee_ZeroRate_ReturnsZero() public view {
        assertEq(model.fee(_terms(), _state(BALANCE, 0, STUB_ORIGINATION_TS), _opts(0), 0), 0);
    }

    function test__Fee_ZeroBalance_ReturnsZero() public view {
        /* The router rejects a rate premium model that owes a fee at a zero balance */
        assertEq(model.fee(_terms(), _state(0, 0, STUB_ORIGINATION_TS), _opts(RATE), 0), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: every window is prorated against 30.41666667 days */
    /*------------------------------------------------------------------------*/

    function test__Fee_FirstWindow_OnAnchor_IsProrated() public view {
        /* An on-anchor origination on 2024-01-01 runs a full January to the 2024-02-01 deadline */
        uint256 windowDuration = _windowDuration(_terms(), ANCHOR_ORIGINATION_TS, 0);
        assertEq(windowDuration, 31 days, "First window must run all of January");

        uint256 fee = model.fee(_terms(), _state(BALANCE, 0, ANCHOR_ORIGINATION_TS), _opts(RATE), 0);

        assertEq(fee, _proratedFee(BALANCE, RATE, windowDuration), "First window must be prorated by its length");

        /* January is longer than the 30.41666667 day reference, so it owes more than a flat month */
        assertGt(fee, _flatFee(BALANCE, RATE), "A 31 day window must owe more than a flat month");
    }

    function test__Fee_FirstWindow_Stub_IsProrated() public view {
        /* The stub runs 2024-01-15 to 2024-02-01, which is 17 days */
        uint256 stubDuration = STUB_FIRST_DEADLINE - STUB_ORIGINATION_TS;
        assertEq(stubDuration, 17 days, "Stub must be 17 days");

        uint256 fee = model.fee(_terms(), _state(BALANCE, 0, STUB_ORIGINATION_TS), _opts(RATE), 0);

        assertEq(fee, _proratedFee(BALANCE, RATE, stubDuration), "Stub window must be prorated by its length");

        /* Derive the same number from the flat fee and the 17 / 30.41666667 ratio */
        assertApproxEqAbs(
            fee,
            _flatFee(BALANCE, RATE) * stubDuration / REFERENCE_WINDOW_DURATION,
            1,
            "Stub window must be prorated against 30.41666667 days"
        );
    }

    function test__Fee_LaterWindows_AreProratedByOwnLength() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        /* Each window after the stub is priced off its own calendar length */
        for (uint16 i = 1; i < 5; i++) {
            uint256 windowDuration = _windowDuration(terms, STUB_ORIGINATION_TS, i);

            assertEq(
                model.fee(terms, _state(BALANCE, i, STUB_ORIGINATION_TS), _opts(RATE), 0),
                _proratedFee(BALANCE, RATE, windowDuration),
                "Later windows must be prorated by their own length"
            );
        }
    }

    function test__Fee_MatchesScheduleAcrossDaysAndWindows() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        /* Sweep the repayment day so anchor clamping and every month length come into play */
        uint8[4] memory repaymentDays = [1, 15, 28, 31];

        for (uint256 r = 0; r < repaymentDays.length; r++) {
            terms.repaymentSpec.day = repaymentDays[r];

            /* Sweep origination across a leap year so the stub length varies */
            for (uint256 offset = 0; offset < 366; offset += 7) {
                uint64 origination = uint64(ANCHOR_ORIGINATION_TS + offset * 1 days);

                (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, origination);

                /* Check the stub and the first few full windows against the schedule */
                for (uint16 i = 0; i < 4; i++) {
                    uint256 windowDuration = deadlines[i] - (i == 0 ? origination : deadlines[i - 1]);

                    assertEq(
                        model.fee(terms, _state(BALANCE, i, origination), _opts(RATE), 0),
                        _proratedFee(BALANCE, RATE, windowDuration),
                        "Fee must track the window length from the schedule"
                    );
                }
            }
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: window length drives the fee above or below a flat month */
    /*------------------------------------------------------------------------*/

    function test__Fee_ShortWindow_OwesLessThanFlatMonth() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        /* Window 1 off the stub origination is February 2024, which is 29 days */
        assertEq(_windowDuration(terms, STUB_ORIGINATION_TS, 1), 29 days, "Window 1 must be February 2024");

        assertLt(
            model.fee(terms, _state(BALANCE, 1, STUB_ORIGINATION_TS), _opts(RATE), 0),
            _flatFee(BALANCE, RATE),
            "A month shorter than the reference must owe less than a flat month"
        );
    }

    function test__Fee_LongWindow_OwesMoreThanFlatMonth() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        /* Window 2 off the stub origination is March 2024, which is 31 days */
        assertEq(_windowDuration(terms, STUB_ORIGINATION_TS, 2), 31 days, "Window 2 must be March 2024");

        assertGt(
            model.fee(terms, _state(BALANCE, 2, STUB_ORIGINATION_TS), _opts(RATE), 0),
            _flatFee(BALANCE, RATE),
            "A month longer than the reference must owe more than a flat month"
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: the schedule charges the loan duration exactly once */
    /*------------------------------------------------------------------------*/

    function test__Fee_SumAcrossSchedule_MatchesLoanDuration() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, STUB_ORIGINATION_TS);

        uint256 total;

        /* Add up the premium owed on every window of the schedule */
        for (uint16 i = 0; i < deadlines.length; i++) {
            total += model.fee(terms, _state(BALANCE, i, STUB_ORIGINATION_TS), _opts(RATE), 0);
        }

        /* The windows tile origination to the final deadline with no gap and no overlap */
        uint256 expected = _proratedFee(BALANCE, RATE, deadlines[deadlines.length - 1] - STUB_ORIGINATION_TS);

        /* Each window rounds up by at most one wei */
        assertApproxEqAbs(total, expected, deadlines.length, "Schedule must charge the loan duration exactly once");
    }

    /*------------------------------------------------------------------------*/
    /* Test: repayment count past the schedule */
    /*------------------------------------------------------------------------*/

    function test__Fee_RevertWhen_RepaymentCountBeyondSchedule() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        (, uint64[] memory deadlines) = ScheduleLogic.deadlines(terms, STUB_ORIGINATION_TS);

        /* The model reads the deadline for the repayment, so there is no window past the last one */
        vm.expectRevert();
        model.fee(terms, _state(BALANCE, uint16(deadlines.length), STUB_ORIGINATION_TS), _opts(RATE), 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: proportional to the balance */
    /*------------------------------------------------------------------------*/

    function test__Fee_ProportionalToBalance() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        uint256 single = model.fee(terms, _state(BALANCE, 0, STUB_ORIGINATION_TS), _opts(RATE), 0);
        uint256 doubled = model.fee(terms, _state(BALANCE * 2, 0, STUB_ORIGINATION_TS), _opts(RATE), 0);

        /* Doubling the balance doubles the prorated premium, allowing for rounding */
        assertApproxEqAbs(doubled, single * 2, 2, "Prorated premium must stay proportional to the balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: ignores the scaled amount argument */
    /*------------------------------------------------------------------------*/

    function test__Fee_IgnoresScaledAmount() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms();

        uint256 withZero = model.fee(terms, _state(BALANCE, 0, STUB_ORIGINATION_TS), _opts(RATE), 0);
        uint256 withAmount = model.fee(terms, _state(BALANCE, 0, STUB_ORIGINATION_TS), _opts(RATE), 5_000_000 * 1e18);

        assertEq(withZero, withAmount, "Fee must be charged against the balance, not the scaled amount");
    }
}
