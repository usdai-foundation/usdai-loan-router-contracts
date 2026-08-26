// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Loan Router V2 Interface
 * @author USD.AI Foundation
 */
interface ILoanRouterV2 {
    /*------------------------------------------------------------------------*/
    /* Structures */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit type
     * @param DepositTimelock Deposit timelock
     * @param EscrowTimelock Escrow timelock
     */
    enum DepositType {
        DepositTimelock,
        EscrowTimelock
    }

    /**
     * @notice Lender deposit info
     * @param depositType Deposit type
     * @param data Deposit data passed to timelock
     */
    struct LenderDepositInfo {
        DepositType depositType;
        bytes data;
    }

    /**
     * @notice Tranche specification
     * @param lender Lender
     * @param amount Amount
     * @param rate Rate
     */
    struct TrancheSpec {
        address lender;
        uint256 amount;
        uint256 rate;
    }

    /**
     * @notice Fee specification
     * @param kind Fee event kind
     * @param recipient Fee recipient (zero address for default)
     * @param model Fee model contract address
     * @param options Encoded fee model options
     */
    struct FeeSpec {
        FeeKind kind;
        address recipient;
        address model;
        bytes options;
    }

    /**
     * @notice Fee event kind
     * @param Origination Fee charged when the loan originates
     * @param Repayment Fee charged on each repayment
     * @param Exit Fee charged when the loan is repaid in full
     * @param Liquidation Fee charged when the loan is liquidated
     * @param Refinance Fee charged when the loan is refinanced
     */
    enum FeeKind {
        Origination,
        Repayment,
        Exit,
        Liquidation,
        Refinance
    }

    /**
     * @notice Interest rate specification
     * @param model Interest rate model contract address
     * @param options Encoded interest rate model options
     */
    struct InterestRateSpec {
        address model;
        bytes options;
    }

    /**
     * @notice Repayment specification
     * @param totalDurationDays Total loan duration in days
     * @param day Day of month repayments are due
     * @param timezoneOffsetSeconds UTC offset in seconds
     */
    struct RepaymentSpec {
        uint16 totalDurationDays;
        uint8 day;
        int32 timezoneOffsetSeconds;
    }

    /**
     * @notice Loan terms specification
     * @param expiration Loan offer expiration timestamp
     * @param borrower Borrower address
     * @param currencyToken Currency token
     * @param collateralToken Collateral token
     * @param repaymentSpec Repayment specification
     * @param interestRateSpec Interest rate specification
     * @param collateralTokenIds Collateral token IDs
     * @param trancheSpecs Tranche specifications
     * @param feeSpecs Fee specifications
     * @param approvalAddresses Addresses required to approve the loan
     * @param options Options data reserved for future extensions
     */
    struct LoanTermsV2 {
        uint64 expiration;
        address borrower;
        address currencyToken;
        address collateralToken;
        RepaymentSpec repaymentSpec;
        InterestRateSpec interestRateSpec;
        uint256[] collateralTokenIds;
        TrancheSpec[] trancheSpecs;
        FeeSpec[] feeSpecs;
        address[] approvalAddresses;
        bytes options;
    }

    /**
     * @notice Loan status
     * @param Uninitialized Loan has not been initialized
     * @param Active Loan is active
     * @param Repaid Loan has been repaid
     * @param Breached Loan is in breach
     * @param Liquidated Loan has been liquidated
     * @param CollateralLiquidated Loan collateral has been liquidated
     */
    enum LoanStatus {
        Uninitialized,
        Active,
        Repaid,
        Breached,
        Liquidated,
        CollateralLiquidated
    }

    /**
     * @notice Loan state
     * @param status Loan status
     * @param repaymentCount Number of completed repayments
     * @param originationTimestamp Loan origination timestamp
     * @param balance Scaled loan balance
     */
    struct LoanState {
        LoanStatus status;
        uint16 repaymentCount;
        uint64 originationTimestamp;
        uint256 balance;
    }

    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid deposit type
     */
    error InvalidDepositType();

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /**
     * @notice Invalid caller
     */
    error InvalidCaller();

    /**
     * @notice Invalid loan state
     */
    error InvalidLoanState();

    /**
     * @notice Invalid length
     */
    error InvalidLength();

    /**
     * @notice Invalid loan terms
     * @param reason Reason
     */
    error InvalidLoanTerms(string reason);

    /**
     * @notice Invalid signature
     */
    error InvalidSignature();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when loan is originated
     * @param loanTermsHash Loan terms hash
     * @param loanTerms Encoded loan terms
     */
    event LoanOriginated(bytes32 indexed loanTermsHash, bytes loanTerms);

    /**
     * @notice Emitted when lender position is minted
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param tokenId Token ID
     */
    event LenderPositionMinted(
        bytes32 indexed loanTermsHash, address indexed lender, uint8 indexed trancheIndex, uint256 tokenId
    );

    /**
     * @notice Emitted when lender is repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Principal repaid
     * @param interest Interest paid
     * @param prepay Prepayment
     */
    event LenderRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest,
        uint256 prepay
    );

    /**
     * @notice Emitted when loan is repaid
     * @param loanTermsHash Loan terms hash
     * @param borrower Borrower address
     * @param principal Principal repaid
     * @param interest Interest paid
     * @param prepayment Prepayment
     * @param fee Fee paid
     * @param isRepaid Whether loan is fully repaid
     */
    event LoanRepaid(
        bytes32 indexed loanTermsHash,
        address indexed borrower,
        uint256 principal,
        uint256 interest,
        uint256 prepayment,
        uint256 fee,
        bool isRepaid
    );

    /**
     * @notice Emitted when loan is refinanced
     * @param oldLoanTermsHash Old loan terms hash
     * @param newLoanTermsHash New loan terms hash
     * @param newLoanTerms New loan terms
     * @param cashOut Net cash-out to the borrower, zero when the refinance is cash-in
     * @param cashIn Net cash-in from the borrower, zero when the refinance is cash-out
     * @param refinanceFee Refinance fee paid
     */
    event LoanRefinanced(
        bytes32 indexed oldLoanTermsHash,
        bytes32 indexed newLoanTermsHash,
        bytes newLoanTerms,
        uint256 cashOut,
        uint256 cashIn,
        uint256 refinanceFee
    );

    /**
     * @notice Emitted when loan is set to breached
     * @param loanTermsHash Loan terms hash
     */
    event LoanBreached(bytes32 indexed loanTermsHash);

    /**
     * @notice Emitted when loan is liquidated
     * @param loanTermsHash Loan terms hash
     */
    event LoanLiquidated(bytes32 indexed loanTermsHash);

    /**
     * @notice Emitted when lender is liquidation repaid
     * @param loanTermsHash Loan terms hash
     * @param lender Lender address
     * @param trancheIndex Tranche index
     * @param principal Principal repaid
     * @param interest Interest paid
     */
    event LenderLiquidationRepaid(
        bytes32 indexed loanTermsHash,
        address indexed lender,
        uint8 indexed trancheIndex,
        uint256 principal,
        uint256 interest
    );

    /**
     * @notice Emitted when collateral is liquidated
     * @param loanTermsHash Loan terms hash
     * @param proceeds Proceeds for lenders
     * @param fee Liquidation fee
     * @param surplus Liquidation surplus
     */
    event LiquidationProceedsDeposited(bytes32 indexed loanTermsHash, uint256 proceeds, uint256 fee, uint256 surplus);

    /**
     * @notice Emitted when transfer failed
     * @param token Token address
     * @param recipient Recipient address
     * @param intendedRecipient Intended recipient address
     * @param amount Amount
     */
    event TransferFailed(
        address indexed token, address indexed recipient, address indexed intendedRecipient, uint256 amount
    );

    /**
     * @notice Emitted when hook failed
     * @param reason Reason
     */
    event HookFailed(string reason);

    /**
     * @notice Emitted when a fee is paid
     * @param loanTermsHash Loan terms hash
     * @param kind Fee kind
     * @param recipient Recipient address
     * @param feeModel Fee model address
     * @param amount Amount of fee paid
     */
    event FeePaid(
        bytes32 indexed loanTermsHash, FeeKind indexed kind, address indexed recipient, address feeModel, uint256 amount
    );

    /**
     * @notice Emitted when ERC20 tokens are rescued
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount
     */
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get collateral timelock address
     * @return Collateral timelock address
     */
    function collateralTimelock() external view returns (address);

    /**
     * @notice Get deposit timelock address
     * @return Deposit timelock address
     */
    function depositTimelock() external view returns (address);

    /**
     * @notice Get escrow timelock address
     * @return Escrow timelock address
     */
    function escrowTimelock() external view returns (address);

    /**
     * @notice Get fee recipient address
     * @return Fee recipient address
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Compute loan terms hash
     * @param loanTerms Loan terms
     * @return Hash of the loan terms
     */
    function loanTermsHash(
        LoanTermsV2 calldata loanTerms
    ) external view returns (bytes32);

    /**
     * @notice Get token IDs of lender positions
     * @param loanTerms Loan terms
     * @return Token IDs
     */
    function loanTokenIds(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint256[] memory);

    /**
     * @notice Get loan state by loan terms hash
     * @param loanTermsHash_ Loan terms hash
     * @return status Loan status
     * @return repaymentCount Number of completed repayments
     * @return originationTimestamp Loan origination timestamp
     * @return scaledBalance Scaled loan balance
     */
    function loanState(
        bytes32 loanTermsHash_
    )
        external
        view
        returns (LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 scaledBalance);

    /**
     * @notice Get loan state by token ID
     * @param tokenId Lender position token ID
     * @return status Loan status
     * @return repaymentCount Number of completed repayments
     * @return originationTimestamp Loan origination timestamp
     * @return scaledBalance Scaled loan balance
     */
    function loanState(
        uint256 tokenId
    )
        external
        view
        returns (LoanStatus status, uint16 repaymentCount, uint64 originationTimestamp, uint256 scaledBalance);

    /**
     * @notice Get the loan deadline schedule in UTC
     * @param loanTerms Loan terms
     * @return Array of UTC deadlines
     */
    function deadlines(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint64[] memory);

    /**
     * @notice Get lender position info by token ID
     * @param tokenId Lender position token ID
     * @return loanTermsHash_ Loan terms hash
     * @return trancheIndex Tranche index
     */
    function lenderPositionInfo(
        uint256 tokenId
    ) external view returns (bytes32 loanTermsHash_, uint8 trancheIndex);

    /**
     * @notice Quote repayment for loan at a given timestamp
     * @param loanTerms Loan terms
     * @param timestamp Timestamp
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feePayment Fees payment
     */
    function quote(
        LoanTermsV2 calldata loanTerms,
        uint64 timestamp
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment);

    /**
     * @notice Quote repayment for loan at the current timestamp
     * @param loanTerms Loan terms
     * @return principalPayment Principal payment
     * @return interestPayment Interest payment
     * @return feePayment Fees payment
     */
    function quote(
        LoanTermsV2 calldata loanTerms
    ) external view returns (uint256 principalPayment, uint256 interestPayment, uint256 feePayment);

    /*------------------------------------------------------------------------*/
    /* Originator API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Originate a loan
     * @param loanTerms Loan terms
     * @param lenderDepositInfos Lender deposit infos
     * @param approvalSignatures Approval signatures over EIP-712 loan terms digest
     * @return amount Amount transferred to the borrower
     */
    function originate(
        LoanTermsV2 calldata loanTerms,
        LenderDepositInfo[] calldata lenderDepositInfos,
        bytes[] calldata approvalSignatures
    ) external returns (uint256 amount);

    /*------------------------------------------------------------------------*/
    /* Borrower API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Repay a loan, or prepay principal when the current window is already paid
     * @param loanTerms Loan terms
     * @param amount Amount to pay
     * @return repaymentAmount Amount repaid
     */
    function repay(
        LoanTermsV2 calldata loanTerms,
        uint256 amount
    ) external returns (uint256 repaymentAmount);

    /*------------------------------------------------------------------------*/
    /* Liquidator API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Mark a loan as breached
     * @param loanTermsHash_ Loan terms hash
     */
    function setLoanBreach(
        bytes32 loanTermsHash_
    ) external;

    /**
     * @notice Liquidate loan after grace period or breach
     * @param loanTerms Loan terms
     */
    function liquidate(
        LoanTermsV2 calldata loanTerms
    ) external;

    /**
     * @notice Deposit liquidation proceeds for a loan and finalize it
     * @param loanTerms Loan terms
     * @param proceeds Proceeds
     */
    function depositLiquidationProceeds(
        LoanTermsV2 calldata loanTerms,
        uint256 proceeds
    ) external;

    /*------------------------------------------------------------------------*/
    /* Refinance API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Refinance a loan by replacing its terms with new terms
     * @param oldLoanTerms Old loan terms
     * @param newLoanTerms New loan terms
     * @param expectedBalance Expected pending balance of old loan
     *
     * The new total tranche amount is the new outstanding balance. When it is
     * greater than the current balance, the difference is a cash-out drawn
     * from the deposit timelock and paid to the borrower. When it is less, the
     * difference is a cash-in pulled from the borrower and repaid to the
     * lenders. The borrower, currency token, collateral, repayment schedule,
     * and the lender holding each tranche position must not change.
     *
     * Lenders must fund cash-out amounts into the deposit timelock under the
     * new loan terms hash before this call. The cash-out covers the cash-in
     * and refinance fee first, so the borrower only needs to approve and hold
     * the amount by which the cash-in plus fee exceeds the cash-out.
     */
    function refinance(
        LoanTermsV2 calldata oldLoanTerms,
        LoanTermsV2 calldata newLoanTerms,
        uint256 expectedBalance
    ) external;

    /*------------------------------------------------------------------------*/
    /* Pause API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Pause
     */
    function pause() external;

    /**
     * @notice Unpause
     */
    function unpause() external;

    /*------------------------------------------------------------------------*/
    /* Rescue ERC20 API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Rescue ERC20 tokens
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount
     */
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external;
}
