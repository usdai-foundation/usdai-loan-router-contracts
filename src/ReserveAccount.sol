// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";

import "./interfaces/IReserveAccount.sol";
import "./interfaces/ILoanRouterV2.sol";

/**
 * @title Reserve Account
 * @author USD.AI Foundation
 */
contract ReserveAccount is
    ERC165Upgradeable,
    IReserveAccount,
    IERC721Receiver,
    AccessControlUpgradeable,
    MulticallUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.1";

    /**
     * @notice Borrower role
     */
    bytes32 public constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    /**
     * @notice Currency token storage location
     * @dev keccak256(abi.encode(uint256(keccak256("reserveAccount.currencyToken")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant CURRENCY_TOKEN_STORAGE_LOCATION =
        0xca025fa9e56516a43a52451c0174d7fba469bef87cf82a590e983eb89bb1fb00;

    /**
     * @notice Reserves storage location
     * @dev keccak256(abi.encode(uint256(keccak256("reserveAccount.reserves")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant RESERVES_STORAGE_LOCATION =
        0x53cfd27ffa372c3f642690b65850f6a9b6a488614d3f42bf98ca97377726ac00;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @custom:storage-location erc7201:reserveAccount.currencyToken
     */
    struct CurrencyTokenStorage {
        IERC20 token;
    }

    /**
     * @custom:storage-location erc7201:reserveAccount.reserves
     */
    struct ReservesStorage {
        uint256 required;
    }

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Admin address
     */
    address private immutable _admin;

    /**
     * @notice Loan router
     */
    address private immutable _loanRouter;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Reserve Account Constructor
     * @param admin_ Admin address
     * @param loanRouter_ Loan router this account forwards repayments to
     */
    constructor(
        address admin_,
        address loanRouter_
    ) nonZeroAddress(admin_) nonZeroAddress(loanRouter_) {
        _admin = admin_;
        _loanRouter = loanRouter_;

        _disableInitializers();
    }

    /*------------------------------------------------------------------------*/
    /* Initialization */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param borrower Borrower address
     * @param currencyToken_ Currency token
     * @param reservesRequired Initial reserves required
     */
    function initialize(
        address borrower,
        address currencyToken_,
        uint256 reservesRequired
    ) external nonZeroAddress(borrower) nonZeroAddress(currencyToken_) initializer {
        __ERC165_init();
        __AccessControl_init();
        __Multicall_init();

        _getCurrencyTokenStorage().token = IERC20(currencyToken_);
        _getReservesStorage().required = reservesRequired;

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(BORROWER_ROLE, borrower);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero address modifier
     * @param value Value to check
     */
    modifier nonZeroAddress(
        address value
    ) {
        if (value == address(0)) revert InvalidAddress();
        _;
    }

    /**
     * @notice Non-zero value modifier
     * @param value Value to check
     */
    modifier nonZeroUint(
        uint256 value
    ) {
        if (value == 0) revert InvalidAmount();
        _;
    }

    /*------------------------------------------------------------------------*/
    /* Storage getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get currency token storage pointer
     * @return $ Currency token storage reference
     */
    function _getCurrencyTokenStorage() internal pure returns (CurrencyTokenStorage storage $) {
        assembly {
            $.slot := CURRENCY_TOKEN_STORAGE_LOCATION
        }
    }

    /**
     * @notice Get reserves storage pointer
     * @return $ Reserves storage reference
     */
    function _getReservesStorage() internal pure returns (ReservesStorage storage $) {
        assembly {
            $.slot := RESERVES_STORAGE_LOCATION
        }
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IReserveAccount
     */
    function admin() external view returns (address) {
        return _admin;
    }

    /**
     * @inheritdoc IReserveAccount
     */
    function loanRouter() external view returns (address) {
        return _loanRouter;
    }

    /**
     * @inheritdoc IReserveAccount
     */
    function currencyToken() external view returns (address) {
        return address(_getCurrencyTokenStorage().token);
    }

    /**
     * @inheritdoc IReserveAccount
     */
    function reserves() public view returns (uint256, uint256) {
        /* Get reserves required */
        uint256 required = _getReservesStorage().required;

        /* Get balance */
        uint256 balance = _getCurrencyTokenStorage().token.balanceOf(address(this));

        /* Compute excess */
        uint256 excess = balance > required ? balance - required : 0;

        /* Return required and excess */
        return (required, excess);
    }

    /*------------------------------------------------------------------------*/
    /* Borrower API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IReserveAccount
     */
    function repay(
        ILoanRouterV2.LoanTermsV2 calldata loanTerms,
        uint256 amount
    ) external onlyRole(BORROWER_ROLE) nonZeroUint(amount) nonReentrant {
        /* Get currency token */
        IERC20 token = _getCurrencyTokenStorage().token;

        /* Validate currency token */
        if (loanTerms.currencyToken != address(token)) revert InvalidCurrencyToken();

        /* Get token balance and reserves required */
        uint256 balance = token.balanceOf(address(this));
        uint256 required = _getReservesStorage().required;

        /* Validate reserves are sufficient */
        if (balance < required) revert InsufficientReserves();

        /* Validate amount is within available excess */
        if (balance - required < amount) revert InvalidAmount();

        /* Approve loan router to spend tokens */
        token.forceApprove(_loanRouter, amount);

        /* Forward repayment to loan router */
        uint256 repaymentAmount = ILoanRouterV2(_loanRouter).repay(loanTerms, amount);

        /* Revoke loan router approval */
        token.forceApprove(_loanRouter, 0);

        /* Emit RepaymentForwarded event */
        emit RepaymentForwarded(repaymentAmount);
    }

    /**
     * @inheritdoc IReserveAccount
     */
    function withdraw(
        address recipient,
        uint256 amount
    ) external onlyRole(BORROWER_ROLE) nonZeroUint(amount) nonZeroAddress(recipient) nonReentrant {
        /* Compute available excess */
        (, uint256 excess) = reserves();

        /* Validate amount is within available excess */
        if (excess < amount) revert InvalidAmount();

        /* Transfer to recipient */
        _getCurrencyTokenStorage().token.safeTransfer(recipient, amount);

        /* Emit ReservesWithdrawn event */
        emit ReservesWithdrawn(recipient, amount);
    }

    /*------------------------------------------------------------------------*/
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IReserveAccount
     */
    function execute(
        address target,
        bytes calldata data
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (bytes memory) {
        /* Forward call */
        bytes memory result = Address.functionCall(target, data);

        /* Extract selector for telemetry */
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);

        /* Emit Executed event */
        emit Executed(target, selector);

        return result;
    }

    /**
     * @inheritdoc IReserveAccount
     */
    function setReservesRequired(
        uint256 required
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        /* Update reserves required */
        _getReservesStorage().required = required;

        /* Emit reserves required set event */
        emit ReservesRequiredSet(required);
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
    ) public view virtual override(AccessControlUpgradeable, ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IReserveAccount).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
