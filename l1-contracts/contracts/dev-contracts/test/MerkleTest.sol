// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/libraries/Merkle.sol";

contract MerkleTest {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function calculateRoot(
        bytes32[] calldata _path,
        uint256 _index,
        bytes32 _itemHash
    ) external pure returns (bytes32) {
        return Merkle.calculateRoot(_path, _index, _itemHash);
    }
}
