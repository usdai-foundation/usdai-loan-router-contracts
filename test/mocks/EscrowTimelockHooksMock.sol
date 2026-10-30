// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEscrowTimelockHooks} from "src/interfaces/IEscrowTimelockHooks.sol";

contract EscrowTimelockHooksMock is IEscrowTimelockHooks, IERC165, IERC721Receiver {
    enum Mode {
        Record,
        Revert,
        ConsumeAllGas,
        DisableInterface
    }

    struct Call {
        address target;
        bytes32 context;
        address token;
        uint256 amount;
        uint256 interest;
    }

    Mode public mode;
    Call public lastCall;
    uint256 public callCount;

    constructor(
        Mode mode_
    ) {
        mode = mode_;
    }

    function setMode(
        Mode mode_
    ) external {
        mode = mode_;
    }

    function approveSpender(
        address token,
        address spender,
        uint256 amount
    ) external {
        IERC20(token).approve(spender, amount);
    }

    function onEscrowWithdrawn(
        address target,
        bytes32 context,
        address token,
        uint256 amount,
        uint256 interest
    ) external override {
        if (mode == Mode.Revert) revert("hook reverted");
        if (mode == Mode.ConsumeAllGas) {
            while (true) {
                keccak256(abi.encode(block.number, gasleft()));
            }
        }
        callCount++;
        lastCall = Call({target: target, context: context, token: token, amount: amount, interest: interest});
    }

    function onEscrowInterestRepaid(
        address target,
        bytes32 context,
        address token,
        uint256 interest
    ) external override {
        if (mode == Mode.Revert) revert("hook reverted");
        callCount++;
        lastCall = Call({target: target, context: context, token: token, amount: 0, interest: interest});
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external view override returns (bool) {
        if (mode == Mode.DisableInterface) return false;
        return interfaceId == type(IEscrowTimelockHooks).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
