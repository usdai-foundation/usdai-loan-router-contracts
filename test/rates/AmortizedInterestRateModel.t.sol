// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaseTest} from "../Base.t.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";

import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";
import {ProratedRatioFeeModel} from "src/fees/ProratedRatioFeeModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {IFeeModel} from "src/interfaces/IFeeModel.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";

contract AmortizedInterestRateModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Origination on the 1st at midnight lands on the repayment-day anchor, so there is no stub. */
    uint64 internal constant ORIGINATION_TS = 1_704_067_200; /* 2024-01-01 00:00:00 UTC */

    /* Origination on the 15th is off the anchor, so the first period is a stub. */
    uint64 internal constant STUB_ORIGINATION_TS = 1_705_276_800; /* 2024-01-15 00:00:00 UTC */

    uint16 internal constant CANONICAL_DURATION_DAYS = 365;

    /* The canonical no-stub schedule has 12 deadlines. */
    uint16 internal constant CANONICAL_DEADLINES = 12;

    uint256 internal constant TRANCHE_AMOUNT = 1_000_000 * 1e6; /* raw USDC units */
    uint256 internal constant BALANCE_SCALED = 1_000_000 * 1e18; /* 18-decimal scaled balance */

    /* Equal-total tolerance: one cent on a 18-decimal scaled payment */
    uint256 internal constant ONE_CENT = 1e16;

    /* Repayment fee of 0.5% of the outstanding balance for a reference month */
    uint256 internal constant FEE_RATE = 0.005e18;

    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    AmortizedInterestRateModel internal model;

    ProratedRatioFeeModel internal proratedRatioFeeModel;

    RatioFeeModel internal ratioFeeModel;

    function setUp() public override {
        super.setUp();

        model = new AmortizedInterestRateModel();

        proratedRatioFeeModel = new ProratedRatioFeeModel();

        ratioFeeModel = new RatioFeeModel();
    }

    function _defaultOpts() internal pure returns (bytes memory) {
        return abi.encode(
            AmortizedInterestRateModel.Options({
                gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: false
            })
        );
    }

    /* Options that make the stub window pay principal on top of interest */
    function _principalAndInterestStubOpts() internal pure returns (bytes memory) {
        return abi.encode(
            AmortizedInterestRateModel.Options({
                gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: true
            })
        );
    }

    function _gracedOpts(
        uint64 graceDuration,
        uint256 graceRate
    ) internal pure returns (bytes memory) {
        return abi.encode(
            AmortizedInterestRateModel.Options({
                gracePeriodDuration: graceDuration, gracePeriodRate: graceRate, principalAndInterestStubPayment: false
            })
        );
    }

    /* Single-tranche 10% loan, repaymentDay 1, given duration, no timezone offset */
    function _terms(
        uint16 durationDays,
        bytes memory irmOpts
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(users.lender1, TRANCHE_AMOUNT, RATE_10_PCT));

        terms = LoanFixtures.makeTerms(USDC, tranches, irmOpts);

        terms.repaymentSpec.day = 1;

        terms.repaymentSpec.totalDurationDays = durationDays;

        terms.repaymentSpec.timezoneOffsetSeconds = 0;
    }

    /* Single Repayment fee spec pointing at the prorated ratio fee model */
    function _proratedFeeSpecs(
        uint256 rate
    ) internal view returns (ILoanRouterV2.FeeSpec[] memory feeSpecs) {
        feeSpecs = new ILoanRouterV2.FeeSpec[](1);

        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Repayment,
            recipient: address(0),
            model: address(proratedRatioFeeModel),
            options: abi.encode(ProratedRatioFeeModel.Options({windowRate: rate}))
        });
    }

    /* Single Repayment fee spec pointing at the ratio fee model in balance mode */
    function _balanceRatioFeeSpecs(
        uint256 rate
    ) internal view returns (ILoanRouterV2.FeeSpec[] memory feeSpecs) {
        feeSpecs = new ILoanRouterV2.FeeSpec[](1);

        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Repayment,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Balance, rate: rate}))
        });
    }

    /* Single Repayment fee spec pointing at the ratio fee model in amount mode */
    function _amountRatioFeeSpecs(
        uint256 rate
    ) internal view returns (ILoanRouterV2.FeeSpec[] memory feeSpecs) {
        feeSpecs = new ILoanRouterV2.FeeSpec[](1);

        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Repayment,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: rate}))
        });
    }

    /* Same single-tranche loan carrying a prorated Repayment fee spec */
    function _termsWithFee(
        uint16 durationDays,
        bytes memory irmOpts,
        uint256 rate
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        terms = _terms(durationDays, irmOpts);

        terms.feeSpecs = _proratedFeeSpecs(rate);
    }

    /* Original principal scaled to 18 decimals, the amount the router passes to repayment fee models */
    function _scaledPrincipal(
        ILoanRouterV2.LoanTermsV2 memory terms
    ) internal view returns (uint256 scaledPrincipal) {
        uint256 scaleFactor = 10 ** (18 - IERC20Metadata(terms.currencyToken).decimals());

        for (uint256 i = 0; i < terms.trancheSpecs.length; i++) {
            scaledPrincipal += terms.trancheSpecs[i].amount * scaleFactor;
        }
    }

    /* Repayment fee the router charges for the window, passing the scaled principal like the router does */
    function _expectedFee(
        ILoanRouterV2.LoanTermsV2 memory terms,
        LoanRouterV2.LoanState memory state
    ) internal view returns (uint256 fee) {
        uint256 scaledPrincipal = _scaledPrincipal(terms);

        for (uint256 i = 0; i < terms.feeSpecs.length; i++) {
            fee += IFeeModel(terms.feeSpecs[i].model).fee(terms, state, terms.feeSpecs[i].options, scaledPrincipal);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Schedule helpers */
    /*------------------------------------------------------------------------*/

    function _schedule(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp
    ) internal pure returns (uint64[] memory deadlines) {
        (, deadlines) = ScheduleLogic.deadlines(terms, originationTimestamp);
    }

    function _hasStub(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp
    ) internal pure returns (bool stub) {
        (stub,) = ScheduleLogic.deadlines(terms, originationTimestamp);
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

    /*------------------------------------------------------------------------*/
    /* Test: metadata */
    /*------------------------------------------------------------------------*/

    function test__InterestRateModelName_Returns() public view {
        assertEq(model.INTEREST_RATE_MODEL_NAME(), "AmortizedInterestRateModel");
    }

    function test__InterestRateModelVersion_Returns() public view {
        assertEq(model.INTEREST_RATE_MODEL_VERSION(), "2.0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: gracePeriodEnd */
    /*------------------------------------------------------------------------*/

    function test__GracePeriodEnd_Returns() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 3, ORIGINATION_TS);

        assertEq(model.gracePeriodEnd(terms, state), _schedule(terms, ORIGINATION_TS)[3] + graceDuration);
    }

    /*------------------------------------------------------------------------*/
    /* Test: level payment - equal totals */
    /*------------------------------------------------------------------------*/

    function test__Repayment_NoStub_TotalPaymentIsLevel() public view {
        /* On-anchor origination: every cycle, including the first, pays the same principal + interest */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint256 balance = BALANCE_SCALED;
        uint256 referenceTotal;
        for (uint16 i = 0; i < deadlines.length; i++) {
            (uint256 principalPayment, uint256 interestPayment,,) =
                model.repayment(terms, _state(balance, i, ORIGINATION_TS), deadlines[i]);

            uint256 total = principalPayment + interestPayment;
            if (i == 0) {
                referenceTotal = total;
            } else {
                assertApproxEqAbs(total, referenceTotal, ONE_CENT, "Total payment must be level across cycles");
            }

            balance -= principalPayment;
        }

        /* The level schedule amortizes the balance to zero */
        assertEq(balance, 0, "Loan must amortize to zero");
    }

    function test__Repayment_Stub_TotalPaymentIsLevelAfterStub() public view {
        /* Off-anchor origination: the stub is interest-only, then every later cycle pays a level total */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, STUB_ORIGINATION_TS);

        uint256 balance = BALANCE_SCALED;
        uint256 referenceTotal;
        for (uint16 i = 0; i < deadlines.length; i++) {
            (uint256 principalPayment, uint256 interestPayment,,) =
                model.repayment(terms, _state(balance, i, STUB_ORIGINATION_TS), deadlines[i]);

            if (i == 0) {
                /* Stub pays interest only */
                assertEq(principalPayment, 0, "Stub pays no principal");
            } else if (i == 1) {
                referenceTotal = principalPayment + interestPayment;
            } else {
                assertApproxEqAbs(
                    principalPayment + interestPayment, referenceTotal, ONE_CENT, "Post-stub totals must be level"
                );
            }

            balance -= principalPayment;
        }

        assertEq(balance, 0, "Loan must amortize to zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: principal edges */
    /*------------------------------------------------------------------------*/

    function test__Repayment_Stub_PaysZeroPrincipal() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, STUB_ORIGINATION_TS);

        (uint256 principalPayment, uint256 interestPayment,,) =
            model.repayment(terms, state, _schedule(terms, STUB_ORIGINATION_TS)[0]);

        assertEq(principalPayment, 0, "Stub first payment pays no principal");

        /* Interest accrues over the stub window (Jan 15 to Feb 1 = 17 days) at 10% APR */
        uint256 stubDays = (_schedule(terms, STUB_ORIGINATION_TS)[0] - STUB_ORIGINATION_TS) / 86400;
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 10 / 100 * stubDays / 365, 0.001e18);
    }

    function test__Repayment_Stub_IsTheOnlyDeadline_Sweeps() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(10, _defaultOpts());

        uint64[] memory deadlines = _schedule(terms, STUB_ORIGINATION_TS);
        assertEq(deadlines.length, 1, "Fixture must yield a single deadline");
        assertTrue(_hasStub(terms, STUB_ORIGINATION_TS), "Fixture must be a stub origination");

        (uint256 principalPayment,,,) =
            model.repayment(terms, _state(BALANCE_SCALED, 0, STUB_ORIGINATION_TS), deadlines[0]);

        assertEq(principalPayment, BALANCE_SCALED, "Single-deadline stub sweeps the balance");
    }

    function test__Repayment_FinalWindow_SweepsBalance() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        (uint256 principalPayment,,,) =
            model.repayment(terms, _state(BALANCE_SCALED, lastIndex, ORIGINATION_TS), deadlines[lastIndex]);

        assertEq(principalPayment, BALANCE_SCALED);
    }

    function test__Repayment_SingleDeadlineLoan_Sweeps() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(15, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        assertEq(deadlines.length, 1, "Fixture must yield a single deadline");

        (uint256 principalPayment,,,) = model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), deadlines[0]);

        assertEq(principalPayment, BALANCE_SCALED);
    }

    function test__Repayment_Prepayment_ReamortizesDownward() public view {
        /* A prepayment lowers the balance, so the recomputed level total drops but stays level thereafter */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        /* Reference level total on the undisturbed schedule */
        (uint256 p0, uint256 i0,,) = model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), deadlines[0]);
        uint256 levelTotal = p0 + i0;

        /* Halve the balance at cycle 1 as if a large prepayment occurred */
        (uint256 p1, uint256 i1,,) =
            model.repayment(terms, _state((BALANCE_SCALED - p0) / 2, 1, ORIGINATION_TS), deadlines[1]);

        assertLt(p1 + i1, levelTotal, "Prepaid balance produces a smaller level total");
    }

    /*------------------------------------------------------------------------*/
    /* Test: window interest */
    /*------------------------------------------------------------------------*/

    function test__Repayment_WindowInterest_MatchesApr() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (, uint256 interestPayment,,) = model.repayment(terms, state, _schedule(terms, ORIGINATION_TS)[0]);

        /* Cycle 0 spans Jan 1 to Feb 1 (31 days) at 10% APR */
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 10 / 100 * 31 / 365, 0.001e18);
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace period interest */
    /*------------------------------------------------------------------------*/

    function _ungracedWindowInterest(
        uint16 repaymentCount
    ) internal view returns (uint256) {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, repaymentCount, ORIGINATION_TS);
        (, uint256 interestPayment,,) = model.repayment(terms, state, _schedule(terms, ORIGINATION_TS)[repaymentCount]);
        return interestPayment;
    }

    function test__Repayment_GracePeriod_WithinGrace_AddsExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0] + uint64(3 days);
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        uint256 graceInterest = interestPayment - _ungracedWindowInterest(0);
        assertApproxEqRel(graceInterest, BALANCE_SCALED * 14 / 100 * 3 / 365, 0.001e18);
    }

    function test__Repayment_GracePeriod_PastGrace_CappedAtDuration() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0] + uint64(30 days);
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        uint256 graceInterest = interestPayment - _ungracedWindowInterest(0);
        assertApproxEqRel(graceInterest, BALANCE_SCALED * 14 / 100 * 7 / 365, 0.001e18);
    }

    function test__Repayment_GracePeriod_AtDeadlineBoundary_NoExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (, uint256 interestPayment,,) = model.repayment(terms, state, _schedule(terms, ORIGINATION_TS)[0]);

        assertEq(interestPayment, _ungracedWindowInterest(0), "No grace interest exactly at the deadline");
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche blended rate and split */
    /*------------------------------------------------------------------------*/

    function test__Repayment_MultiTranche_SplitReconciles() public view {
        ILoanRouterV2.TrancheSpec[] memory tranches = LoanFixtures.tranches2(
            LoanFixtures.tranche(users.lender1, 600_000 * 1e6, RATE_10_PCT),
            LoanFixtures.tranche(users.lender2, 400_000 * 1e6, RATE_14_PCT)
        );
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests
        ) = model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), _schedule(terms, ORIGINATION_TS)[0]);

        /* Blended APR over the 31-day first window */
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 116 / 1000 * 31 / 365, 0.001e18);

        /* Per-tranche sums reconcile to totals exactly */
        assertEq(tranchePrincipals[0] + tranchePrincipals[1], principalPayment);
        assertEq(trancheInterests[0] + trancheInterests[1], interestPayment);

        /* Principal splits by amount, interest by weighted rate */
        assertEq(tranchePrincipals[1], principalPayment * 40 / 100);
        assertApproxEqRel(trancheInterests[1], interestPayment * (14 * 400) / (10 * 600 + 14 * 400), 0.0001e18);
    }

    function test__Repayment_FinalWindow_TrancheSumEqualsBalance() public view {
        ILoanRouterV2.TrancheSpec[] memory tranches = LoanFixtures.tranches2(
            LoanFixtures.tranche(users.lender1, 600_000 * 1e6, RATE_10_PCT),
            LoanFixtures.tranche(users.lender2, 400_000 * 1e6, RATE_14_PCT)
        );
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;

        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        uint256 finalBalance = 42_000_042e18;
        (uint256 principalPayment,, uint256[] memory tranchePrincipals,) =
            model.repayment(terms, _state(finalBalance, lastIndex, ORIGINATION_TS), deadlines[lastIndex]);

        assertEq(principalPayment, finalBalance, "Final payment sweeps the balance");
        assertEq(tranchePrincipals[0] + tranchePrincipals[1], finalBalance, "Tranche principals sum to the balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: edges and reverts */
    /*------------------------------------------------------------------------*/

    function test__Repayment_ZeroBalance_ZeroPrincipalAndInterest() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        (uint256 principalPayment, uint256 interestPayment,,) =
            model.repayment(terms, _state(0, lastIndex, ORIGINATION_TS), deadlines[lastIndex]);

        assertEq(principalPayment, 0);
        assertEq(interestPayment, 0);
    }

    function test__Repayment_RevertWhen_MalformedOptions() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        terms.interestRateSpec.options = "";

        vm.expectRevert();
        model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), ORIGINATION_TS);
    }

    function test__Repayment_RevertWhen_RepaymentCountOutOfBounds() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        vm.expectRevert();
        model.repayment(terms, _state(BALANCE_SCALED, CANONICAL_DEADLINES, ORIGINATION_TS), ORIGINATION_TS);
    }

    function test__Repayment_RevertWhen_SingleTrancheZeroRate() public {
        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(users.lender1, TRANCHE_AMOUNT, 0));
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;

        vm.expectRevert();
        model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), ORIGINATION_TS);
    }

    /*------------------------------------------------------------------------*/
    /* Test: validateOptions */
    /*------------------------------------------------------------------------*/

    function test__ValidateOptions_AcceptsWellFormed() public view {
        model.validateOptions(_defaultOpts());
    }

    function test__ValidateOptions_RevertWhen_Malformed() public {
        vm.expectRevert();
        model.validateOptions("");
    }

    function test__ValidateOptions_AcceptsGracePeriodRateAtMaximum() public view {
        model.validateOptions(_gracedOpts(3 days, MAX_INTEREST_RATE));
    }

    function test__ValidateOptions_RevertWhen_GracePeriodRateAboveMaximum() public {
        vm.expectRevert(AmortizedInterestRateModel.InvalidOptions.selector);
        model.validateOptions(_gracedOpts(3 days, MAX_INTEREST_RATE + 1));
    }

    /*------------------------------------------------------------------------*/
    /* Test: fuzz */
    /*------------------------------------------------------------------------*/

    function testFuzz_PrincipalSumsToBalance_FuzzedDuration(
        uint16 durationDaysFuzz
    ) public view {
        uint16 durationDays = uint16(bound(durationDaysFuzz, 1, 1825));

        ILoanRouterV2.LoanTermsV2 memory terms = _terms(durationDays, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint256 remaining = BALANCE_SCALED;
        for (uint16 i = 0; i < deadlines.length; i++) {
            (uint256 principalPayment,,,) = model.repayment(terms, _state(remaining, i, ORIGINATION_TS), deadlines[i]);
            remaining -= principalPayment;
        }

        assertEq(remaining, 0, "Principal payments must sum to the initial balance");
    }

    function testFuzz_PrincipalSumsToBalance_FuzzedDayAndOrigin(
        uint8 repaymentDayFuzz,
        uint32 epochOffsetFuzz,
        uint16 durationDaysFuzz
    ) public view {
        uint8 repaymentDay = uint8(bound(uint256(repaymentDayFuzz), 1, 31));
        uint64 originationTimestamp = uint64(946_684_800 + bound(uint256(epochOffsetFuzz), 0, 1_262_304_000));
        uint16 durationDays = uint16(bound(uint256(durationDaysFuzz), 1, 1825));

        ILoanRouterV2.LoanTermsV2 memory terms = _terms(durationDays, _defaultOpts());
        terms.repaymentSpec.day = repaymentDay;

        uint64[] memory deadlines = _schedule(terms, originationTimestamp);

        uint256 remaining = BALANCE_SCALED;
        for (uint16 i = 0; i < deadlines.length; i++) {
            (uint256 principalPayment,,,) =
                model.repayment(terms, _state(remaining, i, originationTimestamp), deadlines[i]);
            remaining -= principalPayment;
        }

        assertEq(remaining, 0, "Principal payments must sum to the initial balance");
    }

    function testFuzz_PrincipalPayment_NeverExceedsBalance(
        uint128 balanceFuzz,
        uint16 repaymentCountFuzz,
        uint16 durationDaysFuzz
    ) public view {
        uint16 durationDays = uint16(bound(uint256(durationDaysFuzz), 61, 1825));

        ILoanRouterV2.LoanTermsV2 memory terms = _terms(durationDays, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint16 repaymentCount = uint16(bound(uint256(repaymentCountFuzz), 0, deadlines.length - 1));
        uint256 balance = bound(uint256(balanceFuzz), 0, 1e29);

        (uint256 principalPayment,,,) =
            model.repayment(terms, _state(balance, repaymentCount, ORIGINATION_TS), deadlines[repaymentCount]);

        assertLe(principalPayment, balance, "Principal must never exceed the balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: repayment fee folded into the level payment */
    /*------------------------------------------------------------------------*/

    /* Walk the schedule and check principal + interest + fee stays level after the first amortizing window */
    function _assertLevelWithFee(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp,
        uint16 firstLevelIndex
    ) internal view {
        uint256 balance = BALANCE_SCALED;
        uint256 referenceTotal;
        uint64[] memory deadlines = _schedule(terms, originationTimestamp);
        for (uint16 i = 0; i < deadlines.length; i++) {
            LoanRouterV2.LoanState memory state = _state(balance, i, originationTimestamp);

            (uint256 principalPayment, uint256 interestPayment,,) = model.repayment(terms, state, deadlines[i]);

            uint256 total = principalPayment + interestPayment + _expectedFee(terms, state);
            if (i < firstLevelIndex) {
                assertEq(principalPayment, 0, "Stub pays no principal");
            } else if (i == firstLevelIndex) {
                referenceTotal = total;
            } else {
                assertApproxEqAbs(total, referenceTotal, ONE_CENT, "Total with fee must be level across cycles");
            }

            balance -= principalPayment;
        }

        assertEq(balance, 0, "Loan must amortize to zero");
    }

    function test__Repayment_NoStub_TotalWithFeeIsLevel() public view {
        /* On-anchor origination: principal + interest + fee is level from the first cycle */
        _assertLevelWithFee(_termsWithFee(CANONICAL_DURATION_DAYS, _defaultOpts(), FEE_RATE), ORIGINATION_TS, 0);
    }

    function test__Repayment_Stub_TotalWithFeeIsLevelAfterStub() public view {
        /* Off-anchor origination: the stub is interest only, then later cycles pay a level total with fee */
        _assertLevelWithFee(_termsWithFee(CANONICAL_DURATION_DAYS, _defaultOpts(), FEE_RATE), STUB_ORIGINATION_TS, 1);
    }

    function test__Repayment_PrincipalAndInterestStub_TotalWithFeeIsLevelFromFirstWindow() public view {
        /* The stub pays principal here, so the level payment projected off the short stub window must still
         * price the longer windows that follow it */
        _assertLevelWithFee(
            _termsWithFee(CANONICAL_DURATION_DAYS, _principalAndInterestStubOpts(), FEE_RATE), STUB_ORIGINATION_TS, 0
        );
    }

    function test__Repayment_BalanceRatioFee_TotalWithFeeIsNearlyLevel() public view {
        /* A ratio fee on the balance charges the same share every window whatever its length, while the model
         * projects it as a per-second rate off the current window. Totals only drift by the month length
         * difference, so they stay level to within half a percent and the loan still amortizes to zero. */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        terms.feeSpecs = _balanceRatioFeeSpecs(FEE_RATE);

        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint256 balance = BALANCE_SCALED;
        uint256 referenceTotal;
        for (uint16 i = 0; i < deadlines.length; i++) {
            LoanRouterV2.LoanState memory state = _state(balance, i, ORIGINATION_TS);

            (uint256 principalPayment, uint256 interestPayment,,) = model.repayment(terms, state, deadlines[i]);

            uint256 total = principalPayment + interestPayment + _expectedFee(terms, state);
            if (i == 0) {
                referenceTotal = total;
            } else {
                assertApproxEqRel(total, referenceTotal, 0.005e18, "Total with fee must be nearly level");
            }

            balance -= principalPayment;
        }

        assertEq(balance, 0, "Loan must amortize to zero");
    }

    function test__Repayment_AmountRatioFee_UsesScaledPrincipalNotBalance() public view {
        /* An amount-mode fee is a fixed share of the original principal. At half the balance it equals a
         * balance-mode fee at twice the rate, so the model must split principal and interest the same way for
         * both. A model that priced the amount-mode fee off the current balance would pay down more principal. */
        ILoanRouterV2.LoanTermsV2 memory amountTerms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        amountTerms.feeSpecs = _amountRatioFeeSpecs(FEE_RATE);

        ILoanRouterV2.LoanTermsV2 memory balanceTerms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        balanceTerms.feeSpecs = _balanceRatioFeeSpecs(FEE_RATE * 2);

        uint64[] memory deadlines = _schedule(amountTerms, ORIGINATION_TS);

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED / 2, 3, ORIGINATION_TS);

        assertEq(_expectedFee(amountTerms, state), _expectedFee(balanceTerms, state), "Fee amounts must match by setup");

        (uint256 amountPrincipal, uint256 amountInterest,,) = model.repayment(amountTerms, state, deadlines[3]);

        (uint256 balancePrincipal, uint256 balanceInterest,,) = model.repayment(balanceTerms, state, deadlines[3]);

        assertEq(amountPrincipal, balancePrincipal, "Equal fees must give equal principal");

        assertEq(amountInterest, balanceInterest, "Equal fees must give equal interest");
    }

    function test__Repayment_AmountRatioFee_AmortizesToZero() public view {
        /* A fixed fee on a falling balance is a rising share of each window, so the total drifts upward. The
         * model recomputes the level payment every window, so the loan must still amortize to zero and never
         * pay more principal than is outstanding. */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        terms.feeSpecs = _amountRatioFeeSpecs(FEE_RATE);

        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint256 balance = BALANCE_SCALED;
        for (uint16 i = 0; i < deadlines.length; i++) {
            LoanRouterV2.LoanState memory state = _state(balance, i, ORIGINATION_TS);

            (uint256 principalPayment,,,) = model.repayment(terms, state, deadlines[i]);

            assertLe(principalPayment, balance, "Principal must not exceed the balance");

            balance -= principalPayment;
        }

        assertEq(balance, 0, "Loan must amortize to zero");
    }

    function test__Repayment_Fee_LowersPrincipalVersusNoFee() public view {
        /* Same loan and window, one with a fee and one without */
        ILoanRouterV2.LoanTermsV2 memory termsWithFee = _termsWithFee(CANONICAL_DURATION_DAYS, _defaultOpts(), FEE_RATE);
        ILoanRouterV2.LoanTermsV2 memory termsWithoutFee = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        uint64[] memory deadlines = _schedule(termsWithFee, ORIGINATION_TS);

        (uint256 principalWithFee, uint256 interestWithFee,,) =
            model.repayment(termsWithFee, _state(BALANCE_SCALED, 0, ORIGINATION_TS), deadlines[0]);

        (uint256 principalWithoutFee, uint256 interestWithoutFee,,) =
            model.repayment(termsWithoutFee, _state(BALANCE_SCALED, 0, ORIGINATION_TS), deadlines[0]);

        assertLt(principalWithFee, principalWithoutFee, "Fee must reduce the principal paid down");

        assertEq(interestWithFee, interestWithoutFee, "Fee must not change the interest");
    }

    function test__Repayment_Fee_FinalWindowSweepsBalance() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _termsWithFee(CANONICAL_DURATION_DAYS, _defaultOpts(), FEE_RATE);
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        (uint256 principalPayment,,,) =
            model.repayment(terms, _state(BALANCE_SCALED, lastIndex, ORIGINATION_TS), deadlines[lastIndex]);

        assertEq(principalPayment, BALANCE_SCALED, "Final payment sweeps the balance");
    }

    function test__Repayment_Fee_ZeroBalance_ZeroPrincipalAndInterest() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _termsWithFee(CANONICAL_DURATION_DAYS, _defaultOpts(), FEE_RATE);
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        (uint256 principalPayment, uint256 interestPayment,,) =
            model.repayment(terms, _state(0, 1, ORIGINATION_TS), deadlines[1]);

        assertEq(principalPayment, 0, "Zero balance pays no principal");

        assertEq(interestPayment, 0, "Zero balance pays no interest");
    }

    function test__Repayment_Fee_MultiTranche_SplitReconciles() public view {
        ILoanRouterV2.TrancheSpec[] memory tranches = LoanFixtures.tranches2(
            LoanFixtures.tranche(users.lender1, 600_000 * 1e6, RATE_10_PCT),
            LoanFixtures.tranche(users.lender2, 400_000 * 1e6, RATE_14_PCT)
        );
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;
        terms.feeSpecs = _proratedFeeSpecs(FEE_RATE);

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests
        ) = model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), _schedule(terms, ORIGINATION_TS)[0]);

        /* Blended APR over the 31-day first window is unaffected by the fee */
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 116 / 1000 * 31 / 365, 0.001e18);

        /* Per-tranche sums reconcile to totals exactly */
        assertEq(tranchePrincipals[0] + tranchePrincipals[1], principalPayment);
        assertEq(trancheInterests[0] + trancheInterests[1], interestPayment);
    }

    function testFuzz_PrincipalSumsToBalance_WithFee(
        uint16 durationDaysFuzz,
        uint256 feeRateFuzz
    ) public view {
        uint16 durationDays = uint16(bound(durationDaysFuzz, 1, 1825));
        uint256 feeRate = bound(feeRateFuzz, 0, 0.05e18);

        ILoanRouterV2.LoanTermsV2 memory terms = _termsWithFee(durationDays, _defaultOpts(), feeRate);
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint256 remaining = BALANCE_SCALED;
        for (uint16 i = 0; i < deadlines.length; i++) {
            (uint256 principalPayment,,,) = model.repayment(terms, _state(remaining, i, ORIGINATION_TS), deadlines[i]);
            remaining -= principalPayment;
        }

        assertEq(remaining, 0, "Principal payments must sum to the initial balance");
    }

    function testFuzz_PrincipalPayment_NeverExceedsBalance_WithFee(
        uint128 balanceFuzz,
        uint16 repaymentCountFuzz,
        uint256 feeRateFuzz
    ) public view {
        uint256 feeRate = bound(feeRateFuzz, 0, 0.05e18);

        ILoanRouterV2.LoanTermsV2 memory terms = _termsWithFee(1825, _defaultOpts(), feeRate);
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        uint16 repaymentCount = uint16(bound(uint256(repaymentCountFuzz), 0, deadlines.length - 1));
        uint256 balance = bound(uint256(balanceFuzz), 0, 1e29);

        (uint256 principalPayment,,,) =
            model.repayment(terms, _state(balance, repaymentCount, ORIGINATION_TS), deadlines[repaymentCount]);

        assertLe(principalPayment, balance, "Principal must never exceed the balance");
    }
}
