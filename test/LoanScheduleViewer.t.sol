// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RouterFixture} from "./helpers/RouterFixture.sol";
import {LoanFixtures} from "./helpers/LoanFixtures.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";
import {ILoanScheduleViewer} from "src/interfaces/ILoanScheduleViewer.sol";
import {LoanScheduleViewer} from "src/LoanScheduleViewer.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";

contract LoanScheduleViewerTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Per-second grace rate, roughly 20% APR */
    uint256 internal constant GRACE_RATE = 6341958396;

    /* Grace period */
    uint64 internal constant GRACE_DURATION = 180 days;

    /* Fixed exit fee */
    uint256 internal constant EXIT_FEE = 1234e18;

    /*------------------------------------------------------------------------*/
    /* State */
    /*------------------------------------------------------------------------*/

    LoanScheduleViewer internal viewer;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        super.setUp();
        viewer = new LoanScheduleViewer(address(router));
    }

    /*------------------------------------------------------------------------*/
    /* Helpers: options and specs */
    /*------------------------------------------------------------------------*/

    function _simpleOptions(
        bool stubPaysPrincipal,
        uint64 gracePeriodDuration,
        uint256 gracePeriodRate
    ) internal pure returns (bytes memory) {
        return abi.encode(
            SimpleInterestRateModel.Options({
                principalAndInterestStubPayment: stubPaysPrincipal,
                gracePeriodDuration: gracePeriodDuration,
                gracePeriodRate: gracePeriodRate
            })
        );
    }

    function _amortizedOptions(
        bool stubPaysPrincipal
    ) internal pure returns (bytes memory) {
        return abi.encode(
            AmortizedInterestRateModel.Options({
                principalAndInterestStubPayment: stubPaysPrincipal, gracePeriodDuration: 0, gracePeriodRate: 0
            })
        );
    }

    function _feeSpec(
        ILoanRouterV2.FeeKind kind,
        address model,
        bytes memory options
    ) internal view returns (ILoanRouterV2.FeeSpec memory) {
        return ILoanRouterV2.FeeSpec({kind: kind, recipient: users.feeRecipient, model: model, options: options});
    }

    function _ratioOptions(
        RatioFeeModel.Mode mode,
        uint256 rate
    ) internal pure returns (bytes memory) {
        return abi.encode(RatioFeeModel.Options({mode: mode, rate: rate}));
    }

    function _absoluteOptions(
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encode(AbsoluteFeeModel.Options({amount: amount}));
    }

    function _oneFee(
        ILoanRouterV2.FeeSpec memory spec
    ) internal pure returns (ILoanRouterV2.FeeSpec[] memory specs) {
        specs = new ILoanRouterV2.FeeSpec[](1);
        specs[0] = spec;
    }

    /*------------------------------------------------------------------------*/
    /* Helpers: origination */
    /*------------------------------------------------------------------------*/

    /* Originate from a config, optionally swapping in an interest rate model */
    function _originate(
        LoanConfig memory config,
        address model,
        bytes memory options
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        loanTerms = buildLoanTerms(config);

        /* Swap in the interest rate model under test */
        if (model != address(0)) {
            loanTerms.interestRateSpec = ILoanRouterV2.InterestRateSpec({model: model, options: options});
        }

        /* Warp to origination and originate */
        vm.warp(config.originationTimestamp);
        bool tranche0UsesEscrow = config.twoTranches ? config.mixedDepositTypes : config.useEscrowTimelock;
        prepareLenderDeposits(loanTerms, tranche0UsesEscrow);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, tranche0UsesEscrow), new bytes[](0));
    }

    function _originateSimple(
        LoanFixtures.WindowVariant variant,
        bool stubPaysPrincipal
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        LoanConfig memory config = _defaultConfig();
        config.variant = variant;
        return _originate(config, address(irm), _simpleOptions(stubPaysPrincipal, 0, 0));
    }

    function _originateAmortized(
        LoanFixtures.WindowVariant variant,
        bool stubPaysPrincipal
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        LoanConfig memory config = _defaultConfig();
        config.variant = variant;
        return _originate(config, address(new AmortizedInterestRateModel()), _amortizedOptions(stubPaysPrincipal));
    }

    function _originateWithGrace() internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        return _originate(_defaultConfig(), address(irm), _simpleOptions(false, GRACE_DURATION, GRACE_RATE));
    }

    function _originateWithFees(
        ILoanRouterV2.FeeSpec[] memory specs
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        LoanConfig memory config = _defaultConfig();
        config.feeSpecs = specs;
        return _originate(config, address(0), "");
    }

    function _originateWithExitFee() internal returns (ILoanRouterV2.LoanTermsV2 memory) {
        return _originateWithFees(
            _oneFee(_feeSpec(ILoanRouterV2.FeeKind.Exit, address(absoluteFeeModel), _absoluteOptions(EXIT_FEE)))
        );
    }

    /*------------------------------------------------------------------------*/
    /* Helpers: state and payments */
    /*------------------------------------------------------------------------*/

    function _state(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (ILoanRouterV2.LoanState memory loan) {
        (loan.status, loan.repaymentCount, loan.originationTimestamp, loan.balance) =
            router.loanState(router.loanTermsHash(loanTerms));
    }

    function _scaleFactor(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());
    }

    /* Unscale rounding up */
    function _unscale(
        uint256 scaledAmount,
        uint256 scaleFactor
    ) internal pure returns (uint256) {
        return (scaledAmount + scaleFactor - 1) / scaleFactor;
    }

    function _quote(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (uint256, uint256, uint256) {
        return router.quote(loanTerms, uint64(block.timestamp));
    }

    /* Pay the current quote plus an extra prepayment */
    function _pay(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 extra
    ) internal {
        (uint256 principal, uint256 interest, uint256 fee) = _quote(loanTerms);
        uint256 total = principal + interest + fee + extra;
        if (total == 0) return;

        deal(loanTerms.currencyToken, users.borrower, total + 1e20);
        vm.startPrank(users.borrower);
        IERC20(loanTerms.currencyToken).approve(address(router), total);
        router.repay(loanTerms, total);
        vm.stopPrank();
    }

    /* Repay the first count windows on time */
    function _repayWindows(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 count
    ) internal {
        uint64[] memory deadlines = router.deadlines(loanTerms);
        for (uint256 i; i < count; i++) {
            vm.warp(deadlines[i]);
            _pay(loanTerms, 0);
        }
    }

    /*------------------------------------------------------------------------*/
    /* Helpers: assertions */
    /*------------------------------------------------------------------------*/

    /* Assert a row equals the live router quote */
    function _assertRowMatchesQuote(
        ILoanScheduleViewer.RepaymentWindow memory row,
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view {
        uint256 scaleFactor = _scaleFactor(loanTerms);
        (uint256 principal, uint256 interest, uint256 fee) = _quote(loanTerms);
        assertEq(_unscale(row.scaledPrincipal, scaleFactor), principal, "principal");
        assertEq(_unscale(row.scaledInterest, scaleFactor), interest, "interest");
        assertEq(_unscale(row.scaledFee, scaleFactor), fee, "fee");
    }

    /* Assert structural invariants of a schedule against the current loan state */
    function _assertInvariants(
        ILoanScheduleViewer.RepaymentSchedule memory schedule,
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view {
        ILoanRouterV2.LoanState memory loan = _state(loanTerms);
        uint64[] memory deadlines = router.deadlines(loanTerms);
        (bool hasStub,) = ScheduleLogic.deadlines(loanTerms, loan.originationTimestamp);

        assertEq(schedule.hasStub, hasStub, "hasStub");
        assertEq(schedule.repayments.length, deadlines.length - loan.repaymentCount, "row count");

        uint256 sumPrincipal;
        uint256 sumInterest;
        uint256 sumFees;
        uint256 previousRemaining = loan.balance;
        for (uint256 i; i < schedule.repayments.length; i++) {
            ILoanScheduleViewer.RepaymentWindow memory row = schedule.repayments[i];
            assertEq(row.deadline, deadlines[loan.repaymentCount + i], "deadline");
            assertEq(row.scaledTotal, row.scaledPrincipal + row.scaledInterest + row.scaledFee, "row total");
            assertEq(row.scaledRemainingBalance, previousRemaining - row.scaledPrincipal, "remaining");
            assertLe(row.scaledRemainingBalance, previousRemaining, "non-increasing");
            previousRemaining = row.scaledRemainingBalance;
            sumPrincipal += row.scaledPrincipal;
            sumInterest += row.scaledInterest;
            sumFees += row.scaledFee;
        }

        assertEq(previousRemaining, 0, "final remaining");
        assertEq(sumPrincipal, loan.balance, "principal sum");
        assertEq(schedule.scaledTotalPrincipal, sumPrincipal, "total principal");
        assertEq(schedule.scaledTotalInterest, sumInterest, "total interest");
        assertEq(schedule.scaledTotalFees, sumFees, "total fees");
    }

    /* Compute the schedule once, then walk every remaining window against the router */
    function _walk(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal {
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        _assertInvariants(schedule, loanTerms);

        for (uint256 i; i < schedule.repayments.length; i++) {
            vm.warp(schedule.repayments[i].deadline);
            _assertRowMatchesQuote(schedule.repayments[i], loanTerms);
            _pay(loanTerms, 0);
        }

        assertEq(uint8(_state(loanTerms).status), uint8(ILoanRouterV2.LoanStatus.Repaid), "repaid");
    }

    function _syntheticState(
        ILoanRouterV2.LoanStatus status,
        uint16 repaymentCount,
        uint64 originationTimestamp,
        uint256 balance
    ) internal pure returns (ILoanRouterV2.LoanState memory) {
        return ILoanRouterV2.LoanState({
            status: status, repaymentCount: repaymentCount, originationTimestamp: originationTimestamp, balance: balance
        });
    }

    /*------------------------------------------------------------------------*/
    /* Test: constructor */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Constructor_SetsLoanRouter() public view {
        assertEq(address(viewer.loanRouter()), address(router));
    }

    /*------------------------------------------------------------------------*/
    /* Test: walk the schedule against the router */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Walk_Simple_Stub() public {
        _walk(_originateSimple(LoanFixtures.WindowVariant.Upper, false));
    }

    function test__Viewer_Walk_Simple_NoStub() public {
        _walk(_originateSimple(LoanFixtures.WindowVariant.Lower, false));
    }

    function test__Viewer_Walk_Simple_StubPaysPrincipal() public {
        _walk(_originateSimple(LoanFixtures.WindowVariant.Upper, true));
    }

    function test__Viewer_Walk_Amortized_Stub() public {
        _walk(_originateAmortized(LoanFixtures.WindowVariant.Upper, false));
    }

    function test__Viewer_Walk_Amortized_NoStub() public {
        _walk(_originateAmortized(LoanFixtures.WindowVariant.Lower, false));
    }

    function test__Viewer_Walk_Amortized_StubPaysPrincipal() public {
        _walk(_originateAmortized(LoanFixtures.WindowVariant.Upper, true));
    }

    function test__Viewer_Walk_TwoTranches() public {
        LoanConfig memory config = _defaultConfig();
        config.twoTranches = true;
        _walk(_originate(config, address(0), ""));
    }

    function test__Viewer_Walk_SixDecimalCurrency() public {
        LoanConfig memory config = _defaultConfig();
        config.currencyToken = USDC;
        config.useEscrowTimelock = false;
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originate(config, address(0), "");

        /* Projection at origination is internally consistent */
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        _assertInvariants(schedule, loanTerms);

        /* Quotes round up to 6 decimals and the router treats the rounding excess as a prepayment, so the
         * on-chain balance drifts below a one-shot projection; recompute each window and compare its first row */
        for (uint256 i; i < schedule.repayments.length; i++) {
            vm.warp(schedule.repayments[i].deadline);
            _assertRowMatchesQuote(viewer.paymentSchedule(loanTerms).repayments[0], loanTerms);
            _pay(loanTerms, 0);
        }

        assertEq(uint8(_state(loanTerms).status), uint8(ILoanRouterV2.LoanStatus.Repaid), "repaid");
    }

    function test__Viewer_Walk_AfterPartialPrepayment() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);

        /* Prepay $10M on top of the first window */
        vm.warp(router.deadlines(loanTerms)[0]);
        _pay(loanTerms, 10_000_000e18);

        /* Rows re-amortize against the reduced balance and still match the router */
        _walk(loanTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Test: hasStub */
    /*------------------------------------------------------------------------*/

    function test__Viewer_HasStub_TrueWhenOriginationOffAnchor() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        assertTrue(viewer.paymentSchedule(loanTerms).hasStub);
    }

    function test__Viewer_HasStub_FalseWhenOriginationOnAnchor() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Lower, false);
        assertFalse(viewer.paymentSchedule(loanTerms).hasStub);
    }

    /*------------------------------------------------------------------------*/
    /* Test: fees */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Fees_RatioBalanceMode_ShrinksWithBalance() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFees(
            _oneFee(
                _feeSpec(
                    ILoanRouterV2.FeeKind.Repayment,
                    address(ratioFeeModel),
                    _ratioOptions(RatioFeeModel.Mode.Balance, LoanFixtures.INSURANCE_ANNUAL_RATE / 12)
                )
            )
        );
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        /* Fee is charged on the pre-payment balance of each row */
        uint256 balance = _state(loanTerms).balance;
        for (uint256 i; i < schedule.repayments.length; i++) {
            uint256 expected = ratioFeeModel.fee(
                loanTerms,
                _syntheticState(ILoanRouterV2.LoanStatus.Active, uint16(i), 0, balance),
                loanTerms.feeSpecs[0].options,
                0
            );
            assertEq(schedule.repayments[i].scaledFee, expected, "fee");
            if (i > 0 && schedule.repayments[i - 1].scaledPrincipal > 0) {
                assertLt(schedule.repayments[i].scaledFee, schedule.repayments[i - 1].scaledFee, "shrinks");
            }
            balance = schedule.repayments[i].scaledRemainingBalance;
        }

        _walk(loanTerms);
    }

    function test__Viewer_Fees_RatioAmountMode_ConstantOnPrincipal() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFees(
            _oneFee(
                _feeSpec(
                    ILoanRouterV2.FeeKind.Repayment,
                    address(ratioFeeModel),
                    _ratioOptions(RatioFeeModel.Mode.Amount, 0.001e18)
                )
            )
        );
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        /* Fee is a fixed ratio of the original scaled principal on every row */
        uint256 expected = (_state(loanTerms).balance * 0.001e18 + 1e18 - 1) / 1e18;
        for (uint256 i; i < schedule.repayments.length; i++) {
            assertEq(schedule.repayments[i].scaledFee, expected, "fee");
        }

        _walk(loanTerms);
    }

    function test__Viewer_Fees_Exit_OnlyOnFinalRow() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        uint256 last = schedule.repayments.length - 1;
        for (uint256 i; i < last; i++) {
            assertEq(schedule.repayments[i].scaledFee, 0, "no fee before exit");
        }
        assertEq(schedule.repayments[last].scaledFee, EXIT_FEE, "exit fee");
        assertEq(schedule.scaledTotalFees, EXIT_FEE, "total fees");

        _walk(loanTerms);
    }

    function test__Viewer_Fees_OtherKinds_Ignored() public {
        ILoanRouterV2.FeeSpec[] memory specs = new ILoanRouterV2.FeeSpec[](3);
        specs[0] = _feeSpec(ILoanRouterV2.FeeKind.Origination, address(absoluteFeeModel), _absoluteOptions(1e18));
        specs[1] = _feeSpec(ILoanRouterV2.FeeKind.Liquidation, address(absoluteFeeModel), _absoluteOptions(1e18));
        specs[2] = _feeSpec(ILoanRouterV2.FeeKind.Refinance, address(absoluteFeeModel), _absoluteOptions(1e18));
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFees(specs);

        assertEq(viewer.paymentSchedule(loanTerms).scaledTotalFees, 0);
    }

    function test__Viewer_Fees_MultipleSpecsOfSameKind_Sum() public {
        ILoanRouterV2.FeeSpec[] memory specs = new ILoanRouterV2.FeeSpec[](2);
        specs[0] = _feeSpec(ILoanRouterV2.FeeKind.Repayment, address(absoluteFeeModel), _absoluteOptions(100e18));
        specs[1] = _feeSpec(ILoanRouterV2.FeeKind.Repayment, address(absoluteFeeModel), _absoluteOptions(25e18));
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithFees(specs);

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        for (uint256 i; i < schedule.repayments.length; i++) {
            assertEq(schedule.repayments[i].scaledFee, 125e18, "fee");
        }

        _walk(loanTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Test: loan state handling */
    /*------------------------------------------------------------------------*/

    function test__Viewer_State_Uninitialized_ReturnsEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        assertEq(schedule.repayments.length, 0);
        assertEq(schedule.scaledTotalPrincipal, 0);
        assertEq(schedule.scaledTotalFees, 0);
    }

    function test__Viewer_State_RepaidByWalking_ReturnsEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();
        _walk(loanTerms);

        assertEq(viewer.paymentSchedule(loanTerms).repayments.length, 0);
    }

    function test__Viewer_State_RepaidByFullPrepayment_ReturnsEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();

        /* Pay off the whole balance in the first window */
        vm.warp(router.deadlines(loanTerms)[0]);
        _pay(loanTerms, 200_000_000e18);
        assertEq(uint8(_state(loanTerms).status), uint8(ILoanRouterV2.LoanStatus.Repaid));

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        assertEq(schedule.repayments.length, 0);
        assertEq(schedule.scaledTotalFees, 0);
    }

    function test__Viewer_State_NonActiveExplicitStates_ReturnEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        ILoanRouterV2.LoanState memory loan = _state(loanTerms);

        ILoanRouterV2.LoanStatus[4] memory statuses = [
            ILoanRouterV2.LoanStatus.Repaid,
            ILoanRouterV2.LoanStatus.Breached,
            ILoanRouterV2.LoanStatus.Liquidated,
            ILoanRouterV2.LoanStatus.CollateralLiquidated
        ];
        for (uint256 i; i < statuses.length; i++) {
            loan.status = statuses[i];
            assertEq(viewer.paymentSchedule(loanTerms, loan, 0).repayments.length, 0);
        }
    }

    function test__Viewer_State_AfterRepayments_ShrinksAndAdvances() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        uint64[] memory deadlines = router.deadlines(loanTerms);

        _repayWindows(loanTerms, 3);

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        assertEq(schedule.repayments.length, deadlines.length - 3);
        assertEq(schedule.repayments[0].deadline, deadlines[3]);
        _assertInvariants(schedule, loanTerms);
    }

    function test__Viewer_State_PartialPrepayment_OnlyFinalRowReachesZero() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();

        vm.warp(router.deadlines(loanTerms)[0]);
        _pay(loanTerms, 20_000_000e18);

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        _assertInvariants(schedule, loanTerms);

        uint256 last = schedule.repayments.length - 1;
        for (uint256 i; i < last; i++) {
            assertGt(schedule.repayments[i].scaledRemainingBalance, 0, "balance remains");
            assertEq(schedule.repayments[i].scaledFee, 0, "no exit fee");
        }
        assertEq(schedule.repayments[last].scaledFee, EXIT_FEE, "exit fee on final row");
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace interest */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Grace_OverdueFirstRow_MatchesQuote() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        uint64[] memory deadlines = router.deadlines(loanTerms);

        vm.warp(deadlines[0] + 3 days);
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        /* Overdue row carries grace interest and matches the live quote */
        _assertRowMatchesQuote(schedule.repayments[0], loanTerms);
        assertEq(schedule.repayments[0].deadline, deadlines[0], "deadline unchanged");

        /* Future rows are unaffected */
        ILoanScheduleViewer.RepaymentSchedule memory onTime = viewer.paymentSchedule(loanTerms, _state(loanTerms), 0);
        assertGt(schedule.repayments[0].scaledInterest, onTime.repayments[0].scaledInterest, "grace added");
        assertEq(schedule.repayments[1].scaledInterest, onTime.repayments[1].scaledInterest, "row 1 unchanged");
    }

    function test__Viewer_Grace_PastGraceDuration_CappedLikeQuote() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();

        vm.warp(router.deadlines(loanTerms)[0] + GRACE_DURATION + 30 days);
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        _assertRowMatchesQuote(schedule.repayments[0], loanTerms);
    }

    function test__Viewer_Grace_TwoWindowsOverdue_BothRowsMatchRouter() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        uint64[] memory deadlines = router.deadlines(loanTerms);

        vm.warp(deadlines[1] + 3 days);
        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);

        /* Row 0 matches the live quote, cure it, then row 1 matches the next live quote */
        _assertRowMatchesQuote(schedule.repayments[0], loanTerms);
        _pay(loanTerms, 0);
        _assertRowMatchesQuote(schedule.repayments[1], loanTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Test: explicit state overload */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Explicit_PreOriginationQuote_MatchesOnChain() public {
        LoanConfig memory config = _defaultConfig();
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);
        vm.warp(config.originationTimestamp);

        /* Project from a synthetic state before the loan exists */
        uint256 scaledPrincipal = loanTerms.trancheSpecs[0].amount * _scaleFactor(loanTerms);
        ILoanScheduleViewer.RepaymentSchedule memory projected = viewer.paymentSchedule(
            loanTerms, _syntheticState(ILoanRouterV2.LoanStatus.Active, 0, uint64(block.timestamp), scaledPrincipal), 0
        );

        /* Originate the same terms and compare */
        prepareLenderDeposits(loanTerms, config.useEscrowTimelock);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, config.useEscrowTimelock), new bytes[](0));
        ILoanScheduleViewer.RepaymentSchedule memory actual = viewer.paymentSchedule(loanTerms);

        assertEq(keccak256(abi.encode(projected)), keccak256(abi.encode(actual)));
    }

    function test__Viewer_Explicit_Timestamp_AddsGraceWhenPastDeadline() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        ILoanRouterV2.LoanState memory loan = _state(loanTerms);
        uint64 deadline = router.deadlines(loanTerms)[0];

        ILoanScheduleViewer.RepaymentSchedule memory onTime = viewer.paymentSchedule(loanTerms, loan, 0);
        ILoanScheduleViewer.RepaymentSchedule memory atDeadline = viewer.paymentSchedule(loanTerms, loan, deadline);
        ILoanScheduleViewer.RepaymentSchedule memory overdue =
            viewer.paymentSchedule(loanTerms, loan, deadline + 3 days);

        assertEq(onTime.repayments[0].scaledInterest, atDeadline.repayments[0].scaledInterest, "at deadline");
        assertGt(overdue.repayments[0].scaledInterest, onTime.repayments[0].scaledInterest, "overdue");
    }

    function test__Viewer_Explicit_BlockTimestamp_MatchesOnChainOverload() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        vm.warp(router.deadlines(loanTerms)[0] + 3 days);

        ILoanScheduleViewer.RepaymentSchedule memory onChain = viewer.paymentSchedule(loanTerms);
        ILoanScheduleViewer.RepaymentSchedule memory explicit_ =
            viewer.paymentSchedule(loanTerms, _state(loanTerms), uint64(block.timestamp));

        assertEq(keccak256(abi.encode(onChain)), keccak256(abi.encode(explicit_)));
    }

    function test__Viewer_Explicit_RepaymentCountPastCalendar_Reverts() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        ILoanRouterV2.LoanState memory loan = _state(loanTerms);
        loan.repaymentCount = uint16(router.deadlines(loanTerms).length + 1);

        vm.expectRevert(ILoanScheduleViewer.InvalidRepaymentCount.selector);
        viewer.paymentSchedule(loanTerms, loan, 0);
    }

    function test__Viewer_Explicit_RepaymentCountAtCalendarEnd_ReturnsEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        ILoanRouterV2.LoanState memory loan = _state(loanTerms);
        loan.repaymentCount = uint16(router.deadlines(loanTerms).length);

        assertEq(viewer.paymentSchedule(loanTerms, loan, 0).repayments.length, 0);
    }

    function test__Viewer_Explicit_EmptyTranches_ReturnsEmpty() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(_defaultConfig());
        loanTerms.trancheSpecs = new ILoanRouterV2.TrancheSpec[](0);

        ILoanRouterV2.LoanState memory loan =
            _syntheticState(ILoanRouterV2.LoanStatus.Active, 0, uint64(block.timestamp), 1e18);
        assertEq(viewer.paymentSchedule(loanTerms, loan, 0).repayments.length, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: encoded overloads */
    /*------------------------------------------------------------------------*/

    function test__Viewer_Encoded_RepaymentSchedule_MatchesStruct() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();

        ILoanScheduleViewer.RepaymentSchedule memory fromStruct = viewer.paymentSchedule(loanTerms);
        ILoanScheduleViewer.RepaymentSchedule memory fromBytes = viewer.paymentSchedule(abi.encode(loanTerms));

        assertEq(keccak256(abi.encode(fromStruct)), keccak256(abi.encode(fromBytes)));
    }

    function test__Viewer_Encoded_Quote_MatchesRouter() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        uint64 deadline = router.deadlines(loanTerms)[0];
        vm.warp(deadline + 3 days);

        (uint256 p, uint256 i, uint256 f) = router.quote(loanTerms, uint64(block.timestamp));
        (uint256 vp, uint256 vi, uint256 vf) = viewer.quote(abi.encode(loanTerms));
        assertEq(vp, p);
        assertEq(vi, i);
        assertEq(vf, f);

        (p, i, f) = router.quote(loanTerms, deadline);
        (vp, vi, vf) = viewer.quote(abi.encode(loanTerms), deadline);
        assertEq(vp, p);
        assertEq(vi, i);
        assertEq(vf, f);
    }

    function test__Viewer_Encoded_MalformedBytes_Reverts() public {
        vm.expectRevert();
        viewer.paymentSchedule(hex"deadbeef");
    }

    /*------------------------------------------------------------------------*/
    /* Test: fuzz */
    /*------------------------------------------------------------------------*/

    function testFuzz__Viewer_Prepayment_ScheduleStillMatchesRouter(
        uint256 prepayment
    ) public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateSimple(LoanFixtures.WindowVariant.Upper, false);
        vm.warp(router.deadlines(loanTerms)[0]);

        /* Prepay anything that leaves the loan active with a meaningful balance */
        (uint256 principal,,) = _quote(loanTerms);
        uint256 balance = _state(loanTerms).balance;
        prepayment = bound(prepayment, 1e18, balance - principal - 1_000_000e18);
        _pay(loanTerms, prepayment);

        _walk(loanTerms);
    }

    function testFuzz__Viewer_Timestamp_FirstRowMatchesQuote(
        uint64 offset
    ) public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithGrace();
        uint64 deadline = router.deadlines(loanTerms)[0];

        /* Any time from origination through the end of the grace period */
        offset = uint64(bound(offset, 0, deadline - block.timestamp + GRACE_DURATION));
        vm.warp(block.timestamp + offset);

        ILoanScheduleViewer.RepaymentSchedule memory schedule = viewer.paymentSchedule(loanTerms);
        _assertRowMatchesQuote(schedule.repayments[0], loanTerms);
    }

    /*------------------------------------------------------------------------*/
    /* Test: proxy */
    /*------------------------------------------------------------------------*/

    function test__Viewer_BehindProxy_MatchesImplementation() public {
        /* Deploy behind a transparent proxy */
        LoanScheduleViewer proxied = LoanScheduleViewer(
            address(
                new TransparentUpgradeableProxy(
                    address(viewer), users.deployer, abi.encodeWithSelector(LoanScheduleViewer.initialize.selector)
                )
            )
        );
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithExitFee();

        assertEq(address(proxied.loanRouter()), address(router));
        assertEq(
            keccak256(abi.encode(proxied.paymentSchedule(loanTerms))),
            keccak256(abi.encode(viewer.paymentSchedule(loanTerms)))
        );
    }
}
