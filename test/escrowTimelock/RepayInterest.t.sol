// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {BaseTest} from "../Base.t.sol";
import {IEscrowTimelock} from "src/interfaces/IEscrowTimelock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {EscrowTimelockHooksMock} from "../mocks/EscrowTimelockHooksMock.sol";

contract EscrowTimelockRepayInterestTest is BaseTest {
    event InterestRepaid(address indexed target, bytes32 indexed context, uint256 interest);

    address internal target;
    bytes32 internal context = keccak256("test-context");
    uint256 internal constant AMOUNT = 100_000 * 1e18;

    function setUp() public override {
        super.setUp();

        target = address(loanRouter);

        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(target, context, USDAI, AMOUNT, RATE_10_PCT);

        vm.warp(block.timestamp + 30 days);
    }

    /*------------------------------------------------------------------------*/
    /* Test: repayInterest */
    /*------------------------------------------------------------------------*/

    function test__RepayInterest_Success() public {
        uint256 owed = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days);
        uint256 repay = owed / 3;

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        vm.expectEmit(true, true, false, true, address(escrowTimelock));
        emit InterestRepaid(target, context, repay);

        vm.prank(users.admin);
        uint256 repaid = escrowTimelock.repayInterest(target, context, repay);

        assertEq(repaid, repay, "Returns repaid amount");
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore, repay, "Depositor receives repayment");
        assertEq(escrowTimelock.accrued(), owed - repay, "Accrued drops by repayment");

        (,,,,, uint256 interestOwed) = escrowTimelock.depositInfo(escrowTimelock.depositTokenId(target, context));
        assertEq(interestOwed, owed - repay, "depositInfo shows remaining interest");
    }

    function test__RepayInterest_CancelPaysRemainder() public {
        uint256 owed = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days);
        uint256 repay = owed / 2;

        vm.prank(users.admin);
        escrowTimelock.repayInterest(target, context, repay);

        vm.prank(STAKED_USDAI);
        (, uint256 interest) = escrowTimelock.cancel(target, context);

        assertEq(interest, owed - repay, "Cancel pays the remainder");
        assertEq(escrowTimelock.accrued(), 0, "Accrued is zero after cancel");
    }

    function test__RepayInterest_WithdrawPaysRemainder() public {
        uint256 owed = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days);

        vm.prank(users.admin);
        escrowTimelock.repayInterest(target, context, owed);

        vm.prank(target);
        (, uint256 interest) = escrowTimelock.withdraw(context, USDAI, AMOUNT);

        assertEq(interest, 0, "Withdraw pays nothing after full repayment");
        assertEq(escrowTimelock.accrued(), 0, "Accrued is zero after withdraw");
    }

    function test__RepayInterest_ClampsToOwed() public {
        uint256 owed = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days);

        uint256 susdaiBalanceBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);

        vm.expectEmit(true, true, false, true, address(escrowTimelock));
        emit InterestRepaid(target, context, owed);

        vm.prank(users.admin);
        uint256 repaid = escrowTimelock.repayInterest(target, context, owed + 1);

        assertEq(repaid, owed, "Returns clamped amount");
        assertEq(IERC20(USDAI).balanceOf(STAKED_USDAI) - susdaiBalanceBefore, owed, "Repayment clamps to owed");
        assertEq(escrowTimelock.accrued(), 0, "Nothing left accrued");
    }

    function test__RepayInterest_RevertWhen_ZeroAmount() public {
        vm.expectRevert(IEscrowTimelock.InvalidAmount.selector);
        vm.prank(users.admin);
        escrowTimelock.repayInterest(target, context, 0);
    }

    function test__RepayInterest_RevertWhen_NotEscrowAdmin() public {
        vm.expectRevert(IEscrowTimelock.InvalidCaller.selector);
        vm.prank(STAKED_USDAI);
        escrowTimelock.repayInterest(target, context, 1);
    }

    function test__RepayInterest_RevertWhen_InvalidDeposit() public {
        vm.expectRevert(IEscrowTimelock.InvalidDeposit.selector);
        vm.prank(users.admin);
        escrowTimelock.repayInterest(target, keccak256("other"), 1);
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _deployEscrowWithMock(
        EscrowTimelockHooksMock.Mode mode
    ) private returns (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) {
        /* Deploy hook mock */
        mock = new EscrowTimelockHooksMock(mode);

        /* Deploy escrow with the mock as depositor */
        vm.startPrank(users.deployer);

        EscrowTimelock impl = new EscrowTimelock(USDAI, address(mock), users.admin);

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), address(users.admin), abi.encodeWithSignature("initialize(address)", users.deployer)
        );

        hookEscrow = EscrowTimelock(address(proxy));

        vm.stopPrank();

        /* Fund the mock with USDai */
        deal(USDAI, address(mock), 1_000_000 * 1e18);

        /* Have the mock approve the new escrow */
        mock.approveSpender(USDAI, address(hookEscrow), type(uint256).max);

        /* Have the escrow admin approve the new escrow */
        vm.prank(users.admin);
        IERC20(USDAI).approve(address(hookEscrow), type(uint256).max);
    }

    /*------------------------------------------------------------------------*/
    /* Test: hook callback */
    /*------------------------------------------------------------------------*/

    function test__RepayInterest_InvokesHookCallback_OnConformingDepositor() public {
        /* Deploy escrow with recording mock */
        (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) =
            _deployEscrowWithMock(EscrowTimelockHooksMock.Mode.Record);

        /* Set deposit context */
        bytes32 hookContext = keccak256("hook-repay");

        /* Deposit from the mock */
        vm.prank(address(mock));
        hookEscrow.deposit(target, hookContext, USDAI, AMOUNT, RATE_10_PCT);

        /* Move time forward */
        vm.warp(block.timestamp + 30 days);

        /* Compute repayment amount */
        uint256 repay = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days) / 2;

        /* Record mock balance */
        uint256 mockBalanceBefore = IERC20(USDAI).balanceOf(address(mock));

        /* Repay interest as escrow admin */
        vm.prank(users.admin);
        hookEscrow.repayInterest(target, hookContext, repay);

        /* Check hook call count */
        assertEq(mock.callCount(), 1, "Hook invoked once");

        /* Read last hook call */
        (
            address recordedTarget,
            bytes32 recordedContext,
            address recordedToken,
            uint256 recordedAmount,
            uint256 recordedInterest
        ) = mock.lastCall();

        /* Check hook parameters */
        assertEq(recordedTarget, target, "hook target param");
        assertEq(recordedContext, hookContext, "hook context param");
        assertEq(recordedToken, USDAI, "hook token param");
        assertEq(recordedAmount, 0, "hook amount param");
        assertEq(recordedInterest, repay, "hook interest param");

        /* Check mock received repayment */
        assertEq(IERC20(USDAI).balanceOf(address(mock)) - mockBalanceBefore, repay, "Mock receives repayment");
    }

    function test__RepayInterest_SkipsHook_WhenInterfaceDisabled() public {
        /* Deploy escrow with interface disabled mock */
        (EscrowTimelock hookEscrow, EscrowTimelockHooksMock mock) =
            _deployEscrowWithMock(EscrowTimelockHooksMock.Mode.DisableInterface);

        /* Set deposit context */
        bytes32 hookContext = keccak256("hook-repay");

        /* Deposit from the mock */
        vm.prank(address(mock));
        hookEscrow.deposit(target, hookContext, USDAI, AMOUNT, RATE_10_PCT);

        /* Move time forward */
        vm.warp(block.timestamp + 30 days);

        /* Compute repayment amount */
        uint256 repay = calculateExpectedInterest(AMOUNT, RATE_10_PCT, 30 days) / 2;

        /* Record mock balance */
        uint256 mockBalanceBefore = IERC20(USDAI).balanceOf(address(mock));

        /* Repay interest as escrow admin */
        vm.prank(users.admin);
        hookEscrow.repayInterest(target, hookContext, repay);

        /* Check hook was skipped */
        assertEq(mock.callCount(), 0, "Hook not invoked");

        /* Check mock received repayment */
        assertEq(IERC20(USDAI).balanceOf(address(mock)) - mockBalanceBefore, repay, "Mock receives repayment");
    }
}
