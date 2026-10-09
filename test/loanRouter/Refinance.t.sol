// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";
import {LoanFixtures} from "../helpers/LoanFixtures.sol";
import {TestERC721} from "../mocks/TestERC721.sol";

import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ILoanRouterV2Hooks} from "src/interfaces/ILoanRouterV2Hooks.sol";
import {AbsoluteFeeModel} from "src/fees/AbsoluteFeeModel.sol";
import {RatioFeeModel} from "src/fees/RatioFeeModel.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";

/**
 * @title Refinance test
 * @author USD.AI Foundation
 */
contract LoanRouterV2RefinanceTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Flat refinance fee of 100k USDai */
    uint256 internal constant REFINANCE_FEE = 100_000 * 1e18;

    /* Cash-in or cash-out delta of 5M USDai */
    uint256 internal constant CASH_DELTA = 5_000_000 * 1e18;

    /* Cash-in or cash-out delta of 1M USDC in 6 decimal units */
    uint256 internal constant CASH_DELTA_USDC = 1_000_000 * 1e6;

    /* Scale factor applied to a 6 decimal token to reach the 18 decimal internal precision */
    uint256 internal constant USDC_SCALE_FACTOR = 1e12;

    /*------------------------------------------------------------------------*/
    /* Originated loans */
    /*------------------------------------------------------------------------*/

    /* Originated loan */
    ILoanRouterV2.LoanTermsV2 internal loanA;

    /* Loan under test for the multi-tranche and non-USDai decimal cases */
    ILoanRouterV2.LoanTermsV2 internal loanB;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        /* Deploy the fresh router, timelocks, and roles */
        super.setUp();

        /* Originate the loan under test */
        loanA = originateDefault();

        /* Mock the lender refinance hook so the test isolates router accounting */
        vm.mockCall(STAKED_USDAI, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "");

        /* Let the tranche 0 lender fund cash-out deltas from the deposit timelock */
        vm.prank(users.deployer);
        IAccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), STAKED_USDAI);

        vm.prank(STAKED_USDAI);
        IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);

        /* Bring the borrower current so the loan is eligible to refinance */
        _seasonForRefinance(loanA);
    }

    /*------------------------------------------------------------------------*/
    /* Test: reprice */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A pure reprice moves only the refinance fee
     */
    function test__RefinanceReprice() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Reprice to the same principal with a new rate and a refinance fee */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);

        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 lenderBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        /* Capture the old loan hash */
        bytes32 oldHash = router.loanTermsHash(loanA);

        /* Read the old schedule state so the new loan can be checked against it */
        (, uint16 oldCount, uint64 oldOrigination,) = router.loanState(oldHash);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Only the fee moved */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), borrowerBefore - REFINANCE_FEE, "borrower fee");

        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI), lenderBefore, "lender balance");

        /* New loan carries the balance forward and keeps the schedule */
        _assertNewLoanState(newTerms, balance, oldCount, oldOrigination);

        /* Old loan is repaid */
        (ILoanRouterV2.LoanStatus oldStatus,,,) = router.loanState(oldHash);

        assertEq(uint8(oldStatus), uint8(ILoanRouterV2.LoanStatus.Repaid), "old loan not repaid");
    }

    /**
     * @notice Refinancing a live loan keeps the repayment count, origination, and deadline schedule
     */
    function test__RefinancePreservesScheduleState() public {
        /* Read the old loan schedule state */
        bytes32 oldHash = router.loanTermsHash(loanA);

        (, uint16 oldCount, uint64 oldOrigination,) = router.loanState(oldHash);

        uint64[] memory oldSchedule = router.deadlines(loanA);

        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Reprice to the same principal with a refinance fee */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Read the new loan state */
        (, uint16 newCount, uint64 newOrigination,) = router.loanState(router.loanTermsHash(newTerms));

        /* The borrower keeps credit for installments already paid */
        assertEq(newCount, oldCount, "repayment count not carried");

        /* Origination stays put so the maturity does not extend */
        assertEq(newOrigination, oldOrigination, "origination not carried");

        assertLt(newOrigination, uint64(block.timestamp), "origination advanced to refinance time");

        /* The deadline schedule is unchanged */
        uint64[] memory newSchedule = router.deadlines(newTerms);

        assertEq(newSchedule.length, oldSchedule.length, "schedule length changed");

        for (uint256 i; i < oldSchedule.length; i++) {
            assertEq(newSchedule[i], oldSchedule[i], "deadline moved");
        }
    }

    /*------------------------------------------------------------------------*/
    /* Test: lender hook */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing calls onLoanRefinanced on each supporting tranche lender with its index
     */
    function test__RefinanceNotifiesLenderHook() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Build repriced terms with a refinance fee */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Make the lender report support for the hooks interface */
        vm.mockCall(
            STAKED_USDAI,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterV2Hooks).interfaceId),
            abi.encode(true)
        );

        /* Compute the old and new loan hashes */
        bytes32 oldHash = router.loanTermsHash(loanA);

        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Expect the refinance hook on tranche 0 carrying its index and zero cash on both sides */
        vm.expectCall(
            STAKED_USDAI,
            abi.encodeWithSelector(
                ILoanRouterV2Hooks.onLoanRefinanced.selector,
                loanA,
                newTerms,
                oldHash,
                newHash,
                uint8(0),
                uint256(0),
                uint256(0)
            )
        );

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);
    }

    /*------------------------------------------------------------------------*/
    /* Test: cash-out */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A cash-out draws the delta from the deposit timelock and pays the borrower
     */
    function test__RefinanceCashOut() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance without any borrower balance or approval */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives the delta net of the fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA - REFINANCE_FEE, "borrower cash-out");

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Deposit timelock drained by the delta */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - CASH_DELTA, "timelock drained");

        /* New balance grew by the delta */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, newPrincipal, "new balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: cash-in */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A cash-in pulls the delta from the borrower and repays the lender
     */
    function test__RefinanceCashIn() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Shrink the principal by the cash-in delta */
        uint256 newPrincipal = balance - CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Fund and approve the borrower for the cash-in plus fee */
        _fundBorrower(CASH_DELTA + REFINANCE_FEE);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);

        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 lenderBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower pays the delta plus the fee */
        assertEq(
            IERC20(USDAI).balanceOf(users.borrower), borrowerBefore - CASH_DELTA - REFINANCE_FEE, "borrower cash-in"
        );

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Lender receives the repaid principal */
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI), lenderBefore + CASH_DELTA, "lender repaid");

        /* New balance shrank by the delta */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, newPrincipal, "new balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: allowed changes */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinancing may switch to a different interest rate model
     */
    function test__RefinanceChangesInterestRateModel() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Build repriced terms and point them at a fresh rate model */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        SimpleInterestRateModel newModel = new SimpleInterestRateModel();

        newTerms.interestRateSpec.model = address(newModel);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* New loan is active under the new model */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /**
     * @notice The new lender must be whoever currently holds the old position NFT
     */
    function test__RefinanceLenderFollowsPositionOwner() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Transfer the old tranche position to a new holder */
        uint256 oldTokenId = router.loanTokenIds(loanA)[0];

        vm.prank(STAKED_USDAI);
        router.transferFrom(STAKED_USDAI, users.lender1, oldTokenId);

        /* Reprice with the tranche lender set to the new holder */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        newTerms.trancheSpecs[0].lender = users.lender1;

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* New position is minted to the new holder */
        uint256 newTokenId = router.loanTokenIds(newTerms)[0];

        assertEq(router.ownerOf(newTokenId), users.lender1, "new lender not position owner");
    }

    /*------------------------------------------------------------------------*/
    /* Test: fee and cash edge cases */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A reprice with no fee spec moves no cash at all
     */
    function test__RefinanceZeroFee() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Reprice to the same principal with no refinance fee */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Drop the fee spec so the refinance carries no fee */
        newTerms.feeSpecs = new ILoanRouterV2.FeeSpec[](0);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);

        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 lenderBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        /* Refinance without funding or approving the borrower */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* No balance moved for any party */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), borrowerBefore, "borrower balance");

        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore, "fee recipient");

        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI), lenderBefore, "lender balance");

        /* New loan is active */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /**
     * @notice A cash-out that exactly covers the fee pays the borrower nothing
     */
    function test__RefinanceCashOutExactlyCoversFee() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by exactly the refinance fee */
        uint256 newPrincipal = balance + REFINANCE_FEE;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, REFINANCE_FEE);

        /* Zero the borrower so no borrower balance is available */
        deal(USDAI, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance without any borrower balance or approval */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives nothing because the cash-out exactly covers the fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), 0, "borrower balance");

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Deposit timelock drained by the fee amount */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - REFINANCE_FEE, "timelock drained");
    }

    /**
     * @notice A ratio refinance fee is charged on the old balance, not the grown principal
     */
    function test__RefinanceFeeChargesOldBalance() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the principal by the cash-out delta */
        uint256 newPrincipal = balance + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Replace the fee with a one percent ratio on the amount basis */
        RatioFeeModel ratioFeeModel = new RatioFeeModel();

        uint256 feeRate = FIXED_POINT_SCALE / 100;

        ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Refinance,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: feeRate}))
        });
        newTerms.feeSpecs = feeSpecs;

        /* The fee is one percent of the old balance, not the grown principal */
        uint256 expectedFee = Math.mulDiv(balance, feeRate, FIXED_POINT_SCALE, Math.Rounding.Ceil);

        /* Lender funds the cash-out delta into the deposit timelock */
        _fundCashOut(newTerms, CASH_DELTA);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Read the fee recipient balance before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Fee recipient receives one percent of the old balance */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + expectedFee, "fee on old balance");

        /* Borrower receives the cash-out net of that fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA - expectedFee, "borrower cash-out net of fee");
    }

    /**
     * @notice A reverting lender hook is caught and does not block the refinance
     */
    function test__RefinanceLenderHookRevertDoesNotBlock() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Build repriced terms with a refinance fee */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Make the lender report support for the hooks interface */
        vm.mockCall(
            STAKED_USDAI,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterV2Hooks).interfaceId),
            abi.encode(true)
        );

        /* Make the lender refinance hook revert */
        vm.mockCallRevert(
            STAKED_USDAI, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "hook reverted"
        );

        /* Refinance still succeeds */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* New loan is active despite the reverting hook */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /*------------------------------------------------------------------------*/
    /* Test: refinance window */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Paying the cycle opens the refinance window up to that cycle's deadline
     */
    function test__RefinanceAllowedOnlyBeforeCycleDeadline() public {
        /* Originate a loan and leave the first installment unpaid */
        loanB = _originateSingleUsdcUnseasoned();

        /* Read the first deadline before any payment */
        uint64 firstDeadline = router.deadlines(loanB)[0];

        /* Bring the borrower current ahead of that deadline */
        _seasonForRefinance(loanB);

        uint256 balance = _readBalance(loanB);

        /* Keep the tranche flat so no cash has to move */
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanB.trancheSpecs[0].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Once the deadline passes the window closes again */
        vm.warp(firstDeadline + 1);

        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Current Window Not Repaid"));
        router.refinance(loanB, newTerms, balance);

        /* Back inside the window the same refinance succeeds */
        vm.warp(firstDeadline);

        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* New loan is active */
        (ILoanRouterV2.LoanStatus status,,,) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");
    }

    /*------------------------------------------------------------------------*/
    /* Test: tranche removal */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Dropping a trailing tranche repays its lender and burns its position
     */
    function test__RefinanceRemovesTrailingTranche() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Sum the old tranche notionals */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        /* Capture the removed tranche's position token before it is burned */
        uint256 removedTokenId = router.loanTokenIds(loanB)[1];

        /* Drop tranche 1 and keep tranche 0 at its notional */
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanB.trancheSpecs[0].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* The removed tranche is cashed in at the balance ratio, rounded up */
        uint256 expectedCashIn = Math.mulDiv(loanB.trancheSpecs[1].amount, balance, oldPrincipal, Math.Rounding.Ceil);

        /* Fund and approve the borrower for the cash-in */
        _fundBorrower(expectedCashIn);

        /* Read the removed lender's balance before refinancing */
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* The removed lender is paid out in full */
        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before + expectedCashIn, "removed lender cash-in");

        /* The borrower funded the whole cash-in */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), 0, "borrower cash-in");

        /* The removed position no longer exists */
        vm.expectRevert();
        router.ownerOf(removedTokenId);

        /* The removed position's reverse lookup is cleared */
        (bytes32 lookupHash,) = router.lenderPositionInfo(removedTokenId);

        assertEq(lookupHash, bytes32(0), "reverse lookup not cleared");

        /* The new loan carries the old balance at the new principal ratio */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, Math.mulDiv(balance, amounts[0], oldPrincipal), "new balance");
    }

    /**
     * @notice A removed tranche pays the current position owner, not the original lender
     */
    function test__RefinanceRemovedTranchePaysPositionOwner() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Sum the old tranche notionals */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        /* Move the removed tranche's position to a third party */
        uint256 removedTokenId = router.loanTokenIds(loanB)[1];

        vm.prank(users.lender2);
        router.transferFrom(users.lender2, users.lender3, removedTokenId);

        /* Drop tranche 1 and keep tranche 0 at its notional */
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanB.trancheSpecs[0].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* The removed tranche is cashed in at the balance ratio, rounded up */
        uint256 expectedCashIn = Math.mulDiv(loanB.trancheSpecs[1].amount, balance, oldPrincipal, Math.Rounding.Ceil);

        /* Fund and approve the borrower for the cash-in */
        _fundBorrower(expectedCashIn);

        /* Read both lender balances before refinancing */
        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        uint256 lender3Before = IERC20(USDAI).balanceOf(users.lender3);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* The new position owner receives the payout */
        assertEq(IERC20(USDAI).balanceOf(users.lender3), lender3Before + expectedCashIn, "position owner cash-in");

        /* The original lender receives nothing */
        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before, "original lender paid");
    }

    /**
     * @notice A removed tranche's lender is still notified through the refinance hook
     */
    function test__RefinanceNotifiesRemovedTrancheLender() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Sum the old tranche notionals */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        /* Make the removed tranche's lender report support for the hooks interface */
        vm.mockCall(
            users.lender2,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterV2Hooks).interfaceId),
            abi.encode(true)
        );

        vm.mockCall(users.lender2, abi.encodeWithSelector(ILoanRouterV2Hooks.onLoanRefinanced.selector), "");

        /* Drop tranche 1 and keep tranche 0 at its notional */
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanB.trancheSpecs[0].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* The removed tranche is cashed in at the balance ratio, rounded up */
        uint256 expectedCashIn = Math.mulDiv(loanB.trancheSpecs[1].amount, balance, oldPrincipal, Math.Rounding.Ceil);

        /* Fund and approve the borrower for the cash-in */
        _fundBorrower(expectedCashIn);

        /* Compute the old and new loan hashes */
        bytes32 oldHash = router.loanTermsHash(loanB);

        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Expect the hook on the removed tranche carrying its cash-in and no cash-out */
        vm.expectCall(
            users.lender2,
            abi.encodeWithSelector(
                ILoanRouterV2Hooks.onLoanRefinanced.selector,
                loanB,
                newTerms,
                oldHash,
                newHash,
                uint8(1),
                uint256(0),
                expectedCashIn
            )
        );

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);
    }

    /**
     * @notice A cash-out tranche reports its cash-out and no cash-in to its lender hook
     */
    function test__RefinanceHookReportsCashOutOnly() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        /* Grow the tranche notional by the cash-out delta */
        uint256 oldPrincipal = loanA.trancheSpecs[0].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, oldPrincipal + CASH_DELTA, 0);

        /* The cash-out revalues the delta at the balance ratio */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA, balance, oldPrincipal);

        /* Lender funds the cash-out into the deposit timelock */
        _fundCashOut(newTerms, expectedCashOut);

        /* Make the lender report support for the hooks interface */
        vm.mockCall(
            STAKED_USDAI,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ILoanRouterV2Hooks).interfaceId),
            abi.encode(true)
        );

        /* Compute the old and new loan hashes */
        bytes32 oldHash = router.loanTermsHash(loanA);

        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Expect the hook carrying the cash-out and no cash-in */
        vm.expectCall(
            STAKED_USDAI,
            abi.encodeWithSelector(
                ILoanRouterV2Hooks.onLoanRefinanced.selector,
                loanA,
                newTerms,
                oldHash,
                newHash,
                uint8(0),
                expectedCashOut,
                uint256(0)
            )
        );

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);
    }

    /*------------------------------------------------------------------------*/
    /* Test: reverts */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A caller without the originator role cannot refinance
     */
    function test__RevertWhen_CallerNotRefinancer() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* An unauthorized account is rejected */
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Refinancing an already refinanced loan is rejected
     */
    function test__RevertWhen_OldLoanNotActive() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Refinance once, clearing the old loan */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Refinancing the cleared loan again reverts */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidLoanState.selector);
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the tranche lender is rejected
     */
    function test__RevertWhen_LenderChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Change the tranche lender */
        newTerms.trancheSpecs[0].lender = users.lender2;

        /* The router rejects the changed lender */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Lender"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the borrower is rejected
     */
    function test__RevertWhen_BorrowerChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Change the borrower */
        newTerms.borrower = users.lender2;

        /* The router rejects the changed borrower */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Borrower"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A stale expected balance from a last-minute prepay is rejected
     */
    function test__RevertWhen_ExpectedBalanceMismatch() public {
        /* Pay the first installment and read the quoted balance */
        uint256 balance = _payFirstInstallment(loanA);

        /* Build terms off the quoted balance */
        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Borrower prepays part of the principal after the quote was taken */
        _prepay(loanA, CASH_DELTA);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* The router rejects the now-stale expected balance */
        vm.prank(users.deployer);
        vm.expectRevert(ILoanRouterV2.InvalidAmount.selector);
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Expired new loan terms are rejected
     */
    function test__RevertWhen_NewTermsExpired() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Set the expiration into the past */
        newTerms.expiration = uint64(block.timestamp - 1);

        /* The router rejects the expired terms */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Expiration"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the currency token is rejected
     */
    function test__RevertWhen_CurrencyTokenChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Change the currency token */
        newTerms.currencyToken = USDC;

        /* The router rejects the changed currency token */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Currency Token"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the collateral token is rejected
     */
    function test__RevertWhen_CollateralTokenChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Point the collateral token at a fresh NFT */
        TestERC721 otherCollateral = new TestERC721("Other", "OTH");

        newTerms.collateralToken = address(otherCollateral);

        /* The router rejects the changed collateral token */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Collateral Token"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the collateral token IDs is rejected
     */
    function test__RevertWhen_CollateralTokenIdsChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Swap in a different collateral token ID */
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = newTerms.collateralTokenIds[0] + 1;
        newTerms.collateralTokenIds = tokenIds;

        /* The router rejects the changed collateral token IDs */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Collateral Token IDs"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Changing the repayment schedule is rejected
     */
    function test__RevertWhen_RepaymentSpecChanged() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Change the repayment day */
        newTerms.repaymentSpec.day = loanA.repaymentSpec.day == 1 ? 2 : 1;

        /* The router rejects the changed repayment spec */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Repayment Spec"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero interest rate model address is rejected
     */
    function test__RevertWhen_InterestRateModelZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Zero the interest rate model */
        newTerms.interestRateSpec.model = address(0);

        /* The router rejects the missing interest rate model */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Interest Rate Model"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice Raising the tranche count is rejected
     */
    function test__RevertWhen_TrancheCountIncreased() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Split the single tranche into two */
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](2);
        tranches[0] = ILoanRouterV2.TrancheSpec({lender: STAKED_USDAI, amount: balance / 2, rate: RATE_10_PCT});
        tranches[1] = ILoanRouterV2.TrancheSpec({lender: STAKED_USDAI, amount: balance / 2, rate: RATE_10_PCT});
        newTerms.trancheSpecs = tranches;

        /* The router rejects the changed tranche count */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Tranche Specs"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero tranche rate is rejected
     */
    function test__RevertWhen_RateZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Zero the tranche rate */
        newTerms.trancheSpecs[0].rate = 0;

        /* The router rejects the zero rate */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Rate"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A tranche rate above the maximum is rejected
     */
    function test__RevertWhen_RateAboveMaximum() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Push the tranche rate above the maximum */
        newTerms.trancheSpecs[0].rate = MAX_INTEREST_RATE + 1;

        /* The router rejects the out of range rate */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Rate"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A zero tranche amount is rejected
     */
    function test__RevertWhen_TrancheAmountZero() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Zero the tranche amount */
        newTerms.trancheSpecs[0].amount = 0;

        /* The router rejects the zero tranche amount */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Tranche Amount"));
        router.refinance(loanA, newTerms, balance);
    }

    /**
     * @notice A new principal too small to cover one unit per window is rejected
     */
    function test__RevertWhen_PrincipalTooSmall() public {
        /* Read the outstanding balance without repaying */
        uint256 balance = _readBalance(loanA);

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, balance, REFINANCE_FEE);

        /* Shrink the tranche amount below the window count */
        newTerms.trancheSpecs[0].amount = 1;

        /* The router rejects the undersized principal */
        vm.prank(users.deployer);
        vm.expectRevert(abi.encodeWithSelector(ILoanRouterV2.InvalidLoanTerms.selector, "Principal"));
        router.refinance(loanA, newTerms, balance);
    }

    /*------------------------------------------------------------------------*/
    /* Test: multi-tranche */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A multi-tranche reprice splits the balance across tranches and moves only the fee
     */
    function test__RefinanceMultiTrancheReprice() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Split the outstanding balance the same way the router does, senior first */
        uint256 out0 = balance / 2;

        uint256 out1 = balance - out0;

        /* Reprice both tranches to their outstanding share so no cash moves */
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = out0;
        amounts[1] = out1;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, REFINANCE_FEE);

        /* Fund and approve the borrower for the fee */
        _fundBorrower(REFINANCE_FEE);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);

        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);

        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Only the fee moved */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), borrowerBefore - REFINANCE_FEE, "borrower fee");

        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        assertEq(IERC20(USDAI).balanceOf(users.lender1), lender1Before, "lender1 balance");

        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before, "lender2 balance");

        /* Each new tranche position is minted to its lender */
        uint256[] memory newTokenIds = router.loanTokenIds(newTerms);

        assertEq(router.ownerOf(newTokenIds[0]), users.lender1, "tranche 0 lender");

        assertEq(router.ownerOf(newTokenIds[1]), users.lender2, "tranche 1 lender");

        /* New balance equals the recombined split */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, balance, "new balance");
    }

    /**
     * @notice One tranche cashing out and another cashing in nets to a borrower fee only
     */
    function test__RefinanceMultiTrancheMixedCashFlow() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Split the outstanding balance across the two tranches */
        uint256 out0 = balance / 2;

        uint256 out1 = balance - out0;

        /* Grow tranche 0 by the delta and shrink tranche 1 by the same delta */
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = out0 + CASH_DELTA;
        amounts[1] = out1 - CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, REFINANCE_FEE);

        /* Tranche 0 lender funds its cash-out delta into the deposit timelock */
        _fundCashOutTranche(newTerms, 0, CASH_DELTA);

        /* Fund and approve the borrower for the fee alone since the deltas net out */
        _fundBorrower(REFINANCE_FEE);

        /* Read balances before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Tranche 1 lender receives the cash-in delta */
        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before + CASH_DELTA, "lender2 cash-in");

        /* Borrower pays only the fee because the deltas cancel */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), 0, "borrower balance");

        /* Fee recipient receives the fee */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + REFINANCE_FEE, "fee recipient");

        /* Deposit timelock drained by the cash-out delta */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - CASH_DELTA, "timelock drained");

        /* New balance holds the recombined split */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, balance, "new balance");
    }

    /**
     * @notice A tranche left unchanged draws and repays nothing while another cashes out
     */
    function test__RefinanceMultiTrancheZeroDelta() public {
        /* Originate a two-tranche USDai loan and bring it current */
        loanB = _originateTwoTranche(USDAI);

        uint256 balance = _readBalance(loanB);

        /* Split the outstanding balance across the two tranches */
        uint256 out0 = balance / 2;

        uint256 out1 = balance - out0;

        /* Leave tranche 0 untouched and grow tranche 1 by the delta */
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = out0;
        amounts[1] = out1 + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Tranche 1 lender funds its cash-out delta into the deposit timelock */
        _fundCashOutTranche(newTerms, 1, CASH_DELTA);

        /* Zero the borrower so the cash-out alone reaches it */
        deal(USDAI, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Unchanged tranche 0 lender neither pays nor receives */
        assertEq(IERC20(USDAI).balanceOf(users.lender1), lender1Before, "lender1 balance");

        /* Borrower receives the full cash-out with no fee */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), CASH_DELTA, "borrower cash-out");

        /* Deposit timelock drained by the single cash-out delta */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - CASH_DELTA, "timelock drained");
    }

    /**
     * @notice A flat refinance of a partially repaid loan moves no cash and needs no deposit
     */
    function test__RefinanceFlatAfterRepayMovesNoCash() public {
        /* Originate a two-tranche USDC loan and bring it current */
        loanB = _originateTwoTranche(USDC);

        /* Pay the first installment so the outstanding balance no longer divides cleanly */
        uint256 balance = _payFirstInstallment(loanB);

        /* Keep each tranche at its current amount so the refinance is flat */
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = loanB.trancheSpecs[0].amount;
        amounts[1] = loanB.trancheSpecs[1].amount;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDC).balanceOf(users.borrower);

        uint256 lender1Before = IERC20(USDC).balanceOf(users.lender1);

        uint256 lender2Before = IERC20(USDC).balanceOf(users.lender2);

        uint256 timelockBefore = IERC20(USDC).balanceOf(address(depositTimelock));

        /* Refinance without any timelock deposit or borrower funding */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* No cash moved for the borrower */
        assertEq(IERC20(USDC).balanceOf(users.borrower), borrowerBefore, "borrower balance");

        /* No cash moved for either lender */
        assertEq(IERC20(USDC).balanceOf(users.lender1), lender1Before, "lender1 balance");

        assertEq(IERC20(USDC).balanceOf(users.lender2), lender2Before, "lender2 balance");

        /* The deposit timelock was never touched */
        assertEq(IERC20(USDC).balanceOf(address(depositTimelock)), timelockBefore, "timelock unchanged");

        /* New loan carries the reduced balance forward unchanged */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, balance, "new balance carried");
    }

    /*------------------------------------------------------------------------*/
    /* Test: partially repaid loans */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A cash-out on a partially repaid loan scales the notional increase by the balance ratio
     */
    function test__RefinanceCashOutAfterRepayScalesByRatio() public {
        /* Season the loan by prepaying part of the principal */
        _prepay(loanA, CASH_DELTA);

        uint256 balance = _readBalance(loanA);

        /* Grow the tranche notional by the delta */
        uint256 oldPrincipal = loanA.trancheSpecs[0].amount;

        uint256 newPrincipal = oldPrincipal + CASH_DELTA;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = newPrincipal;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanA, amounts, RATE_10_PCT, 0);

        /* Cash-out is the notional increase revalued at the balance ratio, rounded down */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA, balance, oldPrincipal);

        /* Lender funds the cash-out into the deposit timelock */
        _fundCashOut(newTerms, expectedCashOut);

        /* Zero the borrower so the cash-out alone reaches it */
        deal(USDAI, users.borrower, 0);

        /* Read the timelock balance before refinancing */
        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower receives the ratio-scaled cash-out */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), expectedCashOut, "borrower cash-out");

        /* The deposit timelock is drained by the same amount */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - expectedCashOut, "timelock");

        /* The seasoned loan draws less cash than the raw notional increase */
        assertLt(expectedCashOut, CASH_DELTA, "ratio not applied");

        /* New balance carries at the new principal ratio */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, Math.mulDiv(balance, newPrincipal, oldPrincipal), "new balance carried");
    }

    /**
     * @notice A cash-in on a partially repaid loan scales the notional decrease by the balance ratio
     */
    function test__RefinanceCashInAfterRepayScalesByRatio() public {
        /* Season the loan by prepaying part of the principal */
        _prepay(loanA, CASH_DELTA);

        uint256 balance = _readBalance(loanA);

        /* Shrink the tranche notional by the delta */
        uint256 oldPrincipal = loanA.trancheSpecs[0].amount;

        uint256 newPrincipal = oldPrincipal - CASH_DELTA;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = newPrincipal;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanA, amounts, RATE_10_PCT, 0);

        /* Cash-in is the notional decrease revalued at the balance ratio, rounded up */
        uint256 expectedCashIn = Math.mulDiv(CASH_DELTA, balance, oldPrincipal, Math.Rounding.Ceil);

        /* Fund and approve the borrower for the cash-in */
        _fundBorrower(expectedCashIn);

        /* Read the lender balance before refinancing */
        uint256 lenderBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Borrower pays exactly the ratio-scaled cash-in */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), 0, "borrower cash-in");

        /* Lender receives the ratio-scaled cash-in */
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI), lenderBefore + expectedCashIn, "lender cash-in");

        /* The seasoned loan repays less cash than the raw notional decrease */
        assertLt(expectedCashIn, CASH_DELTA, "ratio not applied");

        /* New balance carries at the new principal ratio */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, Math.mulDiv(balance, newPrincipal, oldPrincipal), "new balance carried");
    }

    /**
     * @notice A rebalance on a partially repaid loan settles each tranche at the balance ratio
     */
    function test__RefinanceMultiTrancheRebalanceAfterRepay() public {
        /* Originate a two-tranche USDai loan and season it */
        loanB = _originateTwoTranche(USDAI);

        /* Season the loan by prepaying part of the principal */
        _prepay(loanB, CASH_DELTA);

        uint256 balance = _readBalance(loanB);

        /* Grow tranche 0 and shrink tranche 1 by the same notional delta */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = loanB.trancheSpecs[0].amount + CASH_DELTA;
        amounts[1] = loanB.trancheSpecs[1].amount - CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Each side is the notional delta revalued at the balance ratio */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA, balance, oldPrincipal);

        uint256 expectedCashIn = Math.mulDiv(CASH_DELTA, balance, oldPrincipal, Math.Rounding.Ceil);

        /* Tranche 0 lender funds its cash-out into the deposit timelock */
        _fundCashOutTranche(newTerms, 0, expectedCashOut);

        /* Fund and approve the borrower for the rounding shortfall between the two sides */
        _fundBorrower(expectedCashIn - expectedCashOut);

        /* Read balances before refinancing */
        uint256 borrowerBefore = IERC20(USDAI).balanceOf(users.borrower);

        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);

        uint256 lender2Before = IERC20(USDAI).balanceOf(users.lender2);

        uint256 timelockBefore = IERC20(USDAI).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Tranche 1 lender receives its ratio-scaled cash-in */
        assertEq(IERC20(USDAI).balanceOf(users.lender2), lender2Before + expectedCashIn, "lender2 cash-in");

        /* Tranche 0 lender's wallet is untouched because it funded through the timelock */
        assertEq(IERC20(USDAI).balanceOf(users.lender1), lender1Before, "lender1 balance");

        /* Deposit timelock is drained by the cash-out side */
        assertEq(IERC20(USDAI).balanceOf(address(depositTimelock)), timelockBefore - expectedCashOut, "timelock");

        /* Borrower pays only the rounding shortfall between the two sides */
        assertEq(
            IERC20(USDAI).balanceOf(users.borrower), borrowerBefore - (expectedCashIn - expectedCashOut), "borrower"
        );

        /* Total principal is unchanged so the balance carries over unchanged */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, balance, "new balance carried");
    }

    /**
     * @notice A tranche left unchanged on a partially repaid loan moves no cash while another cashes out
     */
    function test__RefinanceUnchangedTrancheAfterRepayMovesNothing() public {
        /* Originate a two-tranche USDai loan and season it */
        loanB = _originateTwoTranche(USDAI);

        /* Season the loan by prepaying part of the principal */
        _prepay(loanB, CASH_DELTA);

        uint256 balance = _readBalance(loanB);

        /* Leave tranche 0 at its amount and grow tranche 1 by the delta */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = loanB.trancheSpecs[0].amount;
        amounts[1] = loanB.trancheSpecs[1].amount + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Only tranche 1 cashes out, revalued at the balance ratio */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA, balance, oldPrincipal);

        /* Tranche 1 lender funds its cash-out into the deposit timelock */
        _fundCashOutTranche(newTerms, 1, expectedCashOut);

        /* Zero the borrower so the cash-out alone reaches it */
        deal(USDAI, users.borrower, 0);

        /* Read the unchanged tranche lender balance before refinancing */
        uint256 lender1Before = IERC20(USDAI).balanceOf(users.lender1);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Unchanged tranche 0 lender neither pays nor receives */
        assertEq(IERC20(USDAI).balanceOf(users.lender1), lender1Before, "lender1 unchanged");

        /* Borrower receives the single tranche cash-out */
        assertEq(IERC20(USDAI).balanceOf(users.borrower), expectedCashOut, "borrower cash-out");
    }

    /**
     * @notice A USDC cash-out on a partially repaid loan scales and truncates to 6 decimals
     */
    function test__RefinanceUsdcCashOutAfterRepay() public {
        /* Originate a single-tranche USDC loan and season it */
        loanB = _originateSingleUsdc();

        uint256 balance = _payFirstInstallment(loanB);

        /* Grow the tranche notional by the delta in 6 decimal units */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = oldPrincipal + CASH_DELTA_USDC;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Cash-out revalues the notional increase at the balance ratio and truncates to whole units */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA_USDC, balance, oldPrincipal * USDC_SCALE_FACTOR);

        /* Lender funds the cash-out into the deposit timelock */
        _fundCashOutTranche(newTerms, 0, expectedCashOut);

        /* Zero the borrower so the cash-out alone reaches it */
        deal(USDC, users.borrower, 0);

        /* Read the timelock balance before refinancing */
        uint256 timelockBefore = IERC20(USDC).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Borrower receives the ratio-scaled cash-out in 6 decimal units */
        assertEq(IERC20(USDC).balanceOf(users.borrower), expectedCashOut, "borrower cash-out");

        /* Deposit timelock is drained by the same amount */
        assertEq(IERC20(USDC).balanceOf(address(depositTimelock)), timelockBefore - expectedCashOut, "timelock");

        /* The seasoned loan draws less cash than the raw notional increase */
        assertLt(expectedCashOut, CASH_DELTA_USDC, "ratio not applied");

        /* New balance carries at the new principal ratio in 18 decimals */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, Math.mulDiv(balance, oldPrincipal + CASH_DELTA_USDC, oldPrincipal), "new balance carried");
    }

    /**
     * @notice A ratio refinance fee on a partially repaid loan is charged on the reduced old balance
     */
    function test__RefinanceFeeOnOldBalanceAfterRepay() public {
        /* Season the loan by prepaying part of the principal */
        _prepay(loanA, CASH_DELTA);

        uint256 balance = _readBalance(loanA);

        /* Grow the tranche notional by the delta */
        uint256 newPrincipal = loanA.trancheSpecs[0].amount + CASH_DELTA;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTerms(loanA, RATE_10_PCT, newPrincipal, REFINANCE_FEE);

        /* Replace the fee with a one percent ratio on the amount basis */
        RatioFeeModel ratioFeeModel = new RatioFeeModel();

        uint256 feeRate = FIXED_POINT_SCALE / 100;

        ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Refinance,
            recipient: address(0),
            model: address(ratioFeeModel),
            options: abi.encode(RatioFeeModel.Options({mode: RatioFeeModel.Mode.Amount, rate: feeRate}))
        });
        newTerms.feeSpecs = feeSpecs;

        /* The fee is one percent of the reduced old balance */
        uint256 expectedFee = Math.mulDiv(balance, feeRate, FIXED_POINT_SCALE, Math.Rounding.Ceil);

        /* The fee is distinct from both the grown principal and the carried new balance */
        uint256 newBalance = Math.mulDiv(balance, newPrincipal, loanA.trancheSpecs[0].amount);

        assertLt(expectedFee, Math.mulDiv(newPrincipal, feeRate, FIXED_POINT_SCALE), "fee tracks grown principal");

        assertLt(expectedFee, Math.mulDiv(newBalance, feeRate, FIXED_POINT_SCALE), "fee tracks carried balance");

        /* Lender funds the cash-out into the deposit timelock */
        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA, balance, loanA.trancheSpecs[0].amount);

        _fundCashOut(newTerms, expectedCashOut);

        /* Zero the borrower so the cash-out alone must cover the fee */
        deal(USDAI, users.borrower, 0);

        /* Read the fee recipient balance before refinancing */
        uint256 feeRecipientBefore = IERC20(USDAI).balanceOf(users.feeRecipient);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanA, newTerms, balance);

        /* Fee recipient receives one percent of the reduced old balance */
        assertEq(IERC20(USDAI).balanceOf(users.feeRecipient), feeRecipientBefore + expectedFee, "fee on old balance");
    }

    /*------------------------------------------------------------------------*/
    /* Test: non-USDai decimals */
    /*------------------------------------------------------------------------*/

    /**
     * @notice A USDC multi-tranche cash-out settles in 6 decimal units and scales the balance to 18
     */
    function test__RefinanceUsdcMultiTrancheCashOut() public {
        /* Originate a two-tranche USDC loan and bring it current */
        loanB = _originateTwoTranche(USDC);

        uint256 balance = _readBalance(loanB);

        /* Sum the old tranche notionals */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount + loanB.trancheSpecs[1].amount;

        /* Grow each tranche notional by the delta in 6 decimal units */
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = loanB.trancheSpecs[0].amount + CASH_DELTA_USDC;
        amounts[1] = loanB.trancheSpecs[1].amount + CASH_DELTA_USDC;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Each tranche revalues its delta at the balance ratio and rounds down */
        uint256 cashOutPerTranche = Math.mulDiv(CASH_DELTA_USDC, balance, oldPrincipal * USDC_SCALE_FACTOR);

        /* Each lender funds its cash-out delta into the deposit timelock */
        _fundCashOutTranche(newTerms, 0, cashOutPerTranche);

        _fundCashOutTranche(newTerms, 1, cashOutPerTranche);

        /* Zero the borrower so only the cash-out reaches it */
        deal(USDC, users.borrower, 0);

        /* Read balances before refinancing */
        uint256 timelockBefore = IERC20(USDC).balanceOf(address(depositTimelock));

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Borrower receives both cash-out deltas in 6 decimal units */
        assertEq(IERC20(USDC).balanceOf(users.borrower), cashOutPerTranche * 2, "borrower cash-out");

        /* Deposit timelock drained by the combined delta */
        assertEq(IERC20(USDC).balanceOf(address(depositTimelock)), timelockBefore - cashOutPerTranche * 2, "timelock");

        /* New balance carries the old balance at the new principal ratio */
        (,,, uint256 newBalance) = router.loanState(router.loanTermsHash(newTerms));

        assertEq(newBalance, Math.mulDiv(balance, amounts[0] + amounts[1], oldPrincipal), "new balance");
    }

    /**
     * @notice A USDC cash-in rounds up against the borrower
     */
    function test__RefinanceUsdcCashInRoundsUp() public {
        /* Originate a single-tranche USDC loan and bring it current */
        loanB = _originateSingleUsdc();

        uint256 balance = _readBalance(loanB);

        /* Shrink the single tranche below its outstanding balance by the delta */
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = balance / USDC_SCALE_FACTOR - CASH_DELTA_USDC;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Cash-in rounds the scaled shortfall up into whole 6 decimal units */
        uint256 scaledShortfall = balance - amounts[0] * USDC_SCALE_FACTOR;

        uint256 expectedCashIn = scaledShortfall % USDC_SCALE_FACTOR == 0
            ? scaledShortfall / USDC_SCALE_FACTOR
            : scaledShortfall / USDC_SCALE_FACTOR + 1;

        /* Fund and approve the borrower for the cash-in */
        deal(USDC, users.borrower, expectedCashIn);

        vm.prank(users.borrower);
        IERC20(USDC).approve(address(router), expectedCashIn);

        /* Read balances before refinancing */
        uint256 lenderBefore = IERC20(USDC).balanceOf(users.lender1);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Borrower paid the rounded-up cash-in exactly */
        assertEq(IERC20(USDC).balanceOf(users.borrower), 0, "borrower cash-in");

        /* Lender received the rounded-up cash-in */
        assertEq(IERC20(USDC).balanceOf(users.lender1), lenderBefore + expectedCashIn, "lender cash-in");

        /* The rounding never charges the borrower less than the exact shortfall */
        assertGe(expectedCashIn * USDC_SCALE_FACTOR, scaledShortfall, "borrower underpaid");

        /* The rounding never overshoots the exact shortfall by a whole unit */
        assertLt(expectedCashIn * USDC_SCALE_FACTOR - scaledShortfall, USDC_SCALE_FACTOR, "overcharged");
    }

    /**
     * @notice A USDC cash-out rounds down against the borrower
     */
    function test__RefinanceUsdcCashOutRoundsDown() public {
        /* Originate a single-tranche USDC loan and bring it current */
        loanB = _originateSingleUsdc();

        uint256 balance = _readBalance(loanB);

        /* Grow the single tranche notional by the delta */
        uint256 oldPrincipal = loanB.trancheSpecs[0].amount;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = oldPrincipal + CASH_DELTA_USDC;

        ILoanRouterV2.LoanTermsV2 memory newTerms = _buildNewTermsMulti(loanB, amounts, RATE_12_PCT, 0);

        /* Cash-out revalues the delta at the balance ratio and truncates to whole 6 decimal units */
        uint256 scaledOldPrincipal = oldPrincipal * USDC_SCALE_FACTOR;

        uint256 expectedCashOut = Math.mulDiv(CASH_DELTA_USDC, balance, scaledOldPrincipal);

        /* Lender funds the cash-out into the deposit timelock */
        _fundCashOutTranche(newTerms, 0, expectedCashOut);

        /* Zero the borrower so only the cash-out reaches it */
        deal(USDC, users.borrower, 0);

        /* Refinance */
        vm.prank(users.deployer);
        router.refinance(loanB, newTerms, balance);

        /* Borrower received the rounded-down cash-out exactly */
        assertEq(IERC20(USDC).balanceOf(users.borrower), expectedCashOut, "borrower cash-out");

        /* The rounding never pays the borrower more than the exact ratio */
        assertLe(expectedCashOut * scaledOldPrincipal, CASH_DELTA_USDC * balance, "borrower overpaid");

        /* The rounding never shorts the exact ratio by a whole unit */
        assertLt(CASH_DELTA_USDC * balance - expectedCashOut * scaledOldPrincipal, scaledOldPrincipal, "shorted");
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Read the outstanding balance without repaying
     * @param terms Loan terms
     * @return balance Scaled outstanding balance
     */
    function _readBalance(
        ILoanRouterV2.LoanTermsV2 storage terms
    ) internal view returns (uint256 balance) {
        /* Return the stored outstanding balance */
        (,,, balance) = router.loanState(router.loanTermsHash(terms));
    }

    /**
     * @notice Pay the first scheduled installment and return the resulting balance
     * @param terms Loan terms
     * @return balance Scaled outstanding balance after the payment
     */
    function _payFirstInstallment(
        ILoanRouterV2.LoanTermsV2 storage terms
    ) internal returns (uint256 balance) {
        /* Read the deadline schedule */
        uint64[] memory schedule = router.deadlines(terms);

        /* Pay the first installment at its deadline */
        _repayAt(terms, schedule[0]);

        /* Return the outstanding balance */
        (,,, balance) = router.loanState(router.loanTermsHash(terms));
    }

    /**
     * @notice Bring the borrower current on the schedule so the loan can be refinanced
     * @param terms Loan terms
     *
     * Refinancing is allowed only once the current cycle is paid and before that
     * cycle's deadline, so this pays the first installment a day early and leaves
     * a day of room for the refinance itself.
     */
    function _seasonForRefinance(
        ILoanRouterV2.LoanTermsV2 memory terms
    ) internal {
        /* Read the deadline schedule */
        uint64[] memory schedule = router.deadlines(terms);

        /* Pay the first installment one day before its deadline */
        _repayAt(terms, schedule[0] - 1 days);
    }

    /**
     * @notice Prepay principal ahead of schedule
     * @param terms Loan terms
     * @param amount Amount to prepay
     */
    function _prepay(
        ILoanRouterV2.LoanTermsV2 storage terms,
        uint256 amount
    ) internal {
        /* Fund the borrower with the exact prepayment plus headroom */
        deal(USDAI, users.borrower, amount + 1e20);

        /* Approve and prepay as the borrower */
        vm.startPrank(users.borrower);
        IERC20(USDAI).approve(address(router), amount);
        router.repay(terms, amount);
        vm.stopPrank();
    }

    /**
     * @notice Build refinanced single-tranche terms with a new rate, principal, and fee
     * @param oldTerms Old loan terms
     * @param newRate New per-second rate scaled by 1e18
     * @param newPrincipal New tranche amount
     * @param refinanceFee Flat refinance fee
     * @return newTerms Refinanced loan terms
     */
    function _buildNewTerms(
        ILoanRouterV2.LoanTermsV2 storage oldTerms,
        uint256 newRate,
        uint256 newPrincipal,
        uint256 refinanceFee
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory newTerms) {
        /* Deep copy the old terms into memory */
        newTerms = oldTerms;

        /* Set the new tranche amount and rate */
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](1);
        tranches[0] =
            ILoanRouterV2.TrancheSpec({lender: oldTerms.trancheSpecs[0].lender, amount: newPrincipal, rate: newRate});
        newTerms.trancheSpecs = tranches;

        /* Attach the refinance fee spec */
        ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
        feeSpecs[0] = ILoanRouterV2.FeeSpec({
            kind: ILoanRouterV2.FeeKind.Refinance,
            recipient: address(0),
            model: address(absoluteFeeModel),
            options: abi.encode(AbsoluteFeeModel.Options({amount: refinanceFee}))
        });
        newTerms.feeSpecs = feeSpecs;

        /* Keep the new offer valid */
        newTerms.expiration = uint64(block.timestamp + 30 days);
    }

    /**
     * @notice Fund the borrower with USDai and approve the router
     * @param amount Amount to fund and approve
     */
    function _fundBorrower(
        uint256 amount
    ) internal {
        /* Deal the borrower the funds */
        deal(USDAI, users.borrower, amount);

        /* Approve the router to pull the funds */
        vm.prank(users.borrower);
        IERC20(USDAI).approve(address(router), amount);
    }

    /**
     * @notice Fund a cash-out delta into the deposit timelock under the new loan hash
     * @param newTerms Refinanced loan terms
     * @param amount Cash-out delta
     */
    function _fundCashOut(
        ILoanRouterV2.LoanTermsV2 memory newTerms,
        uint256 amount
    ) internal {
        /* Compute the new loan terms hash */
        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Lender deposits the delta keyed to the router and new hash */
        vm.prank(STAKED_USDAI);
        depositTimelock.deposit(address(router), newHash, USDAI, amount, uint64(block.timestamp + 7 days));
    }

    /**
     * @notice Fund one tranche's cash-out delta into the deposit timelock from its lender
     * @param newTerms Refinanced loan terms
     * @param trancheIndex Tranche to fund
     * @param amount Cash-out delta in token units
     */
    function _fundCashOutTranche(
        ILoanRouterV2.LoanTermsV2 memory newTerms,
        uint8 trancheIndex,
        uint256 amount
    ) internal {
        /* Compute the new loan terms hash */
        bytes32 newHash = router.loanTermsHash(newTerms);

        /* Read the tranche lender */
        address lender = newTerms.trancheSpecs[trancheIndex].lender;

        /* Lender deposits the delta keyed to the router and new hash */
        vm.prank(lender);
        depositTimelock.deposit(
            address(router), newHash, newTerms.currencyToken, amount, uint64(block.timestamp + 7 days)
        );
    }

    /**
     * @notice Originate a two-tranche loan in the given currency and return its terms
     * @param currencyToken Loan currency token
     * @return terms Originated loan terms
     */
    function _originateTwoTranche(
        address currencyToken
    ) internal returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        /* Build a two-tranche configuration funded through the deposit timelock */
        LoanConfig memory config;
        config.durationDays = 1095;
        config.variant = LoanFixtures.WindowVariant.Upper;
        config.currencyToken = currencyToken;
        config.twoTranches = true;
        config.mixedDepositTypes = false;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](0);
        config.approvalAddresses = new address[](0);

        /* Originate the loan */
        terms = originateConfigured(config);

        /* Bring the borrower current so the loan is eligible to refinance */
        _seasonForRefinance(terms);
    }

    /**
     * @notice Originate a single-tranche USDC loan without bringing it current
     * @return terms Originated loan terms
     */
    function _originateSingleUsdcUnseasoned() internal returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        /* Build a single-tranche USDC configuration funded through the deposit timelock */
        LoanConfig memory config;
        config.durationDays = 1095;
        config.variant = LoanFixtures.WindowVariant.Upper;
        config.currencyToken = USDC;
        config.twoTranches = false;
        config.useEscrowTimelock = false;
        config.feeSpecs = new ILoanRouterV2.FeeSpec[](0);
        config.approvalAddresses = new address[](0);

        /* Originate the loan */
        terms = originateConfigured(config);
    }

    /**
     * @notice Originate a single-tranche USDC loan and bring it current
     * @return terms Originated loan terms
     */
    function _originateSingleUsdc() internal returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        /* Originate the loan */
        terms = _originateSingleUsdcUnseasoned();

        /* Bring the borrower current so the loan is eligible to refinance */
        _seasonForRefinance(terms);
    }

    /**
     * @notice Build refinanced multi-tranche terms with new amounts, a shared rate, and a fee
     * @param oldTerms Old loan terms
     * @param newAmounts New tranche amounts, one per tranche
     * @param newRate New per-second rate scaled by 1e18 applied to every tranche
     * @param refinanceFee Flat refinance fee, zero for no fee
     * @return newTerms Refinanced loan terms
     */
    function _buildNewTermsMulti(
        ILoanRouterV2.LoanTermsV2 storage oldTerms,
        uint256[] memory newAmounts,
        uint256 newRate,
        uint256 refinanceFee
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory newTerms) {
        /* Deep copy the old terms into memory */
        newTerms = oldTerms;

        /* Rebuild the tranches keeping each lender and applying the new amount and rate */
        ILoanRouterV2.TrancheSpec[] memory tranches = new ILoanRouterV2.TrancheSpec[](newAmounts.length);
        for (uint256 i; i < newAmounts.length; i++) {
            tranches[i] = ILoanRouterV2.TrancheSpec({
                lender: oldTerms.trancheSpecs[i].lender, amount: newAmounts[i], rate: newRate
            });
        }
        newTerms.trancheSpecs = tranches;

        /* Attach the refinance fee spec or clear it when the fee is zero */
        if (refinanceFee == 0) {
            newTerms.feeSpecs = new ILoanRouterV2.FeeSpec[](0);
        } else {
            ILoanRouterV2.FeeSpec[] memory feeSpecs = new ILoanRouterV2.FeeSpec[](1);
            feeSpecs[0] = ILoanRouterV2.FeeSpec({
                kind: ILoanRouterV2.FeeKind.Refinance,
                recipient: address(0),
                model: address(absoluteFeeModel),
                options: abi.encode(AbsoluteFeeModel.Options({amount: refinanceFee}))
            });
            newTerms.feeSpecs = feeSpecs;
        }

        /* Keep the new offer valid */
        newTerms.expiration = uint64(block.timestamp + 30 days);
    }

    /**
     * @notice Assert the new loan is active with the expected balance and the old schedule carried over
     * @param newTerms Refinanced loan terms
     * @param expectedBalance Expected scaled balance
     * @param expectedCount Repayment count carried from the old loan
     * @param expectedOrigination Origination timestamp carried from the old loan
     */
    function _assertNewLoanState(
        ILoanRouterV2.LoanTermsV2 memory newTerms,
        uint256 expectedBalance,
        uint16 expectedCount,
        uint64 expectedOrigination
    ) internal view {
        /* Read the new loan state */
        (ILoanRouterV2.LoanStatus status, uint16 count, uint64 origination, uint256 balance) =
            router.loanState(router.loanTermsHash(newTerms));

        /* New loan is active */
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active), "new loan not active");

        /* Balance equals the new principal */
        assertEq(balance, expectedBalance, "balance changed");

        /* Repayment count carries over from the old loan */
        assertEq(count, expectedCount, "repayment count not carried");

        /* Origination timestamp carries over from the old loan */
        assertEq(origination, expectedOrigination, "origination not carried");

        /* Schedule still runs from the original origination timestamp */
        uint64[] memory scheduleAfter = router.deadlines(newTerms);

        uint64[] memory scheduleExpected = _scheduleAt(newTerms, expectedOrigination);

        assertEq(scheduleAfter.length, scheduleExpected.length, "schedule length changed");

        /* Every deadline matches the preserved schedule */
        for (uint256 i; i < scheduleExpected.length; i++) {
            assertEq(scheduleAfter[i], scheduleExpected[i], "deadline mismatch");
        }
    }
}
