// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAssetRouterBase, SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION, LEGACY_ENCODING_VERSION, NEW_ENCODING_VERSION} from "./IAssetRouterBase.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";

import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {Unauthorized, AssetHandlerDoesNotExist} from "../../common/L1ContractErrors.sol";
import {UnsupportedEncodingVersion, AssetIdNotSupported, AssetHandlerDoesNotExist, Unauthorized, ZeroAddress, TokenNotSupported, AddressAlreadyUsed} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 public immutable L1_CHAIN_ID;

    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    /// @dev Current AssetHandlers: NTV for tokens, Bridgehub for chains.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    /// @dev Current AssetDeploymentTrackers: NTV for tokens, CTMDeploymentTracker for chains.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(uint256 _l1ChainId, uint256 _eraChainId, IBridgehub _bridgehub) {
        L1_CHAIN_ID = _l1ChainId;
        ERA_CHAIN_ID = _eraChainId;
        BRIDGE_HUB = _bridgehub;
    }

    /// @inheritdoc IAssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external virtual override;

    function _setAssetHandlerAddressThisChain(
        address _nativeTokenVault,
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) internal {
        bool senderIsNTV = msg.sender == address(_nativeTokenVault);
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        if (!senderIsNTV && msg.sender != assetDeploymentTracker[assetId]) {
            revert Unauthorized(msg.sender);
        }
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _assetRegistrationData, sender);
    }

    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _originalCaller,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request);

    /*//////////////////////////////////////////////////////////////
                            INITIATTE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) public payable virtual;

    function _bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) internal virtual whenNotPaused {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler == address(0)) {
            revert AssetHandlerDoesNotExist(_assetId);
        }

        // slither-disable-next-line unused-return
        IAssetHandler(assetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _msgValue: 0,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _originalCaller, _assetId, _amount);
    }

    /// @inheritdoc IAssetRouterBase
    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable virtual returns (L2TransactionRequestTwoBridgesInner memory request);

    function _bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data,
        address _nativeTokenVault
    ) internal virtual onlyBridgehub whenNotPaused returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes32 assetId;
        bytes memory transferData;
        bytes1 encodingVersion = _data[0];
        // The new encoding ensures that the calldata is collision-resistant with respect to the legacy format.
        // In the legacy calldata, the first input was the address, meaning the most significant byte was always `0x00`.
        if (encodingVersion == SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION) {
            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _originalCaller,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
        } else if (encodingVersion == LEGACY_ENCODING_VERSION) {
            (assetId, transferData) = _handleLegacyData(_data, _originalCaller);
        } else {
            revert UnsupportedEncodingVersion();
        }

        if (BRIDGE_HUB.baseTokenAssetId(_chainId) == assetId) {
            revert AssetIdNotSupported(assetId);
        }

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _nextMsgValue: _value,
            _assetId: assetId,
            _originalCaller: _originalCaller,
            _transferData: transferData,
            _passValue: true
        });

        bytes32 txDataHash = DataEncoding.encodeTxDataHash({
            _nativeTokenVault: address(_nativeTokenVault),
            _encodingVersion: encodingVersion,
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _transferData: transferData
        });

        request = _requestToBridge({
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _originalCaller,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) public virtual;

    function _finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData,
        address _nativeTokenVault
    ) internal {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            assetHandlerAddress[_assetId] = _nativeTokenVault;
            IAssetHandler(_nativeTokenVault).bridgeMint(_chainId, _assetId, _transferData); // ToDo: Maybe it's better to receive amount and receiver here? transferData may have different encoding
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _nextMsgValue The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _nextMsgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes memory _transferData,
        bool _passValue
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            revert AssetHandlerDoesNotExist(_assetId);
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IAssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _msgValue: _nextMsgValue,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: _transferData
        });
    }

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV.
    /// @dev Is not applicable for custom asset handlers.
    /// @param _data The encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver).
    /// @return Tuple of asset ID and encoded transfer data to conform with new encoding standard.
    function _handleLegacyData(bytes calldata _data, address) internal virtual returns (bytes32, bytes memory);

    /// @dev The request data that is passed to the bridgehub.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        address _originalCaller,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositCalldata(_originalCaller, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) public view virtual returns (bytes memory);

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}