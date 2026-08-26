// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/TransientSlot.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import "./interfaces/ILoanRouterV2.sol";
import "./interfaces/ILoanRouterV2Hooks.sol";
import "./interfaces/IInterestRateModelV2.sol";
import "./interfaces/ICollateralTimelock.sol";

import "./LoanLogicV2.sol";
import "./ScheduleLogic.sol";

/**
 * @title Loan Router V2
 * @author USD.AI Foundation
 */
contract LoanRouterV2 is
    ILoanRouterV2,
    IERC721Receiver,
    ERC165Upgradeable,
    ERC721Upgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.2";

    /**
     * @notice Pause role
     */
    bytes32 internal constant PAUSE_ADMIN_ROLE = keccak256("PAUSE_ADMIN_ROLE");

    /**
     * @notice Liquidator role
     */
    bytes32 internal constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    /**
     * @notice Originator role
     */
    bytes32 internal constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");

    /**
     * @notice EIP-712 typehash for the loan terms approval payload
     */
    bytes32 internal constant LOAN_TERMS_APPROVAL_TYPEHASH = keccak256("LoanTermsApproval(bytes32 loanTermsHash)");

    /**
     * @notice Loans storage location
     * @dev keccak256(abi.encode(uint256(keccak256("loanRouterV2.loans")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant LOANS_STORAGE_LOCATION =
        0xc7d422a73feacd7a8d2b5dc09ff3a15bba41f3d6b48de8f5e00b10ef87955800;

    /**
     * @notice Scaling factor transient slot
     * @dev keccak256(abi.encode(uint256(keccak256("loanRouterV2.scalingFactor")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant SCALING_FACTOR_STORAGE_LOCATION =
        0x63043b76c5cd2ec68fff67ecb9da21435dee1f3740390bd2214e1d4f680a6900;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan reverse lookup
     * @param loanTermsHash Loan terms hash
     * @param trancheIndex Tranche index
     */
    struct LoanReverseLookup {
        bytes32 loanTermsHash;
        uint8 trancheIndex;
    }

    /**
     * @notice Loans storage
     * @custom:storage-location erc7201:loanRouterV2.loans
     * @param loans Loans mapping (loan terms hash to LoanState)
     * @param loanReverseLookups Reverse loans mapping (token ID to LoanReverseLookup)
     */
    struct Loans {
        mapping(bytes32 => LoanState) loans;
        mapping(uint256 => LoanReverseLookup) loanReverseLookups;
    }

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Fee recipient
     */
    address internal immutable _feeRecipient;

    /**
     * @notice Collateral timelock
     */
    address internal immutable _collateralTimelock;

    /**
     * @notice Deposit timelock
     */
    address internal immutable _depositTimelock;

    /**
     * @notice Escrow timelock
     */
    address internal immutable _escrowTimelock;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Loan Router V2 Constructor
     * @param feeRecipient_ Fee recipient address
     * @param collateralTimelock_ Collateral timelock address
     * @param depositTimelock_ Deposit timelock
     * @param escrowTimelock_ Escrow timelock
     */
    constructor(
        address feeRecipient_,
        address collateralTimelock_,
        address depositTimelock_,
        address escrowTimelock_
    ) {
        _disableInitializers();

        if (feeRecipient_ == address(0)) revert InvalidAddress();
        if (collateralTimelock_ == address(0)) revert InvalidAddress();
        if (depositTimelock_ == address(0)) revert InvalidAddress();
        if (escrowTimelock_ == address(0)) revert InvalidAddress();

        _feeRecipient = feeRecipient_;
        _collateralTimelock = collateralTimelock_;
        _depositTimelock = depositTimelock_;
        _escrowTimelock = escrowTimelock_;
    }

    /*------------------------------------------------------------------------*/
    /* Initialization */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     */
    function initialize(
        address admin
    ) external initializer {
        __ERC165_init();
        __ERC721_init("USDai Loan Router V2", "USDai-LR-V2");
        __EIP712_init("USDai Loan Router V2", "1.0");
        __Pausable_init();
        __AccessControl_init();

        if (admin == address(0)) revert InvalidAddress();

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Store scale factor in transient storage modifier
     * @param currencyToken_ Currency token
     */
    modifier scaleFactor(
        address currencyToken_
    ) {
        /* Store scale factor in transient storage location */
        SCALING_FACTOR_STORAGE_LOCATION.asUint256().tstore(10 ** (18 - IERC20Metadata(currencyToken_).decimals()));

        _;

        /* Reset scale factor */
        SCALING_FACTOR_STORAGE_LOCATION.asUint256().tstore(0);
    }

    /*------------------------------------------------------------------------*/
    /* Storage getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get loans storage pointer
     * @return $ Loans storage reference
     */
    function _getLoansStorage() internal pure returns (Loans storage $) {
        assembly {
            $.slot := LOANS_STORAGE_LOCATION
        }
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Scale a value up
     * @param value Value
     * @param scaleFactor_ Scale factor
     * @return Scaled value
     */
    function _scale(
        uint256 value,
        uint256 scaleFactor_
    ) internal pure returns (uint256) {
        return value * scaleFactor_;
    }

    /**
     * @notice Scale a value up
     * @param value Value
     * @return Scaled value
     */
    function _scale(
        uint256 value
    ) internal view returns (uint256) {
        return _scale(value, SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload());
    }

    /**
     * @notice Scale a value down
     * @param value Value
     * @param roundUp Round up if true
     * @param scaleFactor_ Scale factor
     * @return Unscaled value
     */
    function _unscale(
        uint256 value,
        uint256 scaleFactor_,
        bool roundUp
    ) internal pure returns (uint256) {
        /* Round down if not rounding up */
        return (value % scaleFactor_ == 0 || !roundUp) ? value / scaleFactor_ : value / scaleFactor_ + 1;
    }

    /**
     * @notice Scale a value down
     * @param value Value
     * @param roundUp Round up if true
     * @return Unscaled value
     */
    function _unscale(
        uint256 value,
        bool roundUp
    ) internal view returns (uint256) {
        return _unscale(value, SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(), roundUp);
    }

    /**
     * @notice Tokenize lender positions
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param isRefinance Whether the loan is a refinance
     */
    function _tokenizeLenderPositions(
        LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        bool isRefinance
    ) internal {
        /* Transfer tokenized lender positions to lenders */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Get token ID */
            uint256 tokenId = LoanLogicV2._tokenId(loanTermsHash_, i);

            /* Get lender */
            address lender = loanTerms.trancheSpecs[i].lender;

            /* Validate no hash collision */
            if (_getLoansStorage().loanReverseLookups[tokenId].loanTermsHash != bytes32(0)) {
                revert InvalidLoanState();
            }

            /* Store reverse loan lookup */
            _getLoansStorage().loanReverseLookups[tokenId] =
                LoanReverseLookup({loanTermsHash: loanTermsHash_, trancheIndex: i});

            /* Mint tokenized lender position */
            _safeMint(lender, tokenId);

            /* Call onLoanOriginated hook if not refinancing and lender is a contract, and implements ILoanRouterV2Hooks
            interface */
            if (
                !isRefinance && lender.code.length != 0
                    && IERC165(lender).supportsInterface(type(ILoanRouterV2Hooks).interfaceId)
            ) {
                ILoanRouterV2Hooks(lender).onLoanOriginated(loanTerms, loanTermsHash_, i);
            }

            /* Emit lender position minted event */
            emit LenderPositionMinted(loanTermsHash_, lender, i, tokenId);
        }
    }

    /**
     * @notice Burn lender position NFTs and clear reverse lookups
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     */
    function _burnLenderPositions(
        LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_
    ) internal {
        /* Iterate every tranche and tear down its lender position */
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            /* Recompute the lender position token ID */
            uint256 tokenId = LoanLogicV2._tokenId(loanTermsHash_, i);

            /* Delete reverse loan lookup */
            delete _getLoansStorage().loanReverseLookups[tokenId];

            /* Burn the lender position NFT */
            _burn(tokenId);
        }
    }

    /**
     * @notice Close a fully repaid loan by burning lender positions and returning collateral
     * @param loanTerms Loan terms
     * @param loanTermsHash_ Loan terms hash
     * @param loan Loan state
     * @param isRefinance Whether the loan is a refinance
     */
    function _closeLoan(
        LoanTermsV2 calldata loanTerms,
        bytes32 loanTermsHash_,
        LoanState storage loan,
        bool isRefinance
    ) private {
        /* Mark loan repaid and set balance to zero */
        loan.status = LoanStatus.Repaid;
        loan.balance = 0;

        /* Burn lender NFTs and clear reverse lookups */
        _burnLenderPositions(loanTerms, loanTermsHash_);

        /* Return collateral to borrower */
        if (!isRefinance) {
            for (uint256 i; i < loanTerms.collateralTokenIds.length; i++) {
                IERC721(loanTerms.collateralToken)
                    .safeTransferFrom(address(this), loanTerms.borrower, loanTerms.collateralTokenIds[i]);
            }
        }
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function collateralTimelock() external view returns (address) {
        return _collateralTimelock;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function depositTimelock() external view returns (address) {
        return _depositTimelock;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function escrowTimelock() external view returns (address) {
        return _escrowTimelock;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function loanTermsHash(
        LoanTermsV2 calldata loanTerms
    ) external view returns (bytes32) {
        return LoanLogicV2.hashLoanTerms(abi.encode(loanTerms));
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function loanTokenIds(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint256[] memory) {
        /* Get loan terms hash */
        bytes32 loanTermsHash_ = LoanLogicV2.hashLoanTerms(abi.encode(loanTerms));

        /* Get token IDs */
        uint256[] memory tokenIds = new uint256[](loanTerms.trancheSpecs.length);
        for (uint8 i; i < loanTerms.trancheSpecs.length; i++) {
            tokenIds[i] = LoanLogicV2._tokenId(loanTermsHash_, i);
        }

        return tokenIds;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function loanState(
        bytes32 loanTermsHash_
    ) public view returns (LoanStatus, uint16, uint64, uint256) {
        /* Get loan state */
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        return (loan.status, loan.repaymentCount, loan.originationTimestamp, loan.balance);
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function loanState(
        uint256 tokenId
    ) external view returns (LoanStatus, uint16, uint64, uint256) {
        /* Get loan reverse lookup */
        LoanReverseLookup storage loanReverseLookup = _getLoansStorage().loanReverseLookups[tokenId];

        return loanState(loanReverseLookup.loanTermsHash);
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function deadlines(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint64[] memory) {
        /* Look up the loan's origination timestamp from storage */
        uint64 originationTimestamp =
            _getLoansStorage().loans[LoanLogicV2.hashLoanTerms(abi.encode(loanTerms))].originationTimestamp;

        /* Drop the stub flag and return only the deadline schedule */
        (, uint64[] memory loanDeadlines) = ScheduleLogic.deadlines(loanTerms, originationTimestamp);

        return loanDeadlines;
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function lenderPositionInfo(
        uint256 tokenId
    ) external view returns (bytes32, uint8) {
        /* Get loan reverse lookup */
        LoanReverseLookup storage loanReverseLookup = _getLoansStorage().loanReverseLookups[tokenId];

        return (loanReverseLookup.loanTermsHash, loanReverseLookup.trancheIndex);
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function quote(
        LoanTermsV2 calldata loanTerms,
        uint64 timestamp
    ) public view returns (uint256, uint256, uint256) {
        /* Get scale factor */
        uint256 scaleFactor_ = 10 ** (18 - IERC20Metadata(loanTerms.currencyToken).decimals());

        (uint256 scaledPrincipalPayment, uint256 scaledInterestPayment, uint256 scaledFee) = LoanLogicV2.quoteRepayment(
            loanTerms,
            _getLoansStorage().loans[LoanLogicV2.hashLoanTerms(abi.encode(loanTerms))],
            timestamp,
            _scale(LoanLogicV2.computePrincipal(loanTerms), scaleFactor_)
        );

        return (
            _unscale(scaledPrincipalPayment, scaleFactor_, true),
            _unscale(scaledInterestPayment, scaleFactor_, true),
            _unscale(scaledFee, scaleFactor_, true)
        );
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function quote(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint256, uint256, uint256) {
        return quote(loanTerms, uint64(block.timestamp));
    }

    /*------------------------------------------------------------------------*/
    /* Originator API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function originate(
        LoanTermsV2 calldata loanTerms,
        LenderDepositInfo[] calldata lenderDepositInfos,
        bytes[] calldata approvalSignatures
    ) external onlyRole(ORIGINATOR_ROLE) scaleFactor(loanTerms.currencyToken) nonReentrant returns (uint256) {
        /* Get loan storage */
        bytes memory encodedLoanTerms = abi.encode(loanTerms);
        bytes32 loanTermsHash_ = LoanLogicV2.hashLoanTerms(encodedLoanTerms);
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        /* Validate loan state and lender deposit infos length */
        if (loan.status != LoanStatus.Uninitialized) revert InvalidLoanState();
        if (lenderDepositInfos.length != loanTerms.trancheSpecs.length) revert InvalidLength();

        /* Validate loan terms */
        LoanLogicV2.validateLoanTerms(loanTerms);

        /* Validate approval signatures */
        if (loanTerms.approvalAddresses.length > 0) {
            LoanLogicV2.validateApprovals(
                _hashTypedDataV4(keccak256(abi.encode(LOAN_TERMS_APPROVAL_TYPEHASH, loanTermsHash_))),
                loanTerms.approvalAddresses,
                approvalSignatures
            );
        }

        /* Compute principal and scaled principal */
        uint256 principal = LoanLogicV2.computePrincipal(loanTerms);
        uint256 scaledPrincipal = _scale(principal);

        /* Initialize loan state */
        loan.status = LoanStatus.Active;
        loan.balance = scaledPrincipal;
        loan.repaymentCount = 0;
        loan.originationTimestamp = uint64(block.timestamp);

        /* Withdraw collateral from collateral timelock */
        ICollateralTimelock(_collateralTimelock)
            .withdraw(loanTermsHash_, loanTerms.collateralToken, loanTerms.collateralTokenIds);

        /* Withdraw lender funds */
        (uint256 offchainAmount, uint256 onchainAmount) =
            LoanLogicV2.withdrawFunds(loanTerms, loanTermsHash_, lenderDepositInfos, _depositTimelock, _escrowTimelock);

        /* Tokenize lender positions and call onLoanOriginated hooks */
        _tokenizeLenderPositions(loanTerms, loanTermsHash_, false);

        /* Transfer funds to borrower */
        uint256 originationFee;
        if (offchainAmount != 0) {
            /* Compute unscaled origination fee for validation and event accounting */
            originationFee =
                _unscale(LoanLogicV2.computeFees(FeeKind.Origination, loanTerms, loan, scaledPrincipal), true);

            /* Validate unscaled origination fee is not greater than offchain amount */
            if (originationFee > offchainAmount) revert InvalidAmount();

            /* Transfer only onchain funds. Origination fees collected offchain by escrow depositor */
            if (onchainAmount > 0) IERC20(loanTerms.currencyToken).safeTransfer(loanTerms.borrower, onchainAmount);
        } else {
            /* Pay origination fee */
            originationFee = _unscale(
                LoanLogicV2.payFees(
                    FeeKind.Origination,
                    loanTerms,
                    loan,
                    loanTermsHash_,
                    SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(),
                    _feeRecipient,
                    scaledPrincipal
                ),
                true
            );

            /* Transfer principal less origination fee to borrower */
            IERC20(loanTerms.currencyToken).safeTransfer(loanTerms.borrower, principal - originationFee);
        }

        /* Emit loan originated event */
        emit LoanOriginated(loanTermsHash_, encodedLoanTerms);

        return principal - originationFee;
    }

    /*------------------------------------------------------------------------*/
    /* Borrower API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function repay(
        LoanTermsV2 calldata loanTerms,
        uint256 amount
    ) external whenNotPaused scaleFactor(loanTerms.currencyToken) nonReentrant returns (uint256 repaymentAmount) {
        /* Get loan storage */
        bytes32 loanTermsHash_ = LoanLogicV2.hashLoanTerms(abi.encode(loanTerms));
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        /* Validate caller and loan state */
        if (loan.status != LoanStatus.Active) revert InvalidLoanState();
        if (msg.sender != loanTerms.borrower) revert InvalidCaller();
        if (amount == 0) revert InvalidAmount();

        /* Compute unscaled principal */
        uint256 principal = LoanLogicV2.computePrincipal(loanTerms);

        /* Compute scaled amounts */
        uint256 scaledAmount = _scale(amount);
        uint256 scaledPrincipal = _scale(principal);

        /* Compute the payment breakdown, which selects scheduled repayment or standalone prepayment */
        LoanLogicV2.Repayment memory repayment = LoanLogicV2.computeRepayment(
            loanTerms, loan, SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(), scaledAmount, scaledPrincipal
        );

        /* Validate the scaled amount covers the total payment */
        if (scaledAmount < repayment.repayment) revert InvalidAmount();

        /* Unscale the total payment amount, rounded up against scale truncation */
        repaymentAmount = _unscale(repayment.repayment, true);

        /* Transfer total payment amount from borrower */
        IERC20(loanTerms.currencyToken).safeTransferFrom(msg.sender, address(this), repaymentAmount);

        /* Pay repayment fees on a scheduled repayment */
        if (repayment.repaymentFee > 0) {
            LoanLogicV2.payFees(
                FeeKind.Repayment,
                loanTerms,
                loan,
                loanTermsHash_,
                SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(),
                _feeRecipient,
                scaledPrincipal
            );
        }

        /* Pay exit fees if this payment closes the loan */
        if (repayment.exitFee > 0) {
            LoanLogicV2.payFees(
                FeeKind.Exit,
                loanTerms,
                loan,
                loanTermsHash_,
                SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(),
                _feeRecipient,
                scaledPrincipal
            );
        }

        /* Reduce loan balance and advance repayment count on a scheduled repayment */
        loan.balance -= repayment.principalPayment + repayment.prepayment;
        if (!repayment.isStandalonePrepayment) loan.repaymentCount += 1;
        bool isFullyRepaid = loan.balance == 0;

        /* Compute fee total */
        uint256 scaledFeeTotal = repayment.repaymentFee + repayment.exitFee;

        /* Transfer lender repayments, call hooks, and validate total repayment */
        if (
            LoanLogicV2.repayLenders(
                        loanTerms,
                        loanTermsHash_,
                        repayment,
                        loan.balance,
                        SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(),
                        _feeRecipient
                    ) + scaledFeeTotal > repayment.repayment
        ) {
            revert InvalidAmount();
        }

        /* If loan is fully repaid, close it out */
        if (isFullyRepaid) _closeLoan(loanTerms, loanTermsHash_, loan, false);

        /* Emit loan repaid event */
        emit LoanRepaid(
            loanTermsHash_,
            msg.sender,
            _unscale(repayment.principalPayment, false),
            _unscale(repayment.interestPayment, false),
            _unscale(repayment.prepayment, false),
            _unscale(scaledFeeTotal, false),
            isFullyRepaid
        );
    }

    /*------------------------------------------------------------------------*/
    /* Liquidator API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function setLoanBreach(
        bytes32 loanTermsHash_
    ) external onlyRole(LIQUIDATOR_ROLE) {
        /* Get loan storage */
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        /* Check loan is active */
        if (loan.status != LoanStatus.Active) revert InvalidLoanState();

        /* Update loan status */
        loan.status = LoanStatus.Breached;

        /* Emit loan breached event */
        emit LoanBreached(loanTermsHash_);
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function liquidate(
        LoanTermsV2 calldata loanTerms
    ) external onlyRole(LIQUIDATOR_ROLE) nonReentrant {
        /* Get loan storage */
        bytes32 loanTermsHash_ = LoanLogicV2.hashLoanTerms(abi.encode(loanTerms));
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        /* Validate loan state */
        if (loan.status == LoanStatus.Active) {
            if (
                block.timestamp
                    <= IInterestRateModelV2(loanTerms.interestRateSpec.model).gracePeriodEnd(loanTerms, loan)
            ) {
                revert InvalidLoanState();
            }
        } else if (loan.status != LoanStatus.Breached) {
            revert InvalidLoanState();
        }

        /* Update loan status */
        loan.status = LoanStatus.Liquidated;

        /* Transfer collateral and dispatch liquidation hooks */
        LoanLogicV2.liquidateLoan(loanTerms, loanTermsHash_, msg.sender);

        /* Emit loan liquidated event */
        emit LoanLiquidated(loanTermsHash_);
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function depositLiquidationProceeds(
        LoanTermsV2 calldata loanTerms,
        uint256 proceeds
    ) external onlyRole(LIQUIDATOR_ROLE) scaleFactor(loanTerms.currencyToken) nonReentrant {
        /* Get loan storage */
        bytes32 loanTermsHash_ = LoanLogicV2.hashLoanTerms(abi.encode(loanTerms));
        LoanState storage loan = _getLoansStorage().loans[loanTermsHash_];

        /* Check loan is liquidated */
        if (loan.status != LoanStatus.Liquidated) revert InvalidLoanState();

        /* Compute principal */
        uint256 principal = LoanLogicV2.computePrincipal(loanTerms);

        /* Pull proceeds from caller */
        IERC20(loanTerms.currencyToken).safeTransferFrom(msg.sender, address(this), proceeds);

        /* Pay liquidation fee */
        uint256 scaledLiquidationFee = LoanLogicV2.payFees(
            FeeKind.Liquidation,
            loanTerms,
            loan,
            loanTermsHash_,
            SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(),
            _feeRecipient,
            _scale(proceeds)
        );

        /* Compute liquidation breakdown (tranche distribution and surplus) */
        LoanLogicV2.Liquidation memory liquidation =
            LoanLogicV2.computeLiquidation(loanTerms, loan, _scale(proceeds) - scaledLiquidationFee, principal);

        /* Update loan status */
        loan.balance = 0;
        loan.status = LoanStatus.CollateralLiquidated;

        /* Transfer lender liquidation repayments and call onLoanCollateralLiquidated hooks */
        LoanLogicV2.repayLendersLiquidation(
            loanTerms, loanTermsHash_, liquidation, SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload(), _feeRecipient
        );

        /* Burn lender NFTs and clear reverse lookups now that lender hooks have fired */
        _burnLenderPositions(loanTerms, loanTermsHash_);

        /* Unscale surplus and transfer to default fee recipient */
        uint256 surplus = _unscale(liquidation.remainingProceeds, false);
        if (surplus > 0) {
            IERC20(loanTerms.currencyToken).safeTransfer(_feeRecipient, surplus);
        }

        /* Emit liquidation proceeds deposited event */
        emit LiquidationProceedsDeposited(loanTermsHash_, proceeds, _unscale(scaledLiquidationFee, false), surplus);
    }

    /*------------------------------------------------------------------------*/
    /* Refinance API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function refinance(
        LoanTermsV2 calldata oldLoanTerms,
        LoanTermsV2 calldata newLoanTerms,
        uint256 expectedBalance
    ) external onlyRole(ORIGINATOR_ROLE) scaleFactor(oldLoanTerms.currencyToken) nonReentrant {
        /* Get old loan storage */
        bytes32 oldLoanTermsHash = LoanLogicV2.hashLoanTerms(abi.encode(oldLoanTerms));
        LoanState storage oldLoan = _getLoansStorage().loans[oldLoanTermsHash];

        /* Validate old loan state */
        if (oldLoan.status != LoanStatus.Active) revert InvalidLoanState();

        /* Cache old loan balance */
        uint256 oldBalance = oldLoan.balance;

        /* Validate expected current balance */
        if (expectedBalance != oldBalance) {
            revert InvalidAmount();
        }

        /* Compute new loan terms hash and get new loan storage */
        bytes32 newLoanTermsHash = LoanLogicV2.hashLoanTerms(abi.encode(newLoanTerms));
        LoanState storage newLoan = _getLoansStorage().loans[newLoanTermsHash];

        /* Validate new loan state */
        if (newLoan.status != LoanStatus.Uninitialized) revert InvalidLoanState();

        /* Validate refinance loan terms */
        LoanLogicV2.validateRefinanceLoanTerms(oldLoanTerms, newLoanTerms, oldLoan, oldLoanTermsHash);

        /* Read the scale factor */
        uint256 scaleFactor_ = SCALING_FACTOR_STORAGE_LOCATION.asUint256().tload();

        /* Compute the new unscaled balance */
        uint256 newBalance = LoanLogicV2.computePrincipal(newLoanTerms);

        /* Close the old loan without returning collateral */
        _closeLoan(oldLoanTerms, oldLoanTermsHash, oldLoan, true);

        /* Initialize new loan state */
        newLoan.status = LoanStatus.Active;
        newLoan.balance = oldLoan.repaymentCount == 0 ? _scale(newBalance) : oldBalance;
        newLoan.repaymentCount = oldLoan.repaymentCount;
        newLoan.originationTimestamp =
            oldLoan.repaymentCount == 0 ? uint64(block.timestamp) : oldLoan.originationTimestamp;

        /* Tokenize lender positions without calling onLoanOriginated hook */
        _tokenizeLenderPositions(newLoanTerms, newLoanTermsHash, true);

        /* Settle the refinance fee and cash movements and notify lenders */
        (uint256 cashOut, uint256 cashIn, uint256 refinanceFee) = LoanLogicV2.refinance(
            oldLoanTerms,
            newLoanTerms,
            newLoan,
            oldLoanTermsHash,
            newLoanTermsHash,
            oldBalance,
            scaleFactor_,
            _depositTimelock,
            _feeRecipient
        );

        /* Emit loan refinanced event */
        emit LoanRefinanced(oldLoanTermsHash, newLoanTermsHash, abi.encode(newLoanTerms), cashOut, cashIn, refinanceFee);
    }

    /*------------------------------------------------------------------------*/
    /* Pause API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function pause() external onlyRole(PAUSE_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ILoanRouterV2
     */
    function unpause() external onlyRole(PAUSE_ADMIN_ROLE) {
        _unpause();
    }

    /*------------------------------------------------------------------------*/
    /* Rescue ERC20 API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ILoanRouterV2
     */
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);

        /* Emit ERC20 rescued event */
        emit ERC20Rescued(token, to, amount);
    }

    /*------------------------------------------------------------------------*/
    /* IERC721Receiver */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC721Receiver
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControlUpgradeable, ERC165Upgradeable, ERC721Upgradeable) returns (bool) {
        return interfaceId == type(ILoanRouterV2).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
