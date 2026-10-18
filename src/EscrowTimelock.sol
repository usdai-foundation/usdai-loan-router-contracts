// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./interfaces/IEscrowTimelock.sol";
import "./interfaces/IEscrowTimelockHooks.sol";

/**
 * @title Escrow Timelock
 * @author USD.AI Foundation
 */
contract EscrowTimelock is
    IEscrowTimelock,
    ERC165Upgradeable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.0";

    /**
     * @notice Deposits storage location
     * @dev keccak256(abi.encode(uint256(keccak256("escrowTimelock.deposits")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant DEPOSITS_STORAGE_LOCATION =
        0xa534edbfc2a26bdf79c27576a3cfe71994d683a26571907198828f29018f7d00;

    /**
     * @notice Accrual storage location
     * @dev keccak256(abi.encode(uint256(keccak256("escrowTimelock.accrual")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant ACCRUAL_STORAGE_LOCATION =
        0xd0ce944f67547cded3d5848ee065c96cab977ea6922f5f134a261a7de7bf4b00;

    /**
     * @notice Fixed point scale
     */
    uint256 private constant FIXED_POINT_SCALE = 1e18;

    /**
     * @notice Max per-second interest rate (1e18-scaled), 100% APR over a 365 day year
     */
    uint256 private constant MAX_INTEREST_RATE = 31_709_791_983;

    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit record
     * @param target Target address
     * @param timestamp Deposit timestamp
     * @param context Context identifier
     * @param amount Amount
     * @param interestRate Interest rate
     */
    struct Deposit {
        address target;
        uint64 timestamp;
        bytes32 context;
        uint256 amount;
        uint256 interestRate;
    }

    /**
     * @custom:storage-location erc7201:escrowTimelock.deposits
     */
    struct Deposits {
        uint256 totalDeposits;
        mapping(uint256 => Deposit) deposits;
    }

    /**
     * @custom:storage-location erc7201:escrowTimelock.accrual
     */
    struct Accrual {
        uint256 accrued;
        uint256 rate;
        uint64 timestamp;
    }

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit token address
     */
    IERC20 private immutable _depositToken;

    /**
     * @notice Depositor address
     */
    address private immutable _depositor;

    /**
     * @notice Escrow admin address
     */
    address private immutable _escrowAdmin;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Escrow Timelock Constructor
     * @param depositToken_ Deposit token address
     * @param depositor_ Depositor address
     * @param escrowAdmin_ Escrow admin address
     */
    constructor(
        address depositToken_,
        address depositor_,
        address escrowAdmin_
    ) {
        _disableInitializers();

        _depositToken = IERC20(depositToken_);
        _depositor = depositor_;
        _escrowAdmin = escrowAdmin_;
    }

    /*------------------------------------------------------------------------*/
    /* Initialization  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     */
    function initialize(
        address admin
    ) external initializer {
        __ERC165_init();
        __ERC721_init("Escrow Timelock Receipt", "ET-RT");
        __AccessControl_init();

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Only depositor
     */
    modifier onlyDepositor() {
        if (msg.sender != _depositor) revert InvalidCaller();

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
     * @notice Non-zero bytes32 modifier
     * @param value Value to check
     */
    modifier nonZeroBytes32(
        bytes32 value
    ) {
        if (value == bytes32(0)) revert InvalidBytes32();
        _;
    }

    /*------------------------------------------------------------------------*/
    /* Storage getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get reference to deposits storage
     *
     * @return $ Reference to deposits storage
     */
    function _getDepositsStorage() internal pure returns (Deposits storage $) {
        assembly {
            $.slot := DEPOSITS_STORAGE_LOCATION
        }
    }

    /**
     * @notice Get reference to accrual storage
     *
     * @return $ Reference to accrual storage
     */
    function _getAccrualStorage() internal pure returns (Accrual storage $) {
        assembly {
            $.slot := ACCRUAL_STORAGE_LOCATION
        }
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Compute deposit token ID
     * @param target Target address
     * @param context Context identifier
     * @return Deposit token ID
     */
    function _depositTokenId(
        address target,
        bytes32 context
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(target, context)));
    }

    /**
     * @notice Update accrued interest and timestamp
     */
    function _accrue() internal {
        /* Get accrual */
        Accrual storage accrual = _getAccrualStorage();

        /* Update accrued interest */
        accrual.accrued += accrual.rate * (block.timestamp - accrual.timestamp);
        accrual.timestamp = uint64(block.timestamp);
    }

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IEscrowTimelock
     */
    function depositToken() external view returns (address) {
        return address(_depositToken);
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function depositor() external view returns (address) {
        return _depositor;
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function accrued() external view returns (uint256) {
        /* Get accrual */
        Accrual memory accrual = _getAccrualStorage();

        /* Return simulated accrued interest */
        return (accrual.accrued + accrual.rate * (block.timestamp - accrual.timestamp)) / FIXED_POINT_SCALE;
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function totalDeposits() external view returns (uint256) {
        return _getDepositsStorage().totalDeposits;
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function depositTokenId(
        address target,
        bytes32 context
    ) external pure returns (uint256) {
        return _depositTokenId(target, context);
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function depositInfo(
        uint256 tokenId
    ) external view returns (address, bytes32, uint256, uint256, uint64, uint256) {
        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Get interest due */
        uint256 interest = deposit_.amount * deposit_.interestRate * (block.timestamp - deposit_.timestamp);

        /* Unscale interest and round up */
        interest = interest % FIXED_POINT_SCALE == 0 ? interest / FIXED_POINT_SCALE : interest / FIXED_POINT_SCALE + 1;

        /* Return deposit information */
        return (deposit_.target, deposit_.context, deposit_.amount, deposit_.interestRate, deposit_.timestamp, interest);
    }

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IEscrowTimelock
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint256 interestRate
    )
        external
        onlyDepositor
        nonZeroAddress(target)
        nonZeroBytes32(context)
        nonZeroAddress(token)
        nonZeroUint(amount)
        nonReentrant
    {
        /* Validate token matches deposit token */
        if (token != address(_depositToken)) revert UnsupportedToken();

        /* Compute token ID */
        uint256 tokenId = _depositTokenId(target, context);

        /* Validate deposit does not exist */
        if (_getDepositsStorage().deposits[tokenId].target != address(0)) revert InvalidDeposit();

        /* Validate interest rate is not more than max interest rate */
        if (interestRate > MAX_INTEREST_RATE) revert InvalidAmount();

        /* Create deposit */
        _getDepositsStorage().deposits[tokenId] = Deposit({
            target: target,
            context: context,
            amount: amount,
            interestRate: interestRate,
            timestamp: uint64(block.timestamp)
        });

        /* Update total deposits */
        _getDepositsStorage().totalDeposits += amount;

        /* Accrue interest */
        _accrue();

        /* Update accrual rate with deposit */
        _getAccrualStorage().rate += amount * interestRate;

        /* Mint receipt token */
        _safeMint(msg.sender, tokenId);

        /* Transfer token from sender to escrow admin */
        _depositToken.safeTransferFrom(msg.sender, _escrowAdmin, amount);

        /* Emit Deposited event */
        emit Deposited(target, context, amount, interestRate);
    }

    /**
     * @inheritdoc IEscrowTimelock
     */
    function cancel(
        address target,
        bytes32 context
    ) external onlyDepositor nonZeroAddress(target) nonZeroBytes32(context) nonReentrant returns (uint256, uint256) {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(target, context);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate deposit exists */
        if (deposit_.target == address(0)) revert InvalidDeposit();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Update total deposits */
        _getDepositsStorage().totalDeposits -= deposit_.amount;

        /* Accrue interest */
        _accrue();

        /* Calculate total interest accrued for this deposit */
        uint256 interest = (deposit_.amount * deposit_.interestRate) * (block.timestamp - deposit_.timestamp);

        /* Remove deposit from accrual */
        _getAccrualStorage().accrued -= interest;
        _getAccrualStorage().rate -= deposit_.amount * deposit_.interestRate;

        /* Unscale interest and round up */
        interest = interest % FIXED_POINT_SCALE == 0 ? interest / FIXED_POINT_SCALE : interest / FIXED_POINT_SCALE + 1;

        /* Burn receipt token */
        _burn(tokenId);

        /* Transfer deposit amount and interest from escrow admin to depositor */
        _depositToken.safeTransferFrom(_escrowAdmin, _depositor, deposit_.amount + interest);

        /* Emit Canceled event */
        emit Canceled(target, context, deposit_.amount, interest);

        /* Return deposit amount and interest */
        return (deposit_.amount, interest);
    }

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IEscrowTimelock
     */
    function withdraw(
        bytes32 context,
        address token,
        uint256 amount
    ) external nonZeroBytes32(context) nonZeroAddress(token) nonReentrant returns (uint256, uint256) {
        /* Compute token ID */
        uint256 tokenId = _depositTokenId(msg.sender, context);

        /* Get deposit */
        Deposit memory deposit_ = _getDepositsStorage().deposits[tokenId];

        /* Validate deposit exists */
        if (deposit_.target == address(0)) revert InvalidDeposit();

        /* Validate token matches deposit token */
        if (token != address(_depositToken)) revert UnsupportedToken();

        /* Validate deposit amount */
        if (deposit_.amount != amount) revert InvalidAmount();

        /* Delete deposit */
        delete _getDepositsStorage().deposits[tokenId];

        /* Update total deposits */
        _getDepositsStorage().totalDeposits -= deposit_.amount;

        /* Accrue interest */
        _accrue();

        /* Calculate total interest accrued for this deposit */
        uint256 interest = (deposit_.amount * deposit_.interestRate) * (block.timestamp - deposit_.timestamp);

        /* Remove deposit from accrual */
        _getAccrualStorage().accrued -= interest;
        _getAccrualStorage().rate -= deposit_.amount * deposit_.interestRate;

        /* Unscale interest and round up */
        interest = interest % FIXED_POINT_SCALE == 0 ? interest / FIXED_POINT_SCALE : interest / FIXED_POINT_SCALE + 1;

        /* Burn deposit receipt NFT */
        _burn(tokenId);

        /* Transfer interest from escrow admin to depositor */
        if (interest > 0) _depositToken.safeTransferFrom(_escrowAdmin, _depositor, interest);

        /* Call onEscrowWithdrawn hook if depositor supports it */
        if (
            _depositor.code.length != 0 && IERC165(_depositor).supportsInterface(type(IEscrowTimelockHooks).interfaceId)
        ) {
            IEscrowTimelockHooks(_depositor).onEscrowWithdrawn(msg.sender, context, token, amount, interest);
        }

        /* Emit Withdrawn event */
        emit Withdrawn(msg.sender, context, deposit_.amount, amount, interest);

        /* Return withdraw amount and interest */
        return (amount, interest);
    }

    /*------------------------------------------------------------------------*/
    /* ERC721 Overrides */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC721
     */
    function approve(
        address,
        uint256
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function setApprovalForAll(
        address,
        bool
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function transferFrom(
        address,
        address,
        uint256
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /**
     * @inheritdoc IERC721
     */
    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override {
        revert("Transfers are disabled");
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControlUpgradeable, ERC721Upgradeable, ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IEscrowTimelock).interfaceId || super.supportsInterface(interfaceId);
    }
}
