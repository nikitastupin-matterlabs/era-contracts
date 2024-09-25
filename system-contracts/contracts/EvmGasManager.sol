// SPDX-License-Identifier: MIT

// solhint-disable reason-string, gas-custom-errors

pragma solidity ^0.8.0;

import {Utils} from "./libraries/Utils.sol";

import {ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";

// We consider all the contracts (including system ones) as warm.
uint160 constant PRECOMPILES_END = 0xffff;

// Transient storage prefixes
uint256 constant IS_ACCOUNT_EVM_PREFIX = 1 << 255;
uint256 constant IS_ACCOUNT_WARM_PREFIX = 1 << 254;
uint256 constant IS_SLOT_WARM_PREFIX = 1 << 253;

uint256 constant EVM_GAS_SLOT = 4;
uint256 constant EVM_AUX_DATA_SLOT = 5;
uint256 constant EVM_ACTIVE_FRAME_FLAG = 1 << 1;

contract EvmGasManager {
    modifier onlySystemEvm() {
        require(SystemContractHelper.isSystemCall(), "This method requires system call flag");

        // cache use is safe since we do not support SELFDESTRUCT
        uint256 transient_slot = IS_ACCOUNT_EVM_PREFIX | uint256(uint160(msg.sender));
        bool isEVM;
        assembly {
            isEVM := tload(transient_slot)
        }

        if (!isEVM) {
            bytes32 bytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(msg.sender);
            isEVM = Utils.isCodeHashEVM(bytecodeHash);
            if (isEVM) {
                if (!Utils.isContractConstructing(bytecodeHash)) {
                    assembly {
                        tstore(transient_slot, isEVM)
                    }
                }
            }
        }

        require(isEVM, "only system evm");
        _;
    }

    /*
        returns true if the account was already warm
    */
    function warmAccount(address account) external payable onlySystemEvm returns (bool wasWarm) {
        if (uint160(account) < PRECOMPILES_END) return true;
        uint256 transient_slot = IS_ACCOUNT_WARM_PREFIX | uint256(uint160(account));

        assembly {
            wasWarm := tload(transient_slot)

            if iszero(wasWarm) {
                tstore(transient_slot, 1)
            }

            mstore(0x0, wasWarm)
            return(0x0, 0x20)
        }
    }

    function isSlotWarm(uint256 _slot) external view returns (bool isWarm) {
        uint256 prefix = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        uint256 transient_slot;
        assembly {
            mstore(0, prefix)
            mstore(0x20, _slot)
            transient_slot := keccak256(0, 64)
            isWarm := tload(transient_slot)

            mstore(0x0, isWarm)
            return(0x0, 0x20)
        }
    }

    function warmSlot(
        uint256 _slot,
        uint256 _currentValue
    ) external payable onlySystemEvm returns (bool isWarm, uint256 originalValue) {
        uint256 prefix = IS_SLOT_WARM_PREFIX | uint256(uint160(msg.sender));
        uint256 transient_slot;
        assembly {
            mstore(0, prefix)
            mstore(0x20, _slot)
            transient_slot := keccak256(0, 64)

            isWarm := tload(transient_slot)

            switch isWarm
            case 0 {
                originalValue := _currentValue
                tstore(transient_slot, 1)
                tstore(add(transient_slot, 1), originalValue)
            }
            default {
                originalValue := tload(add(transient_slot, 1))
            }

            mstore(0x0, isWarm)
            mstore(0x20, originalValue)
            return(0x0, 0x40)
        }
    }

    /*
    The flow is the following:

    When conducting call:
        1. caller calls to an EVM contract pushEVMFrame with the corresponding gas
        2. callee calls consumeEvmFrame to get the gas and determine if a call is static, frame is marked as used
    */

    function pushEVMFrame(uint256 passGas, bool isStatic) external payable onlySystemEvm {
        assembly {
            tstore(EVM_GAS_SLOT, passGas)
            tstore(EVM_AUX_DATA_SLOT, or(isStatic, EVM_ACTIVE_FRAME_FLAG))
        }
    }

    function consumeEvmFrame() external payable onlySystemEvm returns (uint256 passGas, uint256 auxDataRes) {
        assembly {
            let auxData := tload(EVM_AUX_DATA_SLOT)
            let isFrameActive := and(auxData, EVM_ACTIVE_FRAME_FLAG)

            if isFrameActive {
                passGas := tload(EVM_GAS_SLOT)
                auxDataRes := auxData

                tstore(EVM_AUX_DATA_SLOT, 0) // mark as consumed
            }

            mstore(0x0, passGas)
            mstore(0x20, auxDataRes)
            return(0x0, 0x40)
        }
    }
}
