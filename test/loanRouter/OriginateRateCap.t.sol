// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {AmortizedInterestRateModel} from "src/rates/AmortizedInterestRateModel.sol";

/**
 * @title Originate rate cap test
 * @author USD.AI Foundation
 */
contract LoanRouterV2OriginateRateCapTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: rate above the maximum */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A tranche rate above the maximum is rejected at origination
     */
    function test__Originate_RevertWhen_RateAboveMaximum() public {
        /* Build the default loan terms */
        RouterFixture.LoanConfig memory config = _defaultConfig();

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);

        /* Move to the origination time */
        vm.warp(_recipeTimestamp(config.variant));

        /* Stage the lender deposits */
        prepareLenderDeposits(loanTerms, true);

        /* Push the tranche rate above the maximum */
        loanTerms.trancheSpecs[0].rate = MAX_INTEREST_RATE + 1;

        /* The router rejects the out of range rate */
        vm.prank(users.deployer);

        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Rate"));

        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: grace period rate above the maximum */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A grace period rate above the maximum is rejected at origination
     */
    function test__Originate_RevertWhen_GracePeriodRateAboveMaximum() public {
        /* Build the default loan terms */
        RouterFixture.LoanConfig memory config = _defaultConfig();

        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);

        /* Use the amortized interest rate model */
        loanTerms.interestRateSpec.model = address(new AmortizedInterestRateModel());

        /* Push the grace period rate above the maximum */
        loanTerms.interestRateSpec.options = abi.encode(
            AmortizedInterestRateModel.Options({
                principalAndInterestStubPayment: false,
                gracePeriodDuration: 3 days,
                gracePeriodRate: MAX_INTEREST_RATE + 1
            })
        );

        /* Move to the origination time */
        vm.warp(_recipeTimestamp(config.variant));

        /* Stage the lender deposits */
        prepareLenderDeposits(loanTerms, true);

        /* The interest rate model rejects the out of range rate */
        vm.prank(users.deployer);

        vm.expectRevert(AmortizedInterestRateModel.InvalidOptions.selector);

        router.originate(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: rate at the maximum on the longest schedule */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A loan at the maximum rate on a long schedule still quotes
     */
    function test__Originate_RateAtMaximum_LongestScheduleQuotes() public {
        /* Use a long loan duration */
        RouterFixture.LoanConfig memory config = _defaultConfig();

        config.durationDays = 4000;

        /* Build the loan terms */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = buildLoanTerms(config);

        /* Set the tranche rate to the maximum */
        loanTerms.trancheSpecs[0].rate = MAX_INTEREST_RATE;

        /* Use the amortized interest rate model */
        loanTerms.interestRateSpec.model = address(new AmortizedInterestRateModel());

        /* Use no stub payment and no grace period */
        loanTerms.interestRateSpec.options = abi.encode(
            AmortizedInterestRateModel.Options({
                principalAndInterestStubPayment: false, gracePeriodDuration: 0, gracePeriodRate: 0
            })
        );

        /* Move to the origination time */
        vm.warp(_recipeTimestamp(config.variant));

        /* Stage the lender deposits */
        prepareLenderDeposits(loanTerms, true);

        /* Stage the collateral */
        prepareCollateralDeposit(loanTerms);

        /* Originate the loan */
        originateLoan(loanTerms, buildDepositInfos(loanTerms, true), new bytes[](0));

        /* Move to the first deadline */
        uint64[] memory schedule = _schedule(loanTerms);

        vm.warp(schedule[0]);

        /* Quote the first payment */
        (uint256 principal, uint256 interest, uint256 fees) = router.quote(loanTerms, schedule[0]);

        /* Sum the first payment */
        uint256 total = principal + interest + fees;

        /* Fund the borrower */
        deal(loanTerms.currencyToken, users.borrower, total + 1e20);

        /* Repay the first payment as the borrower */
        vm.startPrank(users.borrower);

        IERC20(loanTerms.currencyToken).approve(address(router), total);

        router.repay(loanTerms, total);

        vm.stopPrank();

        /* Move to the second deadline */
        vm.warp(schedule[1]);

        /* Quote the second payment */
        (principal, interest,) = router.quote(loanTerms, schedule[1]);

        /* The quote stays available at the maximum rate */
        assertGt(principal + interest, 0, "Quote must remain available at the maximum rate");
    }
}
