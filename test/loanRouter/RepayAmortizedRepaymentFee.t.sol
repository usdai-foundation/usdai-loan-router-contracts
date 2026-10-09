// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ProratedRatioFeeModel} from "src/fees/ProratedRatioFeeModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";

contract LoanRouterV2RepayAmortizedRepaymentFeeTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Repayment fee of 0.2% of the outstanding balance for an average month */
    uint256 internal constant FEE_RATE = 0.002e18;

    /* 30.41666667 days, which is 365 / 12 days in seconds */
    uint256 internal constant REFERENCE_WINDOW_DURATION = 2_628_000;

    /*------------------------------------------------------------------------*/
    /* Fixtures */
    /*------------------------------------------------------------------------*/

    AmortizedInterestRateModel internal amortizedInterestRateModel;

    ProratedRatioFeeModel internal proratedRatioFeeModel;

    function setUp() public override {
        super.setUp();

        amortizedInterestRateModel = new AmortizedInterestRateModel();

        proratedRatioFeeModel = new ProratedRatioFeeModel();
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    /* Default loan carrying a single prorated Repayment fee spec at the given rate */
    function _proratedFeeConfig(
        uint256 rate
    ) internal view returns (LoanConfig memory config) {
        config = _defaultConfig();

        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Repayment,
            recipient: address(0),
            model: address(proratedRatioFeeModel),
            options: abi.encode(ProratedRatioFeeModel.Options({windowRate: rate}))
        });
    }

    /* Originate a loan from the given config against the amortized interest rate model */
    function _originateAmortized(
        LoanConfig memory config,
        bool principalAndInterestStubPayment
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        loanTerms = buildLoanTerms(config);

        /* The options layout matches the simple model, so only the model address and stub flag change */
        loanTerms.interestRateSpec.model = address(amortizedInterestRateModel);
        loanTerms.interestRateSpec.options = abi.encode(
            AmortizedInterestRateModel.Options({
                principalAndInterestStubPayment: principalAndInterestStubPayment,
                gracePeriodDuration: 0,
                gracePeriodRate: 0
            })
        );

        vm.warp(_recipeTimestamp(config.variant));
        prepareLenderDeposits(loanTerms, true);
        prepareCollateralDeposit(loanTerms);
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    /* Originate a default loan carrying a prorated Repayment fee against the amortized model */
    function _originateProrated() internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        return _originateAmortized(_proratedFeeConfig(FEE_RATE), false);
    }

    /* Fund the borrower and repay the given scaled total */
    function _fundAndRepay(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 total
    ) internal {
        /* Nothing to do when there is no payment due */
        if (total == 0) return;

        /* Fund the borrower with headroom */
        deal(loanTerms.currencyToken, users.borrower, total + 1e20);

        /* Approve and repay as the borrower */
        vm.startPrank(users.borrower);
        IERC20(loanTerms.currencyToken).approve(address(router), total);
        router.repay(loanTerms, total);
        vm.stopPrank();
    }

    /* Walk the schedule, repaying each quote, and check the total stays level after the interest only stub */
    function _assertRepaysLevel(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 tolerance
    ) internal {
        uint64[] memory schedule = _schedule(loanTerms);
        uint256 levelTotal;

        for (uint256 i = 0; i < schedule.length; i++) {
            vm.warp(schedule[i]);

            (uint256 principal, uint256 interest, uint256 fee) = router.quote(loanTerms, schedule[i]);
            uint256 total = principal + interest + fee;

            /* The stub window pays interest and fee only, so leveling starts after it */
            if (i == 0 && principal == 0) {
                _fundAndRepay(loanTerms, total);
                continue;
            }

            if (levelTotal == 0) {
                levelTotal = total;
            } else {
                /* Principal plus interest plus fee stays level across every remaining window */
                assertApproxEqRel(total, levelTotal, tolerance, "Total with fee must be level across cycles");
            }

            _fundAndRepay(loanTerms, total);
        }

        /* The level schedule amortizes the loan to zero */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid), "Loan must be repaid");
        assertEq(balance, 0, "Balance must reach zero");
    }

    /* Fee owed on a window exactly one average month long */
    function _flatFee(
        uint256 balance
    ) internal pure returns (uint256) {
        return balance * FEE_RATE / 1e18;
    }

    /* Fee owed on a window of the given length, prorated against an average month */
    function _proratedFee(
        uint256 balance,
        uint256 windowDuration
    ) internal pure returns (uint256) {
        return _flatFee(balance) * windowDuration / REFERENCE_WINDOW_DURATION;
    }

    /* Read just the interest leg of a quote */
    function _quoteInterest(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint64 timestamp
    ) internal view returns (uint256) {
        (, uint256 interest,) = router.quote(loanTerms, timestamp);
        return interest;
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee is collected to the recipient on every cycle */
    /*------------------------------------------------------------------------*/

    function test__Repay_RepaymentFee_CollectsToRecipientEachCycle() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateProrated();

        uint64[] memory schedule = _schedule(loanTerms);
        for (uint256 i = 0; i < schedule.length; i++) {
            /* Warp to the cycle deadline */
            vm.warp(schedule[i]);

            /* Quote the amounts due */
            (uint256 principal, uint256 interest, uint256 fee) = router.quote(loanTerms, schedule[i]);

            /* Record the recipient balance before repaying */
            uint256 recipientBefore = IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient);

            /* Repay the full quote */
            _fundAndRepay(loanTerms, principal + interest + fee);

            /* The fee reaches the recipient */
            assertEq(
                IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient) - recipientBefore,
                fee,
                "Recipient must receive the quoted fee each cycle"
            );

            /* The fee is non-zero while a balance remains */
            assertGt(fee, 0, "Fee must be charged on each cycle");
        }

        /* The loan is fully repaid */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid), "Loan must be repaid");
        assertEq(balance, 0, "Balance must reach zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: quoted fee scales with the configured rate */
    /*------------------------------------------------------------------------*/

    function test__Quote_RepaymentFee_ScalesWithRate() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms1 = _originateAmortized(_proratedFeeConfig(FEE_RATE), false);
        ILoanRouterV2.LoanTermsV2 memory loanTerms2 = _originateAmortized(_proratedFeeConfig(FEE_RATE * 2), false);

        uint64[] memory schedule = _schedule(loanTerms1);
        vm.warp(schedule[0]);

        (,, uint256 fee1) = router.quote(loanTerms1, schedule[0]);
        (,, uint256 fee2) = router.quote(loanTerms2, schedule[0]);

        /* Doubling the fee rate doubles the fee at the same balance */
        assertApproxEqRel(fee2, fee1 * 2, 0.0001e18, "Fee must scale linearly with the rate");
    }

    /*------------------------------------------------------------------------*/
    /* Test: the amortized model folds the fee into a level payment */
    /*------------------------------------------------------------------------*/

    function test__Repay_ProratedFee_TotalIsLevel() public {
        _assertRepaysLevel(_originateProrated(), 0.0001e18);
    }

    function test__Repay_BalanceRatioFee_TotalIsNearlyLevel() public {
        /* A ratio fee on the balance charges the same share every window whatever its length, so the level
         * total drifts by the month length difference and stays within half a percent */
        LoanConfig memory config = _defaultConfig();
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        config.feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Repayment,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Balance, rate: FEE_RATE}))
        });

        _assertRepaysLevel(_originateAmortized(config, false), 0.005e18);
    }

    function test__Repay_ProratedFee_PrincipalAndInterestStub_StillAmortizes() public {
        /* With a principal and interest stub the partial window does reach the level payment, so the fee rate
         * backed out of that short window has to price every window after it */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateAmortized(_proratedFeeConfig(FEE_RATE), true);

        uint64[] memory schedule = _schedule(loanTerms);

        /* The partial window now pays principal too */
        vm.warp(schedule[0]);
        (uint256 stubPrincipal,,) = router.quote(loanTerms, schedule[0]);
        assertGt(stubPrincipal, 0, "Principal and interest stub must pay principal");

        for (uint256 i = 0; i < schedule.length; i++) {
            vm.warp(schedule[i]);
            (uint256 principal, uint256 interest, uint256 fee) = router.quote(loanTerms, schedule[i]);
            _fundAndRepay(loanTerms, principal + interest + fee);
        }

        /* The loan still amortizes to zero */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(router.loanTermsHash(loanTerms));
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid), "Loan must be repaid");
        assertEq(balance, 0, "Balance must reach zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: every window is prorated by its own length */
    /*------------------------------------------------------------------------*/

    function test__Repay_ProratedFee_ProratesEveryWindow() public {
        LoanConfig memory config = _proratedFeeConfig(FEE_RATE);
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateAmortized(config, false);
        uint64 originationTs = _recipeTimestamp(config.variant);

        uint64[] memory schedule = _schedule(loanTerms);

        /* The default recipe originates off the anchor, so the first window is partial */
        uint256 stubDuration = schedule[0] - originationTs;
        assertGt(stubDuration, 0, "First window must be partial");
        assertLt(stubDuration, REFERENCE_WINDOW_DURATION, "Partial window must be shorter than an average month");

        /* Quote the partial first window */
        vm.warp(schedule[0]);
        (uint256 stubPrincipal,, uint256 stubFee) = router.quote(loanTerms, schedule[0]);
        assertEq(stubPrincipal, 0, "Partial window is interest only");

        /* The partial window owes the fee scaled by its length over an average month */
        (,,, uint256 balance) = router.loanState(router.loanTermsHash(loanTerms));
        assertApproxEqAbs(
            stubFee, _proratedFee(balance, stubDuration), 2, "Partial window fee must be prorated over 30.41666667 days"
        );
        assertLt(stubFee, _flatFee(balance), "Partial window must owe less than an average month");

        /* Repay the partial window */
        _fundAndRepay(loanTerms, stubPrincipal + _quoteInterest(loanTerms, schedule[0]) + stubFee);

        /* The second window is February, which is shorter than an average month */
        uint256 februaryDuration = schedule[1] - schedule[0];
        assertLt(februaryDuration, REFERENCE_WINDOW_DURATION, "Second window must be shorter than an average month");

        vm.warp(schedule[1]);
        (,, uint256 februaryFee) = router.quote(loanTerms, schedule[1]);
        (,,, uint256 februaryBalance) = router.loanState(router.loanTermsHash(loanTerms));
        assertApproxEqAbs(
            februaryFee,
            _proratedFee(februaryBalance, februaryDuration),
            2,
            "A full window must be prorated by its own length"
        );
        assertLt(februaryFee, _flatFee(februaryBalance), "A short month must owe less than an average month");

        /* The third window is March, which is longer than an average month */
        _repayAt(loanTerms, schedule[1]);

        uint256 marchDuration = schedule[2] - schedule[1];
        assertGt(marchDuration, REFERENCE_WINDOW_DURATION, "Third window must be longer than an average month");

        vm.warp(schedule[2]);
        (,, uint256 marchFee) = router.quote(loanTerms, schedule[2]);
        (,,, uint256 marchBalance) = router.loanState(router.loanTermsHash(loanTerms));
        assertApproxEqAbs(
            marchFee, _proratedFee(marchBalance, marchDuration), 2, "A full window must be prorated by its own length"
        );
        assertGt(marchFee, _flatFee(marchBalance), "A long month must owe more than an average month");
    }

    /*------------------------------------------------------------------------*/
    /* Test: prepayment recasts a fee bearing loan without shortening it */
    /*------------------------------------------------------------------------*/

    /* Originate a prorated fee loan and clear the first window so it sits ahead of schedule */
    function _originatePrepayReady()
        internal
        returns (ILoanRouterV2.LoanTermsV2 memory loanTerms, bytes32 loanTermsHash_)
    {
        /* Originate a loan carrying a prorated Repayment fee */
        loanTerms = _originateProrated();

        /* Read its terms hash */
        loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Clear the first window, which leaves the loan ahead of schedule */
        _repayAt(loanTerms, _schedule(loanTerms)[0]);
    }

    /* Fund the borrower and send a standalone prepayment */
    function _prepay(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint256 amount
    ) internal {
        /* Fund the borrower with exactly the prepayment */
        deal(loanTerms.currencyToken, users.borrower, amount);

        /* Approve and prepay as the borrower */
        vm.startPrank(users.borrower);
        IERC20(loanTerms.currencyToken).approve(address(router), amount);
        router.repay(loanTerms, amount);
        vm.stopPrank();
    }

    function test__Repay_PrepaymentOnly_RepaymentFee_NoFeeCharged() public {
        (ILoanRouterV2.LoanTermsV2 memory loanTerms, bytes32 loanTermsHash_) = _originatePrepayReady();

        /* Read the balance before prepaying */
        (,,, uint256 balanceBefore) = router.loanState(loanTermsHash_);

        /* Read the fee recipient balance before prepaying */
        uint256 recipientBefore = IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient);

        /* Prepay a chunk of principal inside the window that was already paid */
        uint256 prepayment = 10_000_000 * 1e18;
        _prepay(loanTerms, prepayment);

        /* A standalone prepayment owes no fee, so the recipient receives nothing */
        assertEq(
            IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient),
            recipientBefore,
            "Standalone prepayment must charge no fee"
        );

        /* The balance drops by exactly the prepayment */
        (,,, uint256 balanceAfter) = router.loanState(loanTermsHash_);
        assertEq(balanceAfter, balanceBefore - prepayment, "Balance must drop by exactly the prepayment");
    }

    function test__Repay_PrepaymentOnly_RepaymentFee_RecastsLevelPaymentProportionally() public {
        /* Loan A stays on schedule with no prepayment */
        (ILoanRouterV2.LoanTermsV2 memory loanA, bytes32 hashA) = _originatePrepayReady();

        /* Loan B prepays a chunk of principal */
        (ILoanRouterV2.LoanTermsV2 memory loanB, bytes32 hashB) = _originatePrepayReady();
        _prepay(loanB, 10_000_000 * 1e18);

        /* Read both balances after the prepayment */
        (,,, uint256 balanceA) = router.loanState(hashA);
        (,,, uint256 balanceB) = router.loanState(hashB);
        assertLt(balanceB, balanceA, "Prepayment must reduce the balance");

        /* Quote the next window for both loans */
        uint64[] memory schedule = _schedule(loanA);
        vm.warp(schedule[1]);
        (uint256 principalA, uint256 interestA, uint256 feeA) = router.quote(loanA, schedule[1]);
        (uint256 principalB, uint256 interestB, uint256 feeB) = router.quote(loanB, schedule[1]);

        /* The prorated fee is balance proportional, so it tracks the reduced balance */
        assertApproxEqRel(feeB, feeA * balanceB / balanceA, 0.0001e18, "Fee must track the reduced balance");

        /* The level total recasts in proportion, which leaves the term untouched */
        assertApproxEqRel(
            principalB + interestB + feeB,
            (principalA + interestA + feeA) * balanceB / balanceA,
            0.0001e18,
            "Level total must recast in proportion to the reduced balance"
        );

        /* The prepayment does not shorten the deadline schedule */
        assertEq(_schedule(loanB).length, schedule.length, "Prepayment must not shorten the schedule");
    }

    function test__Repay_Prepayment_RepaymentFee_ChargesFeeOnPrePaymentBalance() public {
        (ILoanRouterV2.LoanTermsV2 memory loanTerms, bytes32 loanTermsHash_) = _originatePrepayReady();

        /* Move to the next window deadline */
        uint64[] memory schedule = _schedule(loanTerms);
        vm.warp(schedule[1]);

        /* Read the balance the fee has to be priced against */
        (,,, uint256 balanceBefore) = router.loanState(loanTermsHash_);

        /* The quoted fee prorates the window against the balance carried through it */
        (uint256 principal, uint256 interest, uint256 fee) = router.quote(loanTerms, schedule[1]);
        assertApproxEqAbs(
            fee,
            _proratedFee(balanceBefore, schedule[1] - schedule[0]),
            2,
            "Fee must price the balance carried through the window"
        );

        /* Read the fee recipient balance before repaying */
        uint256 recipientBefore = IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient);

        /* Repay the window plus an excess that the router treats as a prepayment */
        uint256 excess = 5_000_000 * 1e18;
        _fundAndRepay(loanTerms, principal + interest + fee + excess);

        /* The recipient receives the fee priced before the prepayment, not after it */
        assertEq(
            IERC20(loanTerms.currencyToken).balanceOf(users.feeRecipient) - recipientBefore,
            fee,
            "Bundled prepayment must not reprice the fee"
        );

        /* The balance drops by the scheduled principal plus the excess */
        (,,, uint256 balanceAfter) = router.loanState(loanTermsHash_);
        assertEq(balanceAfter, balanceBefore - principal - excess, "Balance must drop by principal plus excess");

        /* The following window prices its fee on the reduced balance */
        vm.warp(schedule[2]);
        (,, uint256 nextFee) = router.quote(loanTerms, schedule[2]);
        assertApproxEqAbs(
            nextFee,
            _proratedFee(balanceAfter, schedule[2] - schedule[1]),
            2,
            "Next window fee must price the reduced balance"
        );
    }

    function test__Repay_PrepaymentOnly_RepaymentFee_StillAmortizesToZero() public {
        (ILoanRouterV2.LoanTermsV2 memory loanTerms, bytes32 loanTermsHash_) = _originatePrepayReady();

        /* Prepay a chunk of principal before resuming the schedule */
        _prepay(loanTerms, 10_000_000 * 1e18);

        /* Record the repayment count, which a standalone prepayment must leave alone */
        (, uint16 repaymentCountAfterPrepay,,) = router.loanState(loanTermsHash_);
        assertEq(repaymentCountAfterPrepay, 1, "Standalone prepayment must not advance the repayment count");

        /* Walk the rest of the schedule, paying each window in full */
        uint64[] memory schedule = _schedule(loanTerms);
        for (uint256 i = 1; i < schedule.length; i++) {
            vm.warp(schedule[i]);

            (uint256 principal, uint256 interest, uint256 fee) = router.quote(loanTerms, schedule[i]);

            _fundAndRepay(loanTerms, principal + interest + fee);
        }

        /* The recast schedule still amortizes the loan to zero on its original term */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid), "Loan must be repaid");
        assertEq(balance, 0, "Balance must reach zero");
    }
}
