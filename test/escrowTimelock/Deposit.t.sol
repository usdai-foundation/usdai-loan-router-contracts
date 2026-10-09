// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IEscrowTimelock} from "src/interfaces/IEscrowTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EscrowTimelockDepositTest is BaseTest {
    event Deposited(address indexed target, bytes32 indexed context, uint256 amount, uint256 interestRate);

    /*------------------------------------------------------------------------*/
    /* Test: deposit */
    /*------------------------------------------------------------------------*/

    function test__Deposit_Success() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18; // 100k USDai
        uint256 interestRate = RATE_10_PCT; // 10% APR

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        uint256 escrowAdminBalanceBefore = IERC20(USDAI).balanceOf(users.admin);

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);
        vm.stopPrank();

        // Verify deposit info
        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (address target_, bytes32 context_, uint256 amount_, uint256 rate_, uint64 timestamp_, uint256 interest_) =
            escrowTimelock.depositInfo(tokenId);

        assertEq(target_, target, "Target should match");
        assertEq(context_, context, "Context should match");
        assertEq(amount_, amount, "Amount should match");
        assertEq(rate_, interestRate, "Interest rate should match");
        assertEq(timestamp_, uint64(block.timestamp), "Timestamp should be current block");
        assertEq(interest_, 0, "Interest should be 0 at deposit time");

        // Verify USDai transferred from sUSDai to escrowAdmin
        assertEq(susdaiBalanceBefore - IERC20(USDAI).balanceOf(STAKED_USDAI), amount, "USDai should leave sUSDai");
        assertEq(
            IERC20(USDAI).balanceOf(users.admin) - escrowAdminBalanceBefore,
            amount,
            "USDai should arrive at escrowAdmin"
        );

        // Verify receipt token was minted to depositor
        assertEq(escrowTimelock.ownerOf(tokenId), STAKED_USDAI, "Receipt NFT should be owned by sUSDai");
    }

    function test__Deposit_VerifyAccrualState() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        // At deposit time, accrued should be 0
        assertEq(escrowTimelock.accrued(), 0, "Accrued should be 0 immediately after deposit");

        // After some time, accrued should increase
        vm.warp(block.timestamp + 30 days);

        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 30 days);
        assertEq(escrowTimelock.accrued(), expectedInterest, "Accrued should match expected interest");
    }

    function test__Deposit_MultipleDeposits_DifferentContexts() public {
        address target = address(loanRouter);
        bytes32 context1 = keccak256("context-1");
        bytes32 context2 = keccak256("context-2");
        uint256 amount1 = 100_000 * 1e18;
        uint256 amount2 = 50_000 * 1e18;
        uint256 rate1 = RATE_8_PCT;
        uint256 rate2 = RATE_12_PCT;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context1, USDAI, amount1, rate1);
        escrowTimelock.deposit(target, context2, USDAI, amount2, rate2);
        vm.stopPrank();

        // Verify both deposits exist independently
        (,, uint256 dep1Amount, uint256 dep1Rate,,) =
            escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context1));
        (,, uint256 dep2Amount, uint256 dep2Rate,,) =
            escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context2));

        assertEq(dep1Amount, amount1, "Deposit 1 amount should match");
        assertEq(dep1Rate, rate1, "Deposit 1 rate should match");
        assertEq(dep2Amount, amount2, "Deposit 2 amount should match");
        assertEq(dep2Rate, rate2, "Deposit 2 rate should match");

        // Verify aggregate accrual after time passes
        vm.warp(block.timestamp + 365 days);

        uint256 expected1 = calculateExpectedInterest(amount1, rate1, 365 days);
        uint256 expected2 = calculateExpectedInterest(amount2, rate2, 365 days);
        assertEq(escrowTimelock.accrued(), expected1 + expected2, "Accrued should be sum of both deposits");
    }

    /*------------------------------------------------------------------------*/
    /* Test: deposit failures */
    /*------------------------------------------------------------------------*/

    function test__Deposit_RevertWhen_NotStakedUSDai() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(users.lender1);
        vm.expectRevert(IEscrowTimelock.InvalidCaller.selector);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroTarget() public {
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidAddress.selector);
        escrowTimelock.deposit(address(0), context, USDAI, amount, RATE_10_PCT);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroContext() public {
        address target = address(loanRouter);
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidBytes32.selector);
        escrowTimelock.deposit(target, bytes32(0), USDAI, amount, RATE_10_PCT);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_ZeroAmount() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidAmount.selector);
        escrowTimelock.deposit(target, context, USDAI, 0, RATE_10_PCT);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_AlreadyExists() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);
        vm.stopPrank();
    }

    function test__Deposit_RevertWhen_UnsupportedToken() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.UnsupportedToken.selector);
        escrowTimelock.deposit(target, context, USDC, amount, RATE_10_PCT);
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Test: depositInfo getter */
    /*------------------------------------------------------------------------*/

    function test__DepositInfo_NonExistent() public view {
        address target = address(loanRouter);
        bytes32 context = keccak256("nonexistent");
        uint256 tokenId = escrowTimelock.depositTokenId(target, context);

        (address t, bytes32 c, uint256 a, uint256 r, uint64 ts, uint256 i) = escrowTimelock.depositInfo(tokenId);

        assertEq(t, address(0), "Target should be zero");
        assertEq(c, bytes32(0), "Context should be zero");
        assertEq(a, 0, "Amount should be zero");
        assertEq(r, 0, "Rate should be zero");
        assertEq(ts, 0, "Timestamp should be zero");
        assertEq(i, 0, "Interest should be zero");
    }

    function test__DepositInfo_WithAccruedInterest() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);

        vm.warp(block.timestamp + 365 days);

        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (,,,,, uint256 interest) = escrowTimelock.depositInfo(tokenId);

        uint256 expectedInterest = calculateExpectedInterest(amount, interestRate, 365 days);
        assertEq(interest, expectedInterest, "Interest should match expected after 1 year");

        // ~10% of 100k = ~10k USDai
        assertGt(interest, 9_900 * 1e18, "Interest should be approximately 10k USDai");
        assertLt(interest, 10_100 * 1e18, "Interest should be approximately 10k USDai");
    }

    /*------------------------------------------------------------------------*/
    /* Test: interest rate boundary */
    /*------------------------------------------------------------------------*/

    function test__Deposit_RevertWhen_InterestRateExceedsMaximum() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("rate-too-high");
        uint256 amount = 100_000 * 1e18;

        vm.startPrank(STAKED_USDAI);
        vm.expectRevert(IEscrowTimelock.InvalidAmount.selector);
        escrowTimelock.deposit(target, context, USDAI, amount, MAX_INTEREST_RATE + 1);
        vm.stopPrank();
    }

    function test__Deposit_AtInterestRateBoundary_ExactlyMaximum() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("rate-at-boundary");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, MAX_INTEREST_RATE);

        uint256 tokenId = escrowTimelock.depositTokenId(target, context);
        (,,, uint256 rate_,,) = escrowTimelock.depositInfo(tokenId);
        assertEq(rate_, MAX_INTEREST_RATE, "Rate should be exactly the maximum");
        assertEq(escrowTimelock.accrued(), 0, "Accrued is 0 at the deposit instant");
    }

    /*------------------------------------------------------------------------*/
    /* Test: event emission */
    /*------------------------------------------------------------------------*/

    function test__Deposit_EmitsDepositedEvent() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("event-test");
        uint256 amount = 100_000 * 1e18;
        uint256 interestRate = RATE_10_PCT;

        vm.expectEmit(true, true, true, true, address(escrowTimelock));
        emit Deposited(target, context, amount, interestRate);

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, interestRate);
    }

    /*------------------------------------------------------------------------*/
    /* Test: aggregate accounting */
    /*------------------------------------------------------------------------*/

    function test__Deposit_VerifyTotalDepositsAccumulation() public {
        address target = address(loanRouter);
        uint256 a1 = 100_000 * 1e18;
        uint256 a2 = 50_000 * 1e18;
        uint256 a3 = 25_000 * 1e18;

        assertEq(escrowTimelock.totalDeposits(), 0, "totalDeposits starts at zero");

        vm.startPrank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("a"), USDAI, a1, RATE_8_PCT);
        assertEq(escrowTimelock.totalDeposits(), a1, "totalDeposits after first deposit");

        escrowTimelock.deposit(target, keccak256("b"), USDAI, a2, RATE_10_PCT);
        assertEq(escrowTimelock.totalDeposits(), a1 + a2, "totalDeposits after second deposit");

        escrowTimelock.deposit(target, keccak256("c"), USDAI, a3, RATE_12_PCT);
        assertEq(escrowTimelock.totalDeposits(), a1 + a2 + a3, "totalDeposits after third deposit");
        vm.stopPrank();
    }

    function test__Deposit_VerifyAccrualRateIncrement() public {
        address target = address(loanRouter);
        uint256 a1 = 100_000 * 1e18;
        uint256 a2 = 50_000 * 1e18;
        uint256 r = RATE_10_PCT;
        uint256 window = 30 days;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("first"), USDAI, a1, r);

        warp(window);
        uint256 firstWindow = (a1 * r * window) / FIXED_POINT_SCALE;
        assertEq(escrowTimelock.accrued(), firstWindow, "Accrual after first deposit and one window");

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, keccak256("second"), USDAI, a2, r);

        warp(window);
        uint256 expected = firstWindow + ((a1 + a2) * r * window) / FIXED_POINT_SCALE;
        assertEq(escrowTimelock.accrued(), expected, "Accrual rate increment is additive across deposits");
    }

    function test__Deposit_RevertWhen_DepositorBalanceInsufficient() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("balance-test");
        uint256 amount = 100_000 * 1e18;

        // Drain the depositor's USDai balance
        deal(USDAI, STAKED_USDAI, 0);

        // deposit() pulls funds via SafeERC20.transferFrom; the failure originates inside the USDai ERC20
        // implementation whose selector is not exposed by our contracts, so the bare expectRevert is
        // intentional. The totalDeposits assertion below confirms no state mutation slipped through.
        uint256 totalDepositsBefore = escrowTimelock.totalDeposits();
        vm.startPrank(STAKED_USDAI);
        vm.expectRevert();
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);
        vm.stopPrank();
        assertEq(escrowTimelock.totalDeposits(), totalDepositsBefore, "Deposit must not commit state on revert");
    }

    /*------------------------------------------------------------------------*/
    /* Test: ERC721 transfers */
    /*------------------------------------------------------------------------*/

    function test__ERC721Transfers_Disabled() public {
        address target = address(loanRouter);
        bytes32 context = keccak256("test-context");
        uint256 amount = 100_000 * 1e18;

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, amount, RATE_10_PCT);

        uint256 tokenId = escrowTimelock.depositTokenId(target, context);

        vm.startPrank(STAKED_USDAI);

        vm.expectRevert();
        escrowTimelock.approve(users.lender1, tokenId);

        vm.expectRevert();
        escrowTimelock.transferFrom(STAKED_USDAI, users.lender1, tokenId);

        vm.expectRevert();
        escrowTimelock.safeTransferFrom(STAKED_USDAI, users.lender1, tokenId, "");

        vm.stopPrank();
    }
}
