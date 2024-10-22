// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

struct ZKChainSpecificForceDeploymentsData {
    bytes32 baseTokenAssetId;
    address l2LegacySharedBridge;
    address l2Weth;
}

/// @notice THe structure that describes force deployments that are the same for each chain.
/// @dev Note, that for simplicity, the same struct is used both for upgrading to the 
/// Gateway version and for the Genesis. Some fields may not be used in either of those. 
// solhint-disable-next-line gas-struct-packing
struct FixedForceDeploymentsData {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedL1Governance;
    uint256 maxNumberOfZKChains;
    bytes32 bridgehubBytecodeHash;
    bytes32 l2AssetRouterBytecodeHash;
    bytes32 l2NtvBytecodeHash;
    bytes32 messageRootBytecodeHash;
    bytes32 sloadContractBytecodeHash;
    address l2SharedBridgeLegacyImpl;
    address l2BridgedStandardERC20Impl;
    address l2WethTokenImpl;
}

interface IL2GenesisUpgrade {
    event UpgradeComplete(uint256 _chainId);

    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable;
}
