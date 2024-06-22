// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2TransactionRequestTwoBridgesInner, IBridgehub} from "./IBridgehub.sol";
import {IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";

interface ISTMDeploymentTracker {
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function BRIDGE_HUB() external view returns (IBridgehub);

    function SHARED_BRIDGE() external view returns (IL1SharedBridge);

    function registerSTMAssetOnL1(address _stmAddress) external;

    function getAssetId(address _l1STM) external view returns (bytes32);

    // todo temporary, will move into L1SharedBridge bridgehubDeposit
    function registerSTMAssetOnL2SharedBridge(
        uint256 _chainId,
        address _stmL1Address,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByteLimit,
        address _refundRecipient
    ) external payable;
}