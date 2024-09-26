// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_MESSAGE_ROOT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

struct SystemContractsArgs {
    uint256 l1ChainId;
    uint256 eraChainId;
    address l1AssetRouter;
    address legacySharedBridge;
    address l2TokenBeacon;
    bytes32 l2TokenProxyBytecodeHash;
    address aliasedOwner;
    bool contractsDeployedAlready;
}

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    address internal constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);

    string internal constant L2_ASSET_ROUTER_PATH = "./zkout/L2AssetRouter.sol/L2AssetRouter.json";
    string internal constant L2_NATIVE_TOKEN_VAULT_PATH = "./zkout/L2NativeTokenVault.sol/L2NativeTokenVault.json";
    string internal constant BRIDGEHUB_PATH = "./zkout/Bridgehub.sol/Bridgehub.json";

    /// @notice Returns the bytecode of a given era contract from a `zkout` folder.
    function readEraBytecode(string memory _filename) internal returns (bytes memory bytecode) {
        string memory artifact = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat("./zkout/", _filename, ".sol/", _filename, ".json")
        );

        bytecode = vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    /// @notice Returns the bytecode of a given system contract.
    function readSystemContractsBytecode(string memory _filename) internal view returns (bytes memory) {
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/",
                _filename,
                ".sol/",
                _filename,
                ".json"
            )
        );
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
    }

    /**
     * @dev Initializes the system contracts.
     * @dev It is a hack needed to make the tests be able to call system contracts directly.
     */
    function initSystemContracts(SystemContractsArgs memory _args) internal {
        bytes memory contractDeployerBytecode = readSystemContractsBytecode("ContractDeployer");
        vm.etch(DEPLOYER_SYSTEM_CONTRACT, contractDeployerBytecode);
        forceDeploySystemContracts(_args);
    }

    function forceDeploySystemContracts(
        SystemContractsArgs memory _args
    ) internal {
        forceDeployBridgehub(_args.l1ChainId, _args.eraChainId, _args.aliasedOwner, _args.l1AssetRouter, _args.legacySharedBridge);
        forceDeployAssetRouter(_args.l1ChainId, _args.eraChainId, _args.aliasedOwner,_args.l1AssetRouter, _args.legacySharedBridge);
        forceDeployNativeTokenVault(_args.l1ChainId, _args.aliasedOwner, _args.l2TokenProxyBytecodeHash, _args.legacySharedBridge, _args.l2TokenBeacon, _args.contractsDeployedAlready);
    }

    function forceDeployBridgehub(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1AssetRouter,
        address _legacySharedBridge
    ) internal {
        new Bridgehub(_l1ChainId, _aliasedOwner, 100);
        forceDeployWithConstructor("Bridgehub", L2_BRIDGEHUB_ADDR, abi.encode(_l1ChainId, _aliasedOwner, 100));
        Bridgehub bridgehub = Bridgehub(L2_BRIDGEHUB_ADDR);
        address l1CTMDeployer = address(0x1);
        vm.prank(_aliasedOwner);
        bridgehub.setAddresses(L2_ASSET_ROUTER_ADDR, ICTMDeploymentTracker(l1CTMDeployer), IMessageRoot(L2_MESSAGE_ROOT_ADDR));
    }

    /// @notice Deploys the L2AssetRouter contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _eraChainId The chain ID of the era chain.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    function forceDeployAssetRouter(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1AssetRouter,
        address _legacySharedBridge
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2AssetRouter(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner);
        }
        forceDeployWithConstructor("L2AssetRouter", L2_ASSET_ROUTER_ADDR, abi.encode(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner));

    }

    /// @notice Deploys the L2NativeTokenVault contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _aliasedOwner The address of the aliased owner.
    /// @param _l2TokenProxyBytecodeHash The hash of the L2 token proxy bytecode.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    /// @param _l2TokenBeacon The address of the L2 token beacon.
    /// @param _contractsDeployedAlready Whether the contracts are deployed already.
    function forceDeployNativeTokenVault(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _l2TokenBeacon,
        bool _contractsDeployedAlready
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2NativeTokenVault({
                _l1ChainId: _l1ChainId,
                _aliasedOwner: _aliasedOwner,
                _l2TokenProxyBytecodeHash: _l2TokenProxyBytecodeHash,
                _legacySharedBridge: _legacySharedBridge,
                _bridgedTokenBeacon: _l2TokenBeacon,
                _contractsDeployedAlready: _contractsDeployedAlready,
                _wethToken: address(0),
                _baseTokenAssetId: ethAssetId
            });
        }
        forceDeployWithConstructor("L2NativeTokenVault", L2_NATIVE_TOKEN_VAULT_ADDR, abi.encode(_l1ChainId, _aliasedOwner, _l2TokenProxyBytecodeHash, _legacySharedBridge, _l2TokenBeacon, _contractsDeployedAlready, address(0), ethAssetId));
    }

    function forceDeployWithConstructor(
        string memory _contractName,
        address _address,
        bytes memory _constuctorArgs
    ) public {
        bytes memory bytecode = readEraBytecode(_contractName);

        bytes32 bytecodehash = L2ContractHelper.hashL2Bytecode(bytecode);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: bytecodehash,
            newAddress: _address,
            callConstructor: true,
            value: 0,
            input: _constuctorArgs
        });

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses(deployments);
    }

    function deploySharedBridgeLegacy(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash
    ) internal returns (address) {
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);

        L2SharedBridgeLegacy bridge = new L2SharedBridgeLegacy();
        console.log("bridge", address(bridge));
        address proxyAdmin = address(0x1);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(bridge),
            proxyAdmin,
            abi.encodeWithSelector(
                L2SharedBridgeLegacy.initialize.selector,
                _l1SharedBridge,
                _l2TokenProxyBytecodeHash,
                _aliasedOwner
            )
        );
        console.log("proxy", address(proxy));
        return address(proxy);
    }

    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }
}