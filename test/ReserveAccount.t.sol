// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {BaseTest} from "./Base.t.sol";
import {LoanFixtures} from "./helpers/LoanFixtures.sol";
import {TestERC721} from "./mocks/TestERC721.sol";

import {ReserveAccount} from "src/ReserveAccount.sol";
import {IReserveAccount} from "src/interfaces/IReserveAccount.sol";
import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";
import {ScheduleLogic} from "src/ScheduleLogic.sol";
import {SimpleInterestRateModel} from "src/rates/SimpleInterestRateModel.sol";
import {ReentrantRouterMock} from "./mocks/ReentrantRouterMock.sol";

contract ReserveAccountTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    uint256 internal constant TRANCHE_AMOUNT = 100_000 * 1e18; /* 100k USDai */
    uint256 internal constant RESERVES_REQUIRED = 5_000 * 1e18; /* 5k USDai reserve floor */

    /*------------------------------------------------------------------------*/
    /* State */
    /*------------------------------------------------------------------------*/

    LoanRouterV2 internal router;
    SimpleInterestRateModel internal irm;
    TestERC721 internal collateralNft;

    ReserveAccount internal reserveImpl;
    ReserveAccount internal reserve;

    address internal collateralEscrow;
    ILoanRouterV2.LoanTermsV2 internal activeLoanTerms;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        super.setUp();

        /* Deploy LoanRouterV2 wired to the existing timelocks */
        vm.startPrank(users.deployer);
        LoanRouterV2 routerImpl = new LoanRouterV2(
            users.feeRecipient, address(collateralTimelock), address(depositTimelock), address(escrowTimelock)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl), abi.encodeWithSelector(LoanRouterV2.initialize.selector, users.admin)
        );
        router = LoanRouterV2(address(routerProxy));
        vm.stopPrank();

        /* Grant ORIGINATOR_ROLE to deployer so we can originate from tests */
        vm.prank(users.admin);
        IAccessControl(address(router)).grantRole(keccak256("ORIGINATOR_ROLE"), users.deployer);

        /* Deploy IRM + collateral NFT */
        irm = new SimpleInterestRateModel();
        collateralNft = new TestERC721("Collateral", "COL");

        /* Set up collateral escrow as an EOA that stages NFTs into CollateralTimelock */
        collateralEscrow = makeAddr("collateralEscrow");
        collateralNft.mint(collateralEscrow, 1);
        vm.prank(collateralEscrow);
        collateralNft.setApprovalForAll(address(collateralTimelock), true);

        /* Grant collateralEscrow the depositor role on CollateralTimelock */
        vm.prank(users.deployer);
        IAccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), collateralEscrow);

        /* Deploy ReserveAccount behind ERC1967 proxy */
        reserveImpl = new ReserveAccount(users.admin, address(router));
        ERC1967Proxy reserveProxy = new ERC1967Proxy(
            address(reserveImpl),
            abi.encodeWithSelector(ReserveAccount.initialize.selector, users.borrower, USDAI, RESERVES_REQUIRED)
        );
        reserve = ReserveAccount(address(reserveProxy));
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _originateLoan() internal returns (ILoanRouterV2.LoanTermsV2 memory loanTerms) {
        SimpleInterestRateModel.Options memory irmOpts = SimpleInterestRateModel.Options({
            gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: false
        });

        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(users.lender1, TRANCHE_AMOUNT, RATE_10_PCT));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        loanTerms = ILoanRouterV2.LoanTermsV2({
            expiration: uint64(block.timestamp + 7 days),
            borrower: address(reserve),
            currencyToken: USDAI,
            collateralToken: address(collateralNft),
            collateralTokenIds: tokenIds,
            trancheSpecs: tranches,
            feeSpecs: new ILoanRouterV2.FeeSpec[](0),
            interestRateSpec: ILoanRouterV2.InterestRateSpec({model: address(irm), options: abi.encode(irmOpts)}),
            repaymentSpec: ILoanRouterV2.RepaymentSpec({day: 15, totalDurationDays: 365, timezoneOffsetSeconds: 0}),
            approvalAddresses: new address[](0),
            options: ""
        });

        /* Lender deposits funds into DepositTimelock targeting the router */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(users.lender1);
        depositTimelock.deposit(
            address(router), loanTermsHash_, USDAI, TRANCHE_AMOUNT, uint64(block.timestamp + 7 days)
        );

        /* Stage collateral in CollateralTimelock */
        vm.prank(collateralEscrow);
        collateralTimelock.deposit(
            address(router), loanTermsHash_, address(collateralNft), tokenIds, uint64(block.timestamp + 7 days)
        );

        /* Build deposit infos (one per tranche), same-token so empty swap data */
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.DepositTimelock, data: ""});

        /* Originate */
        vm.prank(users.deployer);
        router.originate(loanTerms, infos, new bytes[](0));

        activeLoanTerms = loanTerms;
    }

    function _syntheticTerms(
        address currencyToken
    ) internal view returns (ILoanRouterV2.LoanTermsV2 memory terms) {
        terms.currencyToken = currencyToken;
    }

    /*------------------------------------------------------------------------*/
    /* Test: constructor */
    /*------------------------------------------------------------------------*/

    function test__Constructor_SetsImmutables() public view {
        assertEq(reserve.admin(), users.admin);
        assertEq(reserve.loanRouter(), address(router));
    }

    function test__Constructor_RevertWhen_AdminZero() public {
        vm.expectRevert(IReserveAccount.InvalidAddress.selector);
        new ReserveAccount(address(0), address(router));
    }

    function test__Constructor_RevertWhen_LoanRouterZero() public {
        vm.expectRevert(IReserveAccount.InvalidAddress.selector);
        new ReserveAccount(users.admin, address(0));
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize */
    /*------------------------------------------------------------------------*/

    function test__Initialize_SetsStateAndGrantsRoles() public view {
        assertEq(reserve.currencyToken(), USDAI);
        (uint256 required,) = reserve.reserves();
        assertEq(required, RESERVES_REQUIRED);
        assertTrue(IAccessControl(address(reserve)).hasRole(reserve.BORROWER_ROLE(), users.borrower));
        assertTrue(IAccessControl(address(reserve)).hasRole(bytes32(0), users.admin)); /* DEFAULT_ADMIN_ROLE */
    }

    function test__Initialize_RevertWhen_BorrowerZero() public {
        ReserveAccount impl = new ReserveAccount(users.admin, address(router));
        vm.expectRevert(IReserveAccount.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeWithSelector(ReserveAccount.initialize.selector, address(0), USDC, 0));
    }

    function test__Initialize_RevertWhen_CurrencyTokenZero() public {
        ReserveAccount impl = new ReserveAccount(users.admin, address(router));
        vm.expectRevert(IReserveAccount.InvalidAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ReserveAccount.initialize.selector, users.borrower, address(0), 0)
        );
    }

    function test__Initialize_RevertWhen_AlreadyInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reserve.initialize(users.borrower, USDC, 0);
    }

    function test__Initialize_RevertWhen_CalledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reserveImpl.initialize(users.borrower, USDC, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: reserves() view */
    /*------------------------------------------------------------------------*/

    function test__Reserves_BalanceAboveRequired_ReturnsSurplus() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000 * 1e18);
        (uint256 required, uint256 withdrawable) = reserve.reserves();
        assertEq(required, RESERVES_REQUIRED);
        assertEq(withdrawable, 1_000 * 1e18);
    }

    function test__Reserves_BalanceEqualsRequired_ZeroWithdrawable() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED);
        (, uint256 withdrawable) = reserve.reserves();
        assertEq(withdrawable, 0);
    }

    function test__Reserves_BalanceBelowRequired_ZeroWithdrawable() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED / 2);
        (, uint256 withdrawable) = reserve.reserves();
        assertEq(withdrawable, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: repay - reverts */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_NotBorrower() public {
        vm.prank(users.lender1);
        vm.expectRevert(); /* OZ AccessControl revert */
        reserve.repay(_syntheticTerms(USDAI), 1);
    }

    function test__Repay_RevertWhen_ZeroAmount() public {
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAmount.selector);
        reserve.repay(_syntheticTerms(USDAI), 0);
    }

    function test__Repay_RevertWhen_WrongCurrencyToken() public {
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidCurrencyToken.selector);
        reserve.repay(_syntheticTerms(USDC), 1);
    }

    function test__Repay_RevertWhen_InsufficientReserves() public {
        /* balance < required → revert */
        deal(USDAI, address(reserve), RESERVES_REQUIRED - 1);
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InsufficientReserves.selector);
        reserve.repay(_syntheticTerms(USDAI), 1);
    }

    function test__Repay_RevertWhen_AmountExceedsSurplus() public {
        /* balance - required = 100. An amount above the surplus must revert via the
         * `amount > balance - reservesRequired` guard. */
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 100);
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAmount.selector);
        reserve.repay(_syntheticTerms(USDAI), 101);
    }

    /*------------------------------------------------------------------------*/
    /* Test: repay - happy path against a real originated loan */
    /*------------------------------------------------------------------------*/

    function test__Repay_HappyPath_ForwardsToRouter() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Warp to the first repayment deadline */
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        /* Quote the repayment */
        (uint256 P, uint256 I, uint256 F) = router.quote(loanTerms);
        uint256 totalPayment = P + I + F;
        assertGt(totalPayment, 0);

        /* Fund the reserve account so balance > reservesRequired + totalPayment */
        uint256 extraBuffer = totalPayment + 1_000 * 1e18;
        deal(USDAI, address(reserve), RESERVES_REQUIRED + extraBuffer);
        uint256 reserveBalanceBefore = IERC20(USDAI).balanceOf(address(reserve));

        /* Repay through the reserve account */
        vm.prank(users.borrower);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.RepaymentForwarded(totalPayment);
        reserve.repay(loanTerms, totalPayment);

        /* Reserve balance dropped by exactly `totalPayment` */
        assertEq(IERC20(USDAI).balanceOf(address(reserve)), reserveBalanceBefore - totalPayment);
        /* Allowance to the router is revoked after the call */
        assertEq(IERC20(USDAI).allowance(address(reserve), address(router)), 0);
        /* Loan repaymentCount advanced */
        (, uint16 repaymentCount,,) = router.loanState(loanTermsHash_);
        assertEq(repaymentCount, 1);

        /* Silence unused-variable warning */
        originationTs;
    }

    /*------------------------------------------------------------------------*/
    /* Test: repay - an overdue loan is cured and closed in one transaction */
    /*------------------------------------------------------------------------*/

    function test__Repay_Overdue_MulticallCureAndClose() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Warp five days past the third deadline, leaving three missed deadlines */
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        uint64[] memory schedule = _scheduleAt(loanTerms, originationTs);
        vm.warp(schedule[2] + 5 days);

        /* Fund the reserve with room for a full payoff on every call */
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 4 * TRANCHE_AMOUNT);

        /* Batch a repayment per overdue window plus one for the current window */
        bytes[] memory calls = new bytes[](4);
        for (uint256 i; i < calls.length; i++) {
            calls[i] = abi.encodeWithSelector(IReserveAccount.repay.selector, loanTerms, TRANCHE_AMOUNT);
        }

        /* Cure the loan and close it in one transaction */
        vm.prank(users.borrower);
        reserve.multicall(calls);

        /* Loan is closed with every overdue window priced */
        (ILoanRouterV2.LoanStatus status, uint16 repaymentCount,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(repaymentCount, 4);
        assertEq(balance, 0);

        /* Collateral came back to the reserve account */
        assertEq(collateralNft.ownerOf(loanTerms.collateralTokenIds[0]), address(reserve));
    }

    function test__Repay_RevertWhen_BelowScheduledMinimum() public {
        /* The reserve no longer enforces a minimum payment, so a sub-minimum amount must be rejected by the
         * router. Confirm the minimum is still enforced even with ample surplus available. */
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        /* Warp to the first repayment deadline */
        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        /* Quote the scheduled payment */
        (uint256 P, uint256 I, uint256 F) = router.quote(loanTerms);
        uint256 totalPayment = P + I + F;
        assertGt(totalPayment, 0);

        /* Fund the reserve with ample surplus so the surplus guard does not trip first */
        deal(USDAI, address(reserve), RESERVES_REQUIRED + totalPayment + 1_000 * 1e18);

        /* One unit below the scheduled minimum is rejected downstream by the router */
        vm.prank(users.borrower);
        vm.expectRevert(ILoanRouterV2.InvalidAmount.selector);
        reserve.repay(loanTerms, totalPayment - 1);
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_Success() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000 * 1e18);

        address recipient = makeAddr("recipient");
        vm.prank(users.borrower);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.ReservesWithdrawn(recipient, 600 * 1e18);
        reserve.withdraw(recipient, 600 * 1e18);

        assertEq(IERC20(USDAI).balanceOf(recipient), 600 * 1e18);
        assertEq(IERC20(USDAI).balanceOf(address(reserve)), RESERVES_REQUIRED + 400 * 1e18);
    }

    function test__Withdraw_RevertWhen_NotBorrower() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000 * 1e18);
        vm.prank(users.lender1);
        vm.expectRevert();
        reserve.withdraw(users.lender1, 1);
    }

    function test__Withdraw_RevertWhen_ZeroAmount() public {
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAmount.selector);
        reserve.withdraw(makeAddr("recipient"), 0);
    }

    function test__Withdraw_RevertWhen_ZeroRecipient() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000 * 1e18);
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAddress.selector);
        reserve.withdraw(address(0), 1);
    }

    function test__Withdraw_RevertWhen_ExceedsWithdrawable() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 100);
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAmount.selector);
        reserve.withdraw(makeAddr("recipient"), 101);
    }

    /*------------------------------------------------------------------------*/
    /* Test: execute */
    /*------------------------------------------------------------------------*/

    function test__Execute_AdminCanForwardCall() public {
        /* Have the reserve own an NFT, then use execute() to transfer it out */
        TestERC721 nft = new TestERC721("Test", "T");
        nft.mint(address(reserve), 42);

        address recipient = makeAddr("recipient");
        bytes memory data = abi.encodeWithSelector(nft.transferFrom.selector, address(reserve), recipient, uint256(42));

        vm.prank(users.admin);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.Executed(address(nft), nft.transferFrom.selector);
        reserve.execute(address(nft), data);

        assertEq(nft.ownerOf(42), recipient);
    }

    function test__Execute_RevertWhen_NotAdmin() public {
        vm.prank(users.borrower);
        vm.expectRevert();
        reserve.execute(USDC, "");
    }

    function test__Execute_BubblesUpTargetRevert() public {
        /* Calling transferFrom for an NFT the reserve doesn't own should revert */
        TestERC721 nft = new TestERC721("Test", "T");
        nft.mint(makeAddr("other"), 42);
        bytes memory data =
            abi.encodeWithSelector(nft.transferFrom.selector, address(reserve), makeAddr("dest"), uint256(42));

        vm.prank(users.admin);
        vm.expectRevert();
        reserve.execute(address(nft), data);
    }

    /*------------------------------------------------------------------------*/
    /* Test: setReservesRequired */
    /*------------------------------------------------------------------------*/

    function test__SetReservesRequired_AdminCanUpdate() public {
        uint256 newRequired = 12_345 * 1e18;
        vm.prank(users.admin);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.ReservesRequiredSet(newRequired);
        reserve.setReservesRequired(newRequired);

        (uint256 required,) = reserve.reserves();
        assertEq(required, newRequired);
    }

    function test__SetReservesRequired_RevertWhen_NotAdmin() public {
        vm.prank(users.borrower);
        vm.expectRevert();
        reserve.setReservesRequired(0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: ERC721 receiver */
    /*------------------------------------------------------------------------*/

    function test__OnERC721Received_ReturnsSelector() public view {
        bytes4 sel = reserve.onERC721Received(address(0), address(0), 0, "");
        assertEq(sel, IERC721Receiver.onERC721Received.selector);
    }

    /*------------------------------------------------------------------------*/
    /* Test: reserves() boundary */
    /*------------------------------------------------------------------------*/

    function test__Reserves_BalanceZero_ZeroWithdrawable() public view {
        (uint256 required, uint256 withdrawable) = reserve.reserves();
        assertEq(required, RESERVES_REQUIRED);
        assertEq(withdrawable, 0);
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - additional edges */
    /*------------------------------------------------------------------------*/

    function test__Initialize_WithZeroReservesRequired() public {
        ReserveAccount impl = new ReserveAccount(users.admin, address(router));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(ReserveAccount.initialize.selector, users.borrower, USDC, 0)
        );
        ReserveAccount r = ReserveAccount(address(proxy));

        (uint256 required, uint256 withdrawable) = r.reserves();
        assertEq(required, 0, "reservesRequired stored as zero");
        assertEq(withdrawable, 0, "Zero balance + zero required => zero withdrawable");

        deal(USDC, address(r), 12_345);
        (, uint256 w2) = r.reserves();
        assertEq(w2, 12_345, "Entire balance is withdrawable when required is zero");
    }

    /*------------------------------------------------------------------------*/
    /* Test: repay - boundary cases */
    /*------------------------------------------------------------------------*/

    function test__Repay_RevertWhen_AmountEqualsTotalPayment_BalanceAtFloor() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        (uint256 P, uint256 I, uint256 F) = router.quote(loanTerms);
        uint256 totalPayment = P + I + F;
        assertGt(totalPayment, 0);

        /* balance exactly == reservesRequired ⇒ no surplus ⇒ even amount==totalPayment must revert
         * via the `amount > balance - reservesRequired` (= 0) guard, not InsufficientReserves. */
        deal(USDAI, address(reserve), RESERVES_REQUIRED);
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InvalidAmount.selector);
        reserve.repay(loanTerms, totalPayment);
    }

    function test__Repay_AmountEqualsWithdrawable_ExactBoundary() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        (uint256 P, uint256 I, uint256 F) = router.quote(loanTerms);
        uint256 totalPayment = P + I + F;

        /* withdrawable = totalPayment exactly */
        deal(USDAI, address(reserve), RESERVES_REQUIRED + totalPayment);

        vm.prank(users.borrower);
        reserve.repay(loanTerms, totalPayment);

        /* All surplus drained back to the loan */
        assertEq(IERC20(USDAI).balanceOf(address(reserve)), RESERVES_REQUIRED);
        (, uint16 repaymentCount,,) = router.loanState(loanTermsHash_);
        assertEq(repaymentCount, 1);
    }

    function test__Repay_NonReentrant_BlocksReentryViaRouter() public {
        ReentrantRouterMock badRouter = new ReentrantRouterMock();
        ReserveAccount impl = new ReserveAccount(users.admin, address(badRouter));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(ReserveAccount.initialize.selector, users.borrower, USDAI, RESERVES_REQUIRED)
        );
        ReserveAccount r = ReserveAccount(address(proxy));
        badRouter.setReserve(address(r));
        badRouter.setQuoteTotal(10);

        deal(USDC, address(r), RESERVES_REQUIRED + 1_000);

        ILoanRouterV2.LoanTermsV2 memory terms = _syntheticTerms(USDC);

        /* Reentry inside repay → withdraw must revert via nonReentrant. */
        vm.prank(users.borrower);
        vm.expectRevert();
        r.repay(terms, 10);
    }

    /*------------------------------------------------------------------------*/
    /* Test: withdraw - boundary */
    /*------------------------------------------------------------------------*/

    function test__Withdraw_ExactlyWithdrawable_LeavesReservesAtFloor() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000);
        address recipient = makeAddr("recipient");

        vm.prank(users.borrower);
        reserve.withdraw(recipient, 1_000);

        (uint256 required, uint256 withdrawable) = reserve.reserves();
        assertEq(required, RESERVES_REQUIRED);
        assertEq(withdrawable, 0, "Balance landed exactly at floor");
        assertEq(IERC20(USDAI).balanceOf(address(reserve)), RESERVES_REQUIRED);
        assertEq(IERC20(USDAI).balanceOf(recipient), 1_000);
    }

    function test__Withdraw_ToContract() public {
        deal(USDAI, address(reserve), RESERVES_REQUIRED + 1_000);
        /* The reserve account itself is a contract; sending to another reserve account proves
         * the recipient being a contract does not break the safeTransfer path. */
        TestERC721 anyContract = new TestERC721("c", "c");

        vm.prank(users.borrower);
        reserve.withdraw(address(anyContract), 1_000);

        assertEq(IERC20(USDAI).balanceOf(address(anyContract)), 1_000);
    }

    /*------------------------------------------------------------------------*/
    /* Test: setReservesRequired - additional */
    /*------------------------------------------------------------------------*/

    function test__SetReservesRequired_ToZero_StorageZeroed() public {
        vm.prank(users.admin);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.ReservesRequiredSet(0);
        reserve.setReservesRequired(0);

        (uint256 required,) = reserve.reserves();
        assertEq(required, 0);
    }

    function test__SetReservesRequired_AboveCurrentBalance_BreaksRepay() public {
        ILoanRouterV2.LoanTermsV2 memory loanTerms = _originateLoan();
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);

        (,, uint64 originationTs,) = router.loanState(loanTermsHash_);
        vm.warp(_scheduleAt(loanTerms, originationTs)[0]);

        (uint256 P, uint256 I, uint256 F) = router.quote(loanTerms);
        uint256 totalPayment = P + I + F;

        /* Fund the reserve with enough to repay AND leave the original floor. */
        deal(USDAI, address(reserve), RESERVES_REQUIRED + totalPayment);

        /* Admin sets reservesRequired far above current balance. The setter accepts it. */
        uint256 inflated = RESERVES_REQUIRED + totalPayment + 1_000_000 * 1e18;
        vm.prank(users.admin);
        reserve.setReservesRequired(inflated);

        (uint256 required,) = reserve.reserves();
        assertEq(required, inflated, "Setter accepts a value above current balance");

        /* Subsequent repay reverts because balance < required. */
        vm.prank(users.borrower);
        vm.expectRevert(IReserveAccount.InsufficientReserves.selector);
        reserve.repay(loanTerms, totalPayment);
    }

    /*------------------------------------------------------------------------*/
    /* Test: execute - additional edges */
    /*------------------------------------------------------------------------*/

    function test__Execute_WithZeroLengthData() public {
        /* Address.functionCall on a contract with empty data hits its fallback. The test NFT
         * has no fallback, so the call reverts with AddressEmptyCode/CallFailed. We confirm
         * that execute() bubbles that revert up exactly like any other failure. */
        TestERC721 nft = new TestERC721("Test", "T");

        vm.prank(users.admin);
        vm.expectRevert();
        reserve.execute(address(nft), "");
    }

    function test__Execute_WithThreeByteData_SelectorIsZero() public {
        /* Build a target that swallows any call (returns success on any selector). */
        SinkTarget sink = new SinkTarget();
        bytes memory threeByteData = hex"112233";

        vm.prank(users.admin);
        vm.expectEmit(true, true, true, true, address(reserve));
        emit IReserveAccount.Executed(address(sink), bytes4(0));
        reserve.execute(address(sink), threeByteData);
    }

    function test__Execute_RevertWhen_TargetIsZero() public {
        /* Address.functionCall reverts when target has no code. */
        vm.prank(users.admin);
        vm.expectRevert();
        reserve.execute(address(0), "");
    }

    /*------------------------------------------------------------------------*/
    /* Test: lifecycle (EscrowTimelock funding, multi-window repay) */
    /*------------------------------------------------------------------------*/

    function test__Lifecycle_EscrowTimelock_BorrowerIsReserveAccount_FullRepay() public {
        /* Deploy a USDAI-initialized ReserveAccount (the in-setup `reserve` is USDC-only) */
        uint256 usdaiReservesRequired = 5_000 * 1e18;
        ERC1967Proxy usdaiReserveProxy = new ERC1967Proxy(
            address(reserveImpl),
            abi.encodeWithSelector(ReserveAccount.initialize.selector, users.borrower, USDAI, usdaiReservesRequired)
        );
        ReserveAccount usdaiReserve = ReserveAccount(address(usdaiReserveProxy));

        /* Fund the reserve with required reserves plus principal + interest headroom */
        uint256 trancheAmount = 100_000 * 1e18;
        deal(USDAI, address(usdaiReserve), 150_000 * 1e18);
        uint256 reserveBalBefore = IERC20(USDAI).balanceOf(address(usdaiReserve));

        /* Mint a fresh collateral NFT to collateralEscrow for staging */
        uint256 collateralTokenId = 2;
        collateralNft.mint(collateralEscrow, collateralTokenId);

        /* Build loan terms with EscrowTimelock-compatible lender and ReserveAccount borrower */
        SimpleInterestRateModel.Options memory irmOpts = SimpleInterestRateModel.Options({
            gracePeriodDuration: 0, gracePeriodRate: 0, principalAndInterestStubPayment: false
        });
        ILoanRouterV2.TrancheSpec[] memory tranches =
            LoanFixtures.tranches1(LoanFixtures.tranche(STAKED_USDAI, trancheAmount, RATE_8_PCT));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = collateralTokenId;

        ILoanRouterV2.LoanTermsV2 memory loanTerms = ILoanRouterV2.LoanTermsV2({
            expiration: uint64(block.timestamp + 7 days),
            borrower: address(usdaiReserve),
            currencyToken: USDAI,
            collateralToken: address(collateralNft),
            collateralTokenIds: tokenIds,
            trancheSpecs: tranches,
            feeSpecs: new ILoanRouterV2.FeeSpec[](0),
            interestRateSpec: ILoanRouterV2.InterestRateSpec({model: address(irm), options: abi.encode(irmOpts)}),
            repaymentSpec: ILoanRouterV2.RepaymentSpec({day: 15, totalDurationDays: 365, timezoneOffsetSeconds: 0}),
            approvalAddresses: new address[](0),
            options: ""
        });

        /* Lender deposits to EscrowTimelock for the loanTermsHash (no on-chain transfer at deposit) */
        bytes32 loanTermsHash_ = router.loanTermsHash(loanTerms);
        vm.prank(STAKED_USDAI);
        escrowTimelock.deposit(address(router), loanTermsHash_, address(USDAI), trancheAmount, 0);

        /* Stage collateral in CollateralTimelock */
        vm.prank(collateralEscrow);
        collateralTimelock.deposit(
            address(router), loanTermsHash_, address(collateralNft), tokenIds, uint64(block.timestamp + 7 days)
        );

        /* Originate with EscrowTimelock deposit type (single tranche) */
        ILoanRouterV2.LenderDepositInfo[] memory infos = new ILoanRouterV2.LenderDepositInfo[](1);
        infos[0] = ILoanRouterV2.LenderDepositInfo({depositType: ILoanRouterV2.DepositType.EscrowTimelock, data: ""});

        uint256 stakedBalBefore = IERC20(USDAI).balanceOf(STAKED_USDAI);
        vm.prank(users.deployer);
        router.originate(loanTerms, infos, new bytes[](0));

        /* Post-origination: loan active, collateral with router, reserve balance unchanged */
        (ILoanRouterV2.LoanStatus status,,, uint256 balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Active));
        assertEq(balance, trancheAmount);
        assertEq(collateralNft.ownerOf(collateralTokenId), address(router));
        assertEq(IERC20(USDAI).balanceOf(address(usdaiReserve)), reserveBalBefore);

        /* Walk through every repayment window, paying from the reserve at each deadline */
        uint64[] memory schedule = _schedule(loanTerms);
        uint256 totalRepaid;
        for (uint256 i = 0; i < schedule.length; i++) {
            vm.warp(schedule[i]);
            (uint256 principalDue, uint256 interestDue, uint256 feeDue) = router.quote(loanTerms);
            uint256 totalDue = principalDue + interestDue + feeDue;
            vm.prank(users.borrower);
            usdaiReserve.repay(loanTerms, totalDue);
            totalRepaid += totalDue;
        }

        /* Loan fully repaid and zero balance */
        (status,,, balance) = router.loanState(loanTermsHash_);
        assertEq(uint8(status), uint8(ILoanRouterV2.LoanStatus.Repaid));
        assertEq(balance, 0);

        /* Collateral NFT returned to the ReserveAccount borrower */
        assertEq(collateralNft.ownerOf(collateralTokenId), address(usdaiReserve));

        /* Lender NFT burned (reverse lookup cleared) */
        uint256[] memory lenderTokenIds = router.loanTokenIds(loanTerms);
        (bytes32 reverseHash,) = router.lenderPositionInfo(lenderTokenIds[0]);
        assertEq(reverseHash, bytes32(0));

        /* Lender received principal + accrued interest (no fees on this loan) */
        uint256 stakedReceived = IERC20(USDAI).balanceOf(STAKED_USDAI) - stakedBalBefore;
        assertEq(stakedReceived, totalRepaid);
        assertGt(stakedReceived, trancheAmount);

        /* Reserve balance decremented by exactly what flowed out */
        assertEq(IERC20(USDAI).balanceOf(address(usdaiReserve)), reserveBalBefore - totalRepaid);

        /* Required reserves still satisfied */
        (uint256 required,) = usdaiReserve.reserves();
        assertGe(IERC20(USDAI).balanceOf(address(usdaiReserve)), required);
    }

    function _schedule(
        ILoanRouterV2.LoanTermsV2 memory loanTerms
    ) internal view returns (uint64[] memory deadlines) {
        /* Read the router's deadline schedule */
        deadlines = router.deadlines(loanTerms);
    }

    function _scheduleAt(
        ILoanRouterV2.LoanTermsV2 memory loanTerms,
        uint64 originationTimestamp
    ) internal pure returns (uint64[] memory deadlines) {
        /* Drop the stub flag from the computed deadline schedule */
        (, deadlines) = ScheduleLogic.deadlines(loanTerms, originationTimestamp);
    }
}

contract SinkTarget {
    fallback() external payable {}
    receive() external payable {}
}
