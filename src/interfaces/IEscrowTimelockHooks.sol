// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Escrow Timelock Callback Hooks
 * @author USD.AI Foundation
 */
interface IEscrowTimelockHooks {
    /**
     * @notice Called when escrow interest is repaid
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param interest Interest paid
     */
    function onEscrowInterestRepaid(
        address target,
        bytes32 context,
        address token,
        uint256 interest
    ) external;

    /**
     * @notice Called when escrow funds are withdrawn
     * @param target Target address
     * @param context Context identifier
     * @param token Token address
     * @param amount Amount withdrawn
     * @param interest Interest paid
     */
    function onEscrowWithdrawn(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint256 interest
    ) external;
}
