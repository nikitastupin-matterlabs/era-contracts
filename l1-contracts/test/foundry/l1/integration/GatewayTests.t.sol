// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, BridgehubMintCTMAssetData, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IncorrectBridgeHubAddress} from "contracts/common/L1ContractErrors.sol";

contract GatewayTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, GatewayDeployer {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    uint256 migratingChainId = 10;
    uint256 gatewayChainId = 11;
    uint256 mintChainId = 12;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        _deployZKChain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[1]);
        // _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
            // _registerL2SharedBridge(zkChainIds[i], contractAddress);
        }

        _initializeGatewayScript();

        // console.log("KL todo", Ownable(l1Script.getBridgehubProxyAddress()).owner(), l1Script.getBridgehubProxyAddress());
        vm.deal(Ownable(l1Script.getBridgehubProxyAddress()).owner(), 100000000000000000000000000000000000);
        vm.deal(l1Script.getOwnerAddress(), 100000000000000000000000000000000000);
        IZKChain chain = IZKChain(IBridgehub(l1Script.getBridgehubProxyAddress()).getZKChain(migratingChainId));
        IZKChain chain2 = IZKChain(IBridgehub(l1Script.getBridgehubProxyAddress()).getZKChain(gatewayChainId));
        vm.deal(chain.getAdmin(), 100000000000000000000000000000000000);
        vm.deal(chain2.getAdmin(), 100000000000000000000000000000000000);

        // console.log("kl todo balance", Ownable(l1Script.getBridgehubProxyAddress()).owner().balance);
        // vm.deal(msg.sender, 100000000000000000000000000000000000);
        // vm.deal(l1Script.getBridgehubProxyAddress(), 100000000000000000000000000000000000);
    }

    function setUp() public {
        prepare();
    }

    //
    function test_registerGateway() public {
        gatewayScript.registerGateway();
    }

    //
    function test_moveChainToGateway() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();
        // require(bridgehub.settlementLayer())
    }

    function test_l2Registration() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();
        gatewayScript.registerL2Contracts();
    }

    function test_finishMoveChain() public {
        finishMoveChain();
    }

    function test_startMessageToL3() public {
        finishMoveChain();
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        uint256 expectedValue = 1000000000000000000000;

        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect(
            migratingChainId,
            expectedValue,
            0,
            72000000,
            800,
            "0x"
        );
        bridgehub.requestL2TransactionDirect{value: expectedValue}(request);
    }

    function test_forwardToL3OnGateway() public {
        finishMoveChain();

        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        vm.chainId(12345);
        vm.startBroadcast(SETTLEMENT_LAYER_RELAY_SENDER);
        bridgehub.forwardTransactionOnGateway(mintChainId, bytes32(0), 0);
        vm.stopBroadcast();
    }

    function test_recoverFromFailedChainMigration() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();

        // Setup
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        IChainTypeManager ctm = IChainTypeManager(l1Script.getCTM());
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);
        bytes memory transferData;

        {
            IZKChain chain = IZKChain(bridgehub.getZKChain(migratingChainId));
            bytes memory initialDiamondCut = l1Script.getInitialDiamondCutData();
            bytes memory chainData = abi.encode(chain.getProtocolVersion());
            bytes memory ctmData = abi.encode(address(1), msg.sender, ctm.protocolVersion(), initialDiamondCut);
            BridgehubBurnCTMAssetData memory data = BridgehubBurnCTMAssetData({
                chainId: migratingChainId,
                ctmData: ctmData,
                chainData: chainData
            });
            transferData = abi.encode(data);
        }

        address chainAdmin = IZKChain(bridgehub.getZKChain(migratingChainId)).getAdmin();
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.sharedBridge()));
        bytes32 l2TxHash = keccak256("l2TxHash");
        uint256 l2BatchNumber = 5;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes32[] memory merkleProof = new bytes32[](1);
        bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(chainAdmin, assetId, transferData)));

        // Mock Call for Msg Inclusion
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                migratingChainId,
                l2TxHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );

        // Set Deposit Happened
        vm.startBroadcast(address(bridgeHub));
        assetRouter.bridgehubConfirmL2Transaction({
            _chainId: migratingChainId,
            _txDataHash: txDataHash,
            _txHash: l2TxHash
        });
        vm.stopBroadcast();

        vm.startBroadcast();
        l1Nullifier.bridgeRecoverFailedTransfer({
            _chainId: migratingChainId,
            _depositSender: chainAdmin,
            _assetId: assetId,
            _assetData: transferData,
            _l2TxHash: l2TxHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
        vm.stopBroadcast();
    }

    function test_registerAlreadyDeployedZKChain() public {
        gatewayScript.registerGateway();
        IChainTypeManager stm = IChainTypeManager(l1Script.getCTM());
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        address owner = Ownable(address(bridgeHub)).owner();

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);

            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                address(bridgehub.sharedBridge()),
                owner,
                stm.protocolVersion(),
                stm.storedBatchZero(),
                address(bridgehub)
            );

            address stmAddr = IZKChain(chain).getChainTypeManager();

            vm.startBroadcast(owner);
            bridgeHub.addChainTypeManager(stmAddr);
            bridgeHub.addTokenAssetId(baseTokenAssetId);
            bridgeHub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();

            address bridgeHubStmForChain = bridgeHub.chainTypeManager(chainId);
            bytes32 bridgeHubBaseAssetIdForChain = bridgeHub.baseTokenAssetId(chainId);
            address bridgeHubChainAddressdForChain = bridgeHub.getZKChain(chainId);
            address bhAddr = IZKChain(chain).getBridgehub();

            assertEq(bridgeHubStmForChain, stmAddr);
            assertEq(bridgeHubBaseAssetIdForChain, baseTokenAssetId);
            assertEq(bridgeHubChainAddressdForChain, chain);
            assertEq(bhAddr, address(bridgeHub));
        }

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);
            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                address(bridgehub.sharedBridge()),
                owner,
                stm.protocolVersion(),
                stm.storedBatchZero(),
                address(bridgehub.sharedBridge())
            );

            address stmAddr = IZKChain(chain).getChainTypeManager();

            vm.startBroadcast(owner);
            bridgeHub.addTokenAssetId(baseTokenAssetId);
            vm.expectRevert(
                abi.encodeWithSelector(IncorrectBridgeHubAddress.selector, address(bridgehub.sharedBridge()))
            );
            bridgeHub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();
        }
    }

    function finishMoveChain() public {
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        IChainTypeManager ctm = IChainTypeManager(l1Script.getCTM());
        IZKChain migratingChain = IZKChain(bridgehub.getZKChain(migratingChainId));
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(migratingChainId);

        vm.startBroadcast(Ownable(address(bridgehub)).owner());
        bridgehub.registerSettlementLayer(gatewayChainId, true);
        vm.stopBroadcast();

        bytes32 baseTokenAssetId = keccak256("baseTokenAssetId");
        bytes memory initialDiamondCut = l1Script.getInitialDiamondCutData();
        bytes memory chainData = abi.encode(AdminFacet(address(migratingChain)).prepareChainCommitment());
        bytes memory ctmData = abi.encode(baseTokenAssetId, msg.sender, ctm.protocolVersion(), initialDiamondCut);
        BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
            chainId: mintChainId,
            baseTokenAssetId: baseTokenAssetId,
            ctmData: ctmData,
            chainData: chainData
        });
        bytes memory bridgehubMintData = abi.encode(data);
        vm.startBroadcast(address(bridgehub.sharedBridge()));
        uint256 currentChainId = block.chainid;
        vm.chainId(migratingChainId);
        bridgehub.bridgeMint(gatewayChainId, assetId, bridgehubMintData);
        vm.stopBroadcast();
        vm.chainId(currentChainId);

        assertEq(bridgehub.baseTokenAssetId(mintChainId), baseTokenAssetId);
        IZKChain mintedZKChain = IZKChain(bridgehub.getZKChain(mintChainId));
        assertEq(mintedZKChain.getBaseTokenAssetId(), baseTokenAssetId);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
