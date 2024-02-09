import { expect } from "chai";
import { ethers, Wallet } from "ethers";
import * as hardhat from "hardhat";
import { ADDRESS_ONE, getTokens } from "../../scripts/utils";
import type { TestnetERC20Token, WETH9 } from "../../typechain";
import { TestnetERC20TokenFactory, WETH9Factory } from "../../typechain";

import type { IBridgehub } from "../../typechain/IBridgehub";
import { IBridgehubFactory } from "../../typechain/IBridgehubFactory";
import { CONTRACTS_LATEST_PROTOCOL_VERSION, getCallRevertReason, initialDeployment } from "./utils";

import * as fs from "fs";
// import { EraLegacyChainId, EraLegacyDiamondProxyAddress } from "../../src.ts/deploy";
import { hashL2Bytecode } from "../../src.ts/utils";
import type { Deployer } from "../../src.ts/deploy";

import { Interface } from "ethers/lib/utils";
import type { IL1SharedBridge } from "../../typechain/IL1SharedBridge";
import { IL1SharedBridgeFactory } from "../../typechain/IL1SharedBridgeFactory";

const testConfigPath = "./test/test_config/constant";
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";
// eslint-disable-next-line @typescript-eslint/no-var-requires
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = CONTRACTS_LATEST_PROTOCOL_VERSION;

export async function create2DeployFromL1(
  bridgehub: IBridgehub,
  chainId: ethers.BigNumberish,
  walletAddress: string,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish
) {
  const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);
  const gasPrice = await bridgehub.provider.getGasPrice();
  const expectedCost = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );
  const l1GasPriceConverted = await bridgehub.provider.getGasPrice();

  await bridgehub.requestL2TransactionDirect(
    {
      chainId,
      l2Contract: DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
      mintValue: expectedCost,
      l2Value: 0,
      l2Calldata: calldata,
      l2GasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      l1GasPriceConverted,
      factoryDeps: [bytecode],
      refundRecipient: walletAddress,
    },
    { value: expectedCost, gasPrice }
  );
}

describe("Custom base token chain and bridge tests", () => {
  let owner: ethers.Signer;
  let randomSigner: ethers.Signer;
  let deployWallet: Wallet;
  let deployer: Deployer;
  let l1SharedBridge: IL1SharedBridge;
  let bridgehub: IBridgehub;
  let baseToken: TestnetERC20Token;
  let baseTokenAddress: string;
  let altTokenAddress: string;
  let altToken: TestnetERC20Token;
  let wethTokenAddress: string;
  let wethToken: WETH9;
  let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID ? parseInt(process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID) : 270;

  before(async () => {
    [owner, randomSigner] = await hardhat.ethers.getSigners();

    deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic4, "m/44'/60'/0'/0/1").connect(owner.provider);
    const ownerAddress = await deployWallet.getAddress();

    const gasPrice = await owner.provider.getGasPrice();

    const tx = {
      from: owner.getAddress(),
      to: deployWallet.address,
      value: ethers.utils.parseEther("1000"),
      nonce: owner.getTransactionCount(),
      gasLimit: 100000,
      gasPrice: gasPrice,
    };

    await owner.sendTransaction(tx);
    // note we can use initialDeployment so we don't go into deployment details here
    deployer = await initialDeployment(deployWallet, ownerAddress, gasPrice, [], "BAT");
    chainId = deployer.chainId;
    bridgehub = IBridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployWallet);

    const tokens = getTokens("hardhat");
    baseTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "BAT")!.address;
    baseToken = TestnetERC20TokenFactory.connect(baseTokenAddress, owner);

    altTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "DAI")!.address;
    altToken = TestnetERC20TokenFactory.connect(altTokenAddress, owner);

    wethTokenAddress = await deployer.defaultSharedBridge(deployWallet).l1WethAddress();
    wethToken = WETH9Factory.connect(wethTokenAddress, owner);

    // prepare the bridge
    l1SharedBridge = IL1SharedBridgeFactory.connect(deployer.addresses.Bridges.SharedBridgeProxy, deployWallet);
  });

  it("Should have correct base token", async () => {
    // we should still be able to deploy the erc20 bridge
    const baseTokenAddressInBridgehub = await bridgehub.baseToken(chainId);
    expect(baseTokenAddress).equal(baseTokenAddressInBridgehub);
  });

  it("Check should initialize through governance", async () => {
    const l1SharedBridgeInterface = new Interface(hardhat.artifacts.readArtifactSync("L1SharedBridge").abi);
    const upgradeCall = l1SharedBridgeInterface.encodeFunctionData(
      "initializeChainGovernance(uint256,address)",
      [chainId, ADDRESS_ONE]
    );

    const txHash = await deployer.executeUpgrade(l1SharedBridge.address, 0, upgradeCall);

    expect(txHash).not.equal(ethers.constants.HashZero);
  });

  it("Should not allow direct deposits", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge
        .connect(randomSigner)
        .depositLegacyErc20Bridge(await randomSigner.getAddress(), await randomSigner.getAddress(), baseTokenAddress, 0, 0, 0, 0, ethers.constants.AddressZero)
    );

    expect(revertReason).equal("ShB not legacy bridge");
  });

  it("Should deposit base token successfully direct via bridgehub", async () => {
    await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), ethers.utils.parseUnits("800", 18));
    await (
      await baseToken.connect(randomSigner).approve(l1SharedBridge.address, ethers.utils.parseUnits("800", 18))
    ).wait();
    const l1GasPriceConverted = await bridgehub.provider.getGasPrice();
    await bridgehub.connect(randomSigner).requestL2TransactionDirect({
      chainId,
      l2Contract: await randomSigner.getAddress(),
      mintValue: ethers.utils.parseUnits("800", 18),
      l2Value: 1,
      l2Calldata: "0x",
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      l1GasPriceConverted,
      factoryDeps: [],
      refundRecipient: await randomSigner.getAddress(),
    });
  });

  it("Should deposit alternative token successfully twoBridges method", async () => {
    const altTokenAmount = ethers.utils.parseUnits("800", 18);
    const baseTokenAmount = ethers.utils.parseUnits("800", 18);

    await altToken.connect(randomSigner).mint(await randomSigner.getAddress(), altTokenAmount);
    await (await altToken.connect(randomSigner).approve(l1SharedBridge.address, altTokenAmount)).wait();

    await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), baseTokenAmount);
    await (await baseToken.connect(randomSigner).approve(l1SharedBridge.address, baseTokenAmount)).wait();
    const l1GasPriceConverted = await bridgehub.provider.getGasPrice();
    await bridgehub.connect(randomSigner).requestL2TransactionTwoBridges({
      chainId,
      mintValue: baseTokenAmount,
      l2Value: 1,
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      l1GasPriceConverted,
      refundRecipient: await randomSigner.getAddress(),
      secondBridgeAddress: l1SharedBridge.address,
      secondBridgeValue: 0,
      secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "address"],
        [altTokenAddress, altTokenAmount, await randomSigner.getAddress()]
      ),
    });
  });

  it("Should deposit weth token successfully twoBridges method", async () => {
    const wethTokenAmount = ethers.utils.parseUnits("800", 18);
    const baseTokenAmount = ethers.utils.parseUnits("800", 18);

    await (await wethToken.connect(randomSigner).deposit({ value: wethTokenAmount })).wait();
    await (await wethToken.connect(randomSigner).approve(l1SharedBridge.address, wethTokenAmount)).wait();

    await (await baseToken.connect(randomSigner).mint(await randomSigner.getAddress(), baseTokenAmount)).wait();
    await (await baseToken.connect(randomSigner).approve(l1SharedBridge.address, baseTokenAmount)).wait();
    const l1GasPriceConverted = await bridgehub.provider.getGasPrice();

    await bridgehub.connect(randomSigner).requestL2TransactionTwoBridges({
      chainId,
      mintValue: baseTokenAmount,
      l2Value: 1,
      l2GasLimit: 10000000,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      l1GasPriceConverted,
      refundRecipient: await randomSigner.getAddress(),
      secondBridgeAddress: l1SharedBridge.address,
      secondBridgeValue: 0,
      secondBridgeCalldata: ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "address"],
        [wethTokenAddress, wethTokenAmount, await randomSigner.getAddress()]
      ),
    });
  });

  it("Should revert on finalizing a withdrawal with wrong message length", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, "0x", [])
    );
    expect(revertReason).equal("ShB wrong msg len");
  });

  it("Should revert on finalizing a withdrawal with wrong function selector", async () => {
    const revertReason = await getCallRevertReason(
      l1SharedBridge.connect(randomSigner).finalizeWithdrawal(chainId, 0, 0, 0, ethers.utils.randomBytes(96), [])
    );
    expect(revertReason).equal("ShB Incorrect message function selector");
  });
});
