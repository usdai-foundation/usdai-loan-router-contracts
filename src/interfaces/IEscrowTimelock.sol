// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Escrow Timelock Interface
 * @author USD.AI Foundation
 */
interface IEscrowTimelock {
    /*------------------------------------------------------------------------*/
    /* Errors */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Invalid amount
     */
    error InvalidAmount();

    /**
     * @notice Invalid address
     */
    error InvalidAddress();

    /**
     * @notice Invalid bytes32
     */
    error InvalidBytes32();

    /**
     * @notice Invalid deposit
     */
    error InvalidDeposit();

    /**
     * @notice Unsupported token
     */
    error UnsupportedToken();

    /**
     * @notice Invalid caller
     */
    error InvalidCaller();

    /*------------------------------------------------------------------------*/
    /* Events */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Emitted when a deposit is made
     * @param target Target address
     * @param context Context identifier
     * @param amount Amount deposited
     * @param interestRate Interest rate
     */
    event Deposited(address indexed target, bytes32 indexed context, uint256 amount, uint256 interestRate);

    /**
     * @notice Emitted when a deposit is canceled
     * @param target Target address
     * @param context Context identifier
     * @param amount Amount returned
     * @param interest Interest returned
     */
    event Canceled(address indexed target, bytes32 indexed context, uint256 amount, uint256 interest);

    /**
     * @notice Emitted when deposit interest is repaid
     * @param target Target address
     * @param context Context identifier
     * @param interest Interest paid to depositor
     */
    event InterestRepaid(address indexed target, bytes32 indexed context, uint256 interest);

    /**
     * @notice Emitted when a deposit is withdrawn
     * @param withdrawer Withdrawer address
     * @param context Context identifier
     * @param depositAmount Deposit amount
     * @param withdrawAmount Withdraw amount
     * @param interest Interest paid to depositor
     */
    event Withdrawn(
        address indexed withdrawer,
        bytes32 indexed context,
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint256 interest
    );

    /*------------------------------------------------------------------------*/
    /* Getters */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get deposit token address
     * @return Deposit token address
     */
    function depositToken() external view returns (address);

    /**
     * @notice Get depositor address
     * @return Depositor address
     */
    function depositor() external view returns (address);

    /**
     * @notice Get unpaid accrued interest
     * @return Unpaid accrued interest
     */
    function accrued() external view returns (uint256);

    /**
     * @notice Get total deposits
     * @return Total deposits
     */
    function totalDeposits() external view returns (uint256);

    /**
     * @notice Get deposit token ID
     * @param target Target address
     * @param context Context identifier
     * @return Deposit token ID
     */
    function depositTokenId(
        address target,
        bytes32 context
    ) external pure returns (uint256);

    /**
     * @notice Get deposit information
     * @param tokenId Token ID
     * @return target Target address
     * @return context Context identifier
     * @return amount Amount deposited
     * @return interestRate Interest rate
     * @return timestamp Deposit timestamp
     * @return interest Interest owed
     */
    function depositInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            address target,
            bytes32 context,
            uint256 amount,
            uint256 interestRate,
            uint64 timestamp,
            uint256 interest
        );

    /*------------------------------------------------------------------------*/
    /* Depositor API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Deposit tokens with offchain timelock
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount to deposit
     * @param interestRate Interest rate
     */
    function deposit(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint256 interestRate
    ) external;

    /**
     * @notice Cancel deposit
     * @param target Target address
     * @param context Context identifier
     * @return Amount and interest returned
     */
    function cancel(
        address target,
        bytes32 context
    ) external returns (uint256, uint256);

    /*------------------------------------------------------------------------*/
    /* Escrow Admin API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Repay interest owed on a deposit
     * @dev repayInterest() rounds down, cancel() and withdraw() round up
     * @param target Target address
     * @param context Context identifier
     * @param amount Interest amount to repay
     * @return Interest amount repaid (capped at unpaid accrued interest)
     */
    function repayInterest(
        address target,
        bytes32 context,
        uint256 amount
    ) external returns (uint256);

    /*------------------------------------------------------------------------*/
    /* Withdrawer API */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Withdraw deposit
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount to withdraw
     * @return Amount withdrawn and interest paid
     */
    function withdraw(
        bytes32 context,
        address token,
        uint256 amount
    ) external returns (uint256, uint256);
}
