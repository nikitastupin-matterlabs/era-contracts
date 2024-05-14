// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IBatchAggregator{
    function commitBatch(bytes memory batch) external;
    function returnBatchesAndClearState() external returns(bytes memory);
}