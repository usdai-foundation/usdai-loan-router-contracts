// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

contract LoanRouterV2RepayOverdueTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * Budget large enough to close the loan in one call
     */
    uint256 internal constant PAYOFF_BUDGET = 100_000_000 * 1e18;

    /**
     * Grace period long enough to keep the first unpaid deadline curable
     */
    uint64 internal constant GRACE_PERIOD_DURATION = 180 days;

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _simpleOptions(
        uint64 gracePeriodDuration,
        uint256 gracePeriodRate
    ) internal pure returns (bytes memory) {
        /* Encode the simple model options */
        return abi.encode(
            SimpleInterestRateModel.Options({
                principalAndInterestStubPayment: false,
                gracePeriodDuration: gracePeriodDuration,
                gracePeriodRate: gracePeriodRate
            })
        );
    }

    function _amortizedOptions(
        uint64 gracePeriodDuration,
        uint256 gracePeriodRate
    ) internal pure returns (bytes memory) {
        /* Encode the amortized model options */
        return abi.encode(
            AmortizedInterestRateModel.Options({
                principalAndInterestStubPayment: false,
                gracePeriodDuration: gracePeriodDuration,
                gracePeriodRate: gracePeriodRate
            })
        );
    }

    function _originateWithModel(
        address model,
        bytes memory options
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* Originate the canonical loan with the model under test */
        return _originateWithModel(_defaultConfig(), model, options);
    }

    function _originateWithModel(
        RouterFixture.LoanConfig memory config,
        address model,
        bytes memory options
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        /* Build the loan terms */
        loanTerms = buildLoanTerms(config);

        /* Swap in the interest rate model under test */
        loanTerms.interestRateSpec = ILoanRouterV2.InterestRateSpec({model: model, options: options});

        /* Warp to origination time */
        vm.warp(config.originationTimestamp);

        /* Stage the lender and collateral deposits */
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);

        /* Originate the loan */
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    function _repayWithBudget(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 budget
    ) internal {
        /* Fund the borrower with the whole budget */
        deal(loanTerms.currencyToken, users.borrower, budget);

        /* Approve the router for the whole budget */
        vm.startPrank(users.borrower);
        IERC20(loanTerms.currencyToken).approve(address(router), budget);

        /* Repay up to the budget */
        router.repay(loanTerms, budget);
        vm.stopPrank();
    }

    function _repayWindows(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 windowCount
    ) internal returns (uint256 interestQuoted) {
        /* Pay one full budget per window */
        for (uint256 i; i < windowCount; i++) {
            /* Quote the window and track the interest it prices */
            (, uint256 interestPayment,) = router.quote(loanTerms, uint64(block.timestamp));
            interestQuoted += interestPayment;

            /* Repay with a budget that covers the window and the balance */
            _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        }
    }

    function _warpPastFirstDeadline(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal returns (uint256 firstWindowPrincipal, uint256 firstWindowInterest) {
        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Warp five days past the first deadline, short of the second */
        vm.warp(schedule[0] + 5 days);

        /* Quote the overdue window */
        (firstWindowPrincipal, firstWindowInterest,) = router.quote(loanTerms, uint64(block.timestamp));
    }

    function _loanState(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint256 balance) {
        /* Read the loan state, dropping the origination timestamp */
        (status, repaymentCount,, balance) = router.loanState(router.loanTermsHash(loanTerms));
    }

    function _assertActive(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint16 expectedRepaymentCount
    ) internal view {
        /* Loan is still open with a balance outstanding */
        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint256 balance) = _loanState(loanTerms);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertEq(repaymentCount, expectedRepaymentCount);
        assertGt(balance, 0);
    }

    function _assertRepaid(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint16 expectedRepaymentCount
    ) internal view {
        /* Loan is closed with nothing outstanding */
        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint256 balance) = _loanState(loanTerms);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(repaymentCount, expectedRepaymentCount);
        assertEq(balance, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: an overdue loan cannot be prepaid into a payoff */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_PayoffCannotCloseLoan() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        (uint256 firstWindowPrincipal, uint256 firstWindowInterest) = _warpPastFirstDeadline(loanTerms);

        /* Read the lender balance before the payoff attempt */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Attempt to close the loan while it is overdue */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Only the overdue window was settled and the loan stays active */
        _assertActive(loanTerms, 1);

        /* Lender collected the overdue installment and nothing more */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, firstWindowPrincipal + firstWindowInterest);

        /* Collateral is still held by the router */
        assertEq(IERC721(loanTerms.collateralToken).ownerOf(loanTerms.collateralTokenIds[0]), address(router));
    }

    /*------------------------------------------------------------------------*/
    /* Test: curing the loan restores the prepayment */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_CureThenPrepay_ClosesLoan() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        (, uint256 firstWindowInterest) = _warpPastFirstDeadline(loanTerms);

        /* Read the lender balance before the cure */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Cure the overdue window */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        _assertActive(loanTerms, 1);

        /* Quote the window the loan is now current on */
        (, uint256 currentWindowInterest,) = router.quote(loanTerms, uint64(block.timestamp));

        /* Pay the current window and prepay the rest of the balance */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Loan is closed on the current window */
        _assertRepaid(loanTerms, 2);

        /* Lender collected the full principal plus both windows of interest */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, LOAN_AMOUNT_USDAI + firstWindowInterest + currentWindowInterest);
    }

    /*------------------------------------------------------------------------*/
    /* Test: several missed deadlines are cured one window at a time */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_ManyMissedDeadlines_CuredWindowByWindow() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Warp five days past the third deadline, leaving three missed deadlines */
        vm.warp(schedule[2] + 5 days);

        /* Read the lender balance before the catch-up */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Settle the three overdue windows, none of which can take a prepayment */
        uint256 overdueInterest = _repayWindows(loanTerms, 3);
        _assertActive(loanTerms, 3);

        /* Quote the window the loan is now current on */
        (, uint256 currentWindowInterest,) = router.quote(loanTerms, uint64(block.timestamp));

        /* Pay the current window and prepay the rest of the balance */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        _assertRepaid(loanTerms, 4);

        /* Lender collected the full principal plus every window of interest */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, LOAN_AMOUNT_USDAI + overdueInterest + currentWindowInterest);
    }

    /*------------------------------------------------------------------------*/
    /* Test: the amortized model holds back the same prepayment */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_PayoffCannotCloseLoan_Amortized() public {
        AmortizedInterestRateModel amortizedInterestRateModel = new AmortizedInterestRateModel();

        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithModel(
            address(amortizedInterestRateModel), _amortizedOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT)
        );

        (uint256 firstWindowPrincipal, uint256 firstWindowInterest) = _warpPastFirstDeadline(loanTerms);

        /* Read the lender balance before the payoff attempt */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Attempt to close the loan while it is overdue */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Only the overdue window was settled and the loan stays active */
        _assertActive(loanTerms, 1);

        /* Lender collected the overdue installment and nothing more */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, firstWindowPrincipal + firstWindowInterest);

        /* Paying the current window closes the loan */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        _assertRepaid(loanTerms, 2);
    }

    /*------------------------------------------------------------------------*/
    /* Test: the hold back does not depend on a grace period */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_PayoffCannotCloseLoan_NoGracePeriod() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateWithModel(address(irm), _simpleOptions(0, 0));

        _warpPastFirstDeadline(loanTerms);

        /* Attempt to close the loan while it is overdue */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Only the overdue window was settled and the loan stays active */
        _assertActive(loanTerms, 1);
    }

    /*------------------------------------------------------------------------*/
    /* Test: a loan that is current still closes in one call */
    /*------------------------------------------------------------------------*/

    function test__Repay_OnSchedule_PayoffClosesLoan() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Warp to the first deadline, which is not yet overdue */
        vm.warp(schedule[0]);

        /* Quote the current window */
        (, uint256 firstWindowInterest,) = router.quote(loanTerms, uint64(block.timestamp));

        /* Read the lender balance before the payoff */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Close the loan in one call */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        _assertRepaid(loanTerms, 1);

        /* Only the current window's interest was charged, the future windows are waived */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, LOAN_AMOUNT_USDAI + firstWindowInterest);
    }

    /*------------------------------------------------------------------------*/
    /* Test: an overdue final window still closes the loan */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_FinalWindow_ClosesLoan() public {
        /* Originate a short loan so the final window comes up quickly */
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.durationDays = 90;

        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(config, address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Settle every window but the last one, each at its own deadline */
        for (uint256 i; i + 1 < schedule.length; i++) {
            vm.warp(schedule[i]);
            (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) =
                router.quote(loanTerms, schedule[i]);
            _repayWithBudget(loanTerms, principalPayment + interestPayment + feePayment);
        }

        /* Warp five days past the final deadline */
        vm.warp(schedule[schedule.length - 1] + 5 days);

        /* The final installment sweeps the balance, so no prepayment is needed */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);
        _assertRepaid(loanTerms, uint16(schedule.length));

        /* Collateral came back to the borrower */
        assertEq(IERC721(loanTerms.collateralToken).ownerOf(loanTerms.collateralTokenIds[0]), users.borrower);
    }

    /*------------------------------------------------------------------------*/
    /* Test: an interest only overdue window cannot move the balance */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_InterestOnlyWindow_PayoffLeavesBalanceUntouched() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Warp five days past the second deadline, the shape of the reported live loan */
        vm.warp(schedule[1] + 5 days);

        /* The stub first window carries interest only */
        (uint256 firstWindowPrincipal, uint256 firstWindowInterest,) = router.quote(loanTerms, uint64(block.timestamp));
        assertEq(firstWindowPrincipal, 0);

        /* Read the lender balance before the payoff attempt */
        uint256 lenderBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI);

        /* Attempt to close the loan while it is overdue */
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Balance is untouched because the window owes no principal and takes no prepayment */
        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount, uint256 balance) = _loanState(loanTerms);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertEq(repaymentCount, 1);
        assertEq(balance, LOAN_AMOUNT_USDAI);

        /* Lender collected the overdue interest and nothing else */
        uint256 lenderGain = IERC20(loanTerms.currencyToken).balanceOf(STAKED_USDAI) - lenderBalanceBefore;
        assertEq(lenderGain, firstWindowInterest);
    }

    /*------------------------------------------------------------------------*/
    /* Test: an overdue final window still charges the exit fee */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_FinalWindow_ChargesExitFee() public {
        /* Originate a short loan carrying a fixed exit fee */
        uint256 exitFeeAmount = 100_000 * 1e18;
        RouterFixture.LoanConfig memory config = _defaultConfig();
        config.durationDays = 90;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            model: address(absoluteFeeModel),
            recipient: insuranceRecipient,
            kind: ILoanRouterV2.FeeKind.Exit,
            options: abi.encode(AbsoluteFeeModel.Options({amount: exitFeeAmount}))
        });

        ILoanRouterV2.LoanTermsV2 memory loanTerms =
            _originateWithModel(config, address(irm), _simpleOptions(GRACE_PERIOD_DURATION, RATE_8_5_PCT));

        /* Read the deadline schedule */
        uint64[] memory schedule = _schedule(loanTerms);

        /* Settle every window but the last one, each at its own deadline */
        for (uint256 i; i + 1 < schedule.length; i++) {
            vm.warp(schedule[i]);
            (uint256 principalPayment, uint256 interestPayment, uint256 feePayment) =
                router.quote(loanTerms, schedule[i]);
            _repayWithBudget(loanTerms, principalPayment + interestPayment + feePayment);
        }

        /* Read the fee recipient balance before the final payment */
        uint256 feeBalanceBefore = IERC20(loanTerms.currencyToken).balanceOf(insuranceRecipient);

        /* Warp five days past the final deadline and pay */
        vm.warp(schedule[schedule.length - 1] + 5 days);
        _repayWithBudget(loanTerms, PAYOFF_BUDGET);

        /* Loan closed and the exit fee was charged once */
        _assertRepaid(loanTerms, uint16(schedule.length));
        assertEq(IERC20(loanTerms.currencyToken).balanceOf(insuranceRecipient) - feeBalanceBefore, exitFeeAmount);
    }
}
