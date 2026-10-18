// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseTest} from "../Base.t.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";

import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";

contract SimpleInterestRateModelTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Origination on the 1st at midnight lands on the repayment-day anchor, so there is no stub.
       Canonical loan: 1M USDC, repaymentDay 1, 365-day duration, 10% APR. */
    uint64 internal constant ORIGINATION_TS = 1_704_067_200; /* 2024-01-01 00:00:00 UTC */

    /* Origination on the 15th is off the anchor, so the first period is a stub. */
    uint64 internal constant STUB_ORIGINATION_TS = 1_705_276_800; /* 2024-01-15 00:00:00 UTC */

    uint16 internal constant CANONICAL_DURATION_DAYS = 365;

    /* The canonical no-stub schedule has 12 deadlines (Feb 1 ... Dec 1 2024, then the Jan 1 2025 anchor). */
    uint16 internal constant CANONICAL_DEADLINES = 12;

    uint256 internal constant TRANCHE_AMOUNT = 1_000_000 * 1e6; /* raw USDC units */
    uint256 internal constant BALANCE_SCALED = 1_000_000 * 1e18; /* 18-decimal scaled balance */

    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    SimpleInterestRateModel internal model;

    function setUp() public override {
        super.setUp();

        model = new SimpleInterestRateModel();
    }

    function _defaultOpts() internal pure returns (bytes memory) {
        return abi.encode(
            SimpleInterestRateModel.Options({
                gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: false
            })
        );
    }

    function _gracedOpts(
        uint64 graceDuration,
        uint256 graceRate
    ) internal pure returns (bytes memory) {
        return abi.encode(
            SimpleInterestRateModel.Options({
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

    /*------------------------------------------------------------------------*/
    /* Schedule helpers */
    /*------------------------------------------------------------------------*/

    function _schedule(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp
    ) internal pure returns (uint64[] memory deadlines) {
        /* Drop the stub flag */
        (, deadlines) = ScheduleLogic.deadlines(terms, originationTimestamp);
    }

    function _hasStub(
        ILoanRouterV2.LoanTermsV2 memory terms,
        uint64 originationTimestamp
    ) internal pure returns (bool stub) {
        /* Keep only the stub flag */
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
        assertEq(model.INTEREST_RATE_MODEL_NAME(), "SimpleInterestRateModel");
    }

    function test__InterestRateModelVersion_Returns() public view {
        assertEq(model.INTEREST_RATE_MODEL_VERSION(), "2.0");
    }

    /*------------------------------------------------------------------------*/
    /* Test: stub detection */
    /*------------------------------------------------------------------------*/

    function test__HasStub_OffAnchorOrigination_True() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        assertTrue(_hasStub(terms, STUB_ORIGINATION_TS), "Off-anchor origination must flag a stub");
    }

    function test__HasStub_OnAnchorOrigination_False() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        assertFalse(_hasStub(terms, ORIGINATION_TS), "On-anchor origination must not flag a stub");
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

    function test__GracePeriodEnd_AtFinalDeadline() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));

        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, lastIndex, ORIGINATION_TS);

        assertEq(model.gracePeriodEnd(terms, state), deadlines[lastIndex] + graceDuration);
    }

    /*------------------------------------------------------------------------*/
    /* Test: principal - stub is interest only */
    /*------------------------------------------------------------------------*/

    function test__Repayment_Stub_PaysZeroPrincipal() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, STUB_ORIGINATION_TS);

        (uint256 principalPayment, uint256 interestPayment,,) =
            model.repayment(terms, state, _schedule(terms, STUB_ORIGINATION_TS)[0]);

        /* The stub charges interest only */
        assertEq(principalPayment, 0, "Stub first payment pays no principal");

        /* Interest still accrues over the stub window (Jan 15 to Feb 1 = 17 days) */
        uint256 stubDays = (_schedule(terms, STUB_ORIGINATION_TS)[0] - STUB_ORIGINATION_TS) / 86400;
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 10 / 100 * stubDays / 365, 0.001e18);
    }

    function test__Repayment_Stub_IsTheOnlyDeadline_Sweeps() public view {
        /* Off-anchor origination with a duration short enough that the only deadline is the closing anchor */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(10, _defaultOpts());

        uint64[] memory deadlines = _schedule(terms, STUB_ORIGINATION_TS);
        assertEq(deadlines.length, 1, "Fixture must yield a single deadline");
        assertTrue(_hasStub(terms, STUB_ORIGINATION_TS), "Fixture must be a stub origination");

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, STUB_ORIGINATION_TS);

        (uint256 principalPayment,,,) = model.repayment(terms, state, deadlines[0]);

        /* A stub that is also the only deadline must sweep the full balance, not pay zero */
        assertEq(principalPayment, BALANCE_SCALED, "Single-deadline stub sweeps the balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: principal - equal installments */
    /*------------------------------------------------------------------------*/

    function test__Repayment_NoStub_FirstWindow_EqualInstallment() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (uint256 principalPayment,,,) = model.repayment(terms, state, _schedule(terms, ORIGINATION_TS)[0]);

        /* No stub: principal is balance / deadlines */
        assertEq(principalPayment, BALANCE_SCALED / CANONICAL_DEADLINES);
    }

    function test__Repayment_MiddleWindows_EqualInstallments() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        /* Walk the undisturbed schedule and confirm every installment is equal */
        uint256 balance = BALANCE_SCALED;
        uint256 firstInstallment;
        for (uint16 i = 0; i < deadlines.length - 1; i++) {
            (uint256 principalPayment,,,) = model.repayment(terms, _state(balance, i, ORIGINATION_TS), deadlines[i]);

            if (i == 0) {
                firstInstallment = principalPayment;
            } else {
                assertApproxEqAbs(principalPayment, firstInstallment, 1, "Installments must be equal");
            }

            balance -= principalPayment;
        }
    }

    function test__Repayment_FinalWindow_SweepsBalance() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, lastIndex, ORIGINATION_TS);

        (uint256 principalPayment,,,) = model.repayment(terms, state, deadlines[lastIndex]);

        /* The last window sweeps the whole remaining balance */
        assertEq(principalPayment, BALANCE_SCALED);
    }

    function test__Repayment_SingleDeadlineLoan_Sweeps() public view {
        /* On-anchor origination with a 15-day duration yields a single deadline */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(15, _defaultOpts());

        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        assertEq(deadlines.length, 1, "Fixture must yield a single deadline");

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (uint256 principalPayment,,,) = model.repayment(terms, state, deadlines[0]);

        assertEq(principalPayment, BALANCE_SCALED);
    }

    function test__Repayment_Prepayment_ScalesInstallmentDown() public view {
        /* A lower-than-scheduled balance produces a proportionally smaller installment */
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        /* Scheduled balance at cycle 1 versus a balance halved by a prior prepayment */
        uint256 scheduledBalance = BALANCE_SCALED - BALANCE_SCALED / CANONICAL_DEADLINES;

        (uint256 scheduledPayment,,,) =
            model.repayment(terms, _state(scheduledBalance, 1, ORIGINATION_TS), deadlines[1]);

        (uint256 halfPayment,,,) = model.repayment(terms, _state(scheduledBalance / 2, 1, ORIGINATION_TS), deadlines[1]);

        assertApproxEqAbs(halfPayment, scheduledPayment / 2, 1, "Half the balance pays half the installment");
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

    function test__Repayment_FebruaryWindow_Interest_MatchesApr() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);

        /* Cycle 1 is Feb 1 to Mar 1 2024 (29 days in the leap year) */
        uint256 balanceAtCycle1 = BALANCE_SCALED - BALANCE_SCALED / CANONICAL_DEADLINES;

        (, uint256 interestPayment,,) = model.repayment(terms, _state(balanceAtCycle1, 1, ORIGINATION_TS), deadlines[1]);

        uint256 windowDays = (deadlines[1] - deadlines[0]) / 86400;
        assertApproxEqRel(interestPayment, balanceAtCycle1 * 10 / 100 * windowDays / 365, 0.001e18);
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

    function test__Repayment_GracePeriod_BeforeDeadline_NoExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0] - 1;
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        assertEq(interestPayment, _ungracedWindowInterest(0));
    }

    function test__Repayment_GracePeriod_WithinGrace_AddsExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 graceElapsed = uint64(3 days);
        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0] + graceElapsed;
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

    function test__Repayment_GracePeriod_ZeroRate_NoExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, 0));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0] + uint64(5 days);
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        assertEq(interestPayment, _ungracedWindowInterest(0));
    }

    function test__Repayment_GracePeriod_AtDeadlineBoundary_NoExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[0];
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        assertEq(interestPayment, _ungracedWindowInterest(0), "No grace interest exactly at the deadline");
    }

    function test__Repayment_GracePeriod_AtMiddleCycle_AddsExtraInterest() public view {
        uint64 graceDuration = uint64(7 days);
        ILoanRouterV2.LoanTermsV2 memory terms =
            _terms(CANONICAL_DURATION_DAYS, _gracedOpts(graceDuration, RATE_14_PCT));
        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 5, ORIGINATION_TS);

        uint64 timestamp = _schedule(terms, ORIGINATION_TS)[5] + uint64(3 days);
        (, uint256 interestPayment,,) = model.repayment(terms, state, timestamp);

        uint256 graceInterest = interestPayment - _ungracedWindowInterest(5);
        assertApproxEqRel(graceInterest, BALANCE_SCALED * 14 / 100 * 3 / 365, 0.001e18);
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche blended rate and split */
    /*------------------------------------------------------------------------*/

    function test__Repayment_MultiTranche_BlendedRateAndSplit() public view {
        /* 600k @ 10% + 400k @ 14% blends to 11.6% APR */
        ILoanRouterV2.TrancheSpec[] memory tranches = LoanFixtures.tranches2(
            LoanFixtures.tranche(users.lender1, 600_000 * 1e6, RATE_10_PCT),
            LoanFixtures.tranche(users.lender2, 400_000 * 1e6, RATE_14_PCT)
        );
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests
        ) = model.repayment(terms, state, _schedule(terms, ORIGINATION_TS)[0]);

        /* Blended APR = (600*10 + 400*14)/1000 = 11.6% over the 31-day first window */
        assertApproxEqRel(interestPayment, BALANCE_SCALED * 116 / 1000 * 31 / 365, 0.001e18);

        /* Per-tranche sums reconcile to the totals exactly */
        assertEq(tranchePrincipals[0] + tranchePrincipals[1], principalPayment);
        assertEq(trancheInterests[0] + trancheInterests[1], interestPayment);

        /* Principal splits by amount, interest splits by weighted rate */
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

        /* Odd balance stresses dust allocation */
        uint256 finalBalance = 42_000_042e18;
        LoanRouterV2.LoanState memory state = _state(finalBalance, lastIndex, ORIGINATION_TS);

        (uint256 principalPayment,, uint256[] memory tranchePrincipals,) =
            model.repayment(terms, state, deadlines[lastIndex]);

        assertEq(principalPayment, finalBalance, "Final payment sweeps the balance");
        assertEq(tranchePrincipals[0] + tranchePrincipals[1], finalBalance, "Tranche principals sum to the balance");
        assertEq(
            tranchePrincipals[1], Math.mulDiv(finalBalance, 400_000 * 1e6, 1_000_000 * 1e6), "Exact proportional share"
        );
    }

    function test__Repayment_ThreeTranches_DustToFirst() public view {
        ILoanRouterV2.TrancheSpec[] memory tranches = LoanFixtures.tranches3(
            LoanFixtures.tranche(users.lender1, 333_333 * 1e6, RATE_8_PCT),
            LoanFixtures.tranche(users.lender2, 333_333 * 1e6, RATE_10_PCT),
            LoanFixtures.tranche(users.lender3, 333_334 * 1e6, RATE_12_PCT)
        );
        ILoanRouterV2.LoanTermsV2 memory terms = LoanFixtures.makeTerms(USDC, tranches, _defaultOpts());
        terms.repaymentSpec.day = 1;
        terms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        terms.repaymentSpec.timezoneOffsetSeconds = 0;

        uint256 principal = LoanFixtures.sumPrincipal(tranches);

        (
            uint256 principalPayment,
            uint256 interestPayment,
            uint256[] memory tranchePrincipals,
            uint256[] memory trancheInterests
        ) = model.repayment(terms, _state(BALANCE_SCALED, 0, ORIGINATION_TS), _schedule(terms, ORIGINATION_TS)[0]);

        /* Sums reconcile exactly with no wei lost */
        assertEq(tranchePrincipals[0] + tranchePrincipals[1] + tranchePrincipals[2], principalPayment);
        assertEq(trancheInterests[0] + trancheInterests[1] + trancheInterests[2], interestPayment);

        /* Tranches 1 and 2 get the exact floored share; tranche 0 absorbs the dust */
        uint256 totalWeightedRate = uint256(RATE_8_PCT) * (333_333 * 1e6) + uint256(RATE_10_PCT) * (333_333 * 1e6)
            + uint256(RATE_12_PCT) * (333_334 * 1e6);
        assertEq(tranchePrincipals[1], Math.mulDiv(principalPayment, 333_333 * 1e6, principal));
        assertEq(
            trancheInterests[2], Math.mulDiv(interestPayment, uint256(RATE_12_PCT) * (333_334 * 1e6), totalWeightedRate)
        );
    }

    /*------------------------------------------------------------------------*/
    /* Test: edges and reverts */
    /*------------------------------------------------------------------------*/

    function test__Repayment_ZeroBalance_ZeroPrincipalAndInterest() public view {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        uint64[] memory deadlines = _schedule(terms, ORIGINATION_TS);
        uint16 lastIndex = uint16(deadlines.length) - 1;

        LoanRouterV2.LoanState memory state = _state(0, lastIndex, ORIGINATION_TS);

        (uint256 principalPayment, uint256 interestPayment,,) = model.repayment(terms, state, deadlines[lastIndex]);

        assertEq(principalPayment, 0);
        assertEq(interestPayment, 0);
    }

    function test__Repayment_RevertWhen_MalformedOptions() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());
        terms.interestRateSpec.options = "";

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        vm.expectRevert();
        model.repayment(terms, state, ORIGINATION_TS);
    }

    function test__Repayment_RevertWhen_RepaymentCountOutOfBounds() public {
        ILoanRouterV2.LoanTermsV2 memory terms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, CANONICAL_DEADLINES, ORIGINATION_TS);

        vm.expectRevert();
        model.repayment(terms, state, ORIGINATION_TS);
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

    function test__Repayment_USDT_MatchesUSDC() public view {
        /* USDC and USDT are both 6-decimal, so the model output must be identical */
        ILoanRouterV2.LoanTermsV2 memory usdcTerms = _terms(CANONICAL_DURATION_DAYS, _defaultOpts());

        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(users.lender1, TRANCHE_AMOUNT, RATE_10_PCT));
        ILoanRouterV2.LoanTermsV2 memory usdtTerms = LoanFixtures.makeTerms(USDT, tranches, _defaultOpts());
        usdtTerms.repaymentSpec.day = 1;
        usdtTerms.repaymentSpec.totalDurationDays = CANONICAL_DURATION_DAYS;
        usdtTerms.repaymentSpec.timezoneOffsetSeconds = 0;

        LoanRouterV2.LoanState memory state = _state(BALANCE_SCALED, 0, ORIGINATION_TS);

        (uint256 usdcPrincipal, uint256 usdcInterest,,) =
            model.repayment(usdcTerms, state, _schedule(usdcTerms, ORIGINATION_TS)[0]);
        (uint256 usdtPrincipal, uint256 usdtInterest,,) =
            model.repayment(usdtTerms, state, _schedule(usdtTerms, ORIGINATION_TS)[0]);

        assertEq(usdcPrincipal, usdtPrincipal);
        assertEq(usdcInterest, usdtInterest);
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
        vm.expectRevert(SimpleInterestRateModel.InvalidOptions.selector);
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

    function testFuzz_Deadlines_StrictlyMonotone(
        uint8 repaymentDayFuzz,
        uint32 epochOffsetFuzz,
        uint16 durationDaysFuzz,
        int16 tzHoursFuzz
    ) public view {
        uint8 repaymentDay = uint8(bound(uint256(repaymentDayFuzz), 1, 31));
        uint64 originationTimestamp = uint64(946_684_800 + bound(uint256(epochOffsetFuzz), 0, 1_262_304_000));
        uint16 durationDays = uint16(bound(uint256(durationDaysFuzz), 1, 1825));
        int32 timezoneOffsetSeconds = int32(bound(int256(tzHoursFuzz), -12, 14)) * 3600;

        ILoanRouterV2.LoanTermsV2 memory terms = _terms(durationDays, _defaultOpts());
        terms.repaymentSpec.day = repaymentDay;
        terms.repaymentSpec.timezoneOffsetSeconds = timezoneOffsetSeconds;

        uint64[] memory deadlines = _schedule(terms, originationTimestamp);

        for (uint256 i = 1; i < deadlines.length; i++) {
            assertGt(uint256(deadlines[i]), uint256(deadlines[i - 1]), "Deadlines must strictly increase");
        }
    }
}
