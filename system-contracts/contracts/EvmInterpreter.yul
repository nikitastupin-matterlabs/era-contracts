object "EVMInterpreter" {
    code {
        /// @dev This function is used to get the initCode.
        /// @dev It assumes that the initCode has been passed via the calldata and so we use the pointer
        /// to obtain the bytecode.
        function getConstructorBytecode() {
            let bytecodeLengthOffset := BYTECODE_OFFSET()
            let bytecodeOffset := add(BYTECODE_OFFSET(), 32)

            loadCalldataIntoActivePtr()

            let size := getActivePtrDataSize()
            mstore(bytecodeLengthOffset, size)

            copyActivePtrData(bytecodeOffset, 0, size)
        }

        // Note that this function modifies EVM memory and does not restore it. It is expected that
        // it is the last called function during execution.
        function setDeployedCode(gasLeft, offset, len) {
            // This error should never be triggered
            // require(offset > 100, "Offset too small");

            mstore8(sub(offset, 100), 0xd9)
            mstore8(sub(offset, 99), 0xeb)
            mstore8(sub(offset, 98), 0x76)
            mstore8(sub(offset, 97), 0xb2)
            mstore(sub(offset, 96), gasLeft)
            mstore(sub(offset, 64), 0x40)
            mstore(sub(offset, 32), len)

            let success := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, sub(offset, 100), add(len, 100), 0, 0)

            if iszero(success) {
                // This error should never happen
                revert(0, 0)
            }
        }

        function padBytecode(offset, len) -> blobOffset, blobLen {
            blobOffset := sub(offset, 32)
            let trueLastByte := add(offset, len)

            mstore(blobOffset, len)
            // clearing out additional bytes
            mstore(trueLastByte, 0)
            mstore(add(trueLastByte, 32), 0)

            blobLen := add(len, 32)

            if iszero(eq(mod(blobLen, 32), 0)) {
                blobLen := add(blobLen, sub(32, mod(blobLen, 32)))
            }

            // Not it is divisible by 32, but we must make sure that the number of 32 byte words is odd
            if iszero(eq(mod(blobLen, 64), 32)) {
                blobLen := add(blobLen, 32)
            }
        }

        function validateCorrectBytecode(offset, len, gasToReturn) -> returnGas {
            if len {
                let firstByte := shr(mload(offset), 248)
                if eq(firstByte, 0xEF) {
                    revert(0, 0)
                }
            }

            let gasForCode := mul(len, 200)
            returnGas := chargeGas(gasToReturn, gasForCode)
        }

        <!-- @include EvmInterpreterFunctions.yul -->

        function simulate(
            isCallerEVM,
            evmGasLeft,
            isStatic,
        ) -> returnOffset, returnLen, retGasLeft {

            returnOffset := MEM_OFFSET_INNER()
            returnLen := 0

            <!-- @include EvmInterpreterLoop.yul -->

            retGasLeft := evmGasLeft
        }

        ////////////////////////////////////////////////////////////////
        //                      FALLBACK
        ////////////////////////////////////////////////////////////////

        let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

        if isStatic {
            revert(0, 0)
        }

        getConstructorBytecode()

        if iszero(isCallerEVM) {
            evmGasLeft := getEVMGas()
        }

        let offset, len, gasToReturn := simulate(isCallerEVM, evmGasLeft, false)

        gasToReturn := validateCorrectBytecode(offset, len, gasToReturn)

        offset, len := padBytecode(offset, len)

        setDeployedCode(gasToReturn, offset, len)
    }
    object "EVMInterpreter_deployed" {
        code {
            <!-- @include EvmInterpreterFunctions.yul -->

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // TALK ABOUT THE DIFFERENCE BETWEEN VERBATIM AND DOING A STATIC CALL.
            // IN SOLIDITY A STATIC CALL IS REPLACED BY A VERBATIM IF THE ADDRES IS ONE
            // OF THE ONES IN THE SYSTEM CONTRACT LIST WHATEVER.
            // IN YUL NO SUCH REPLACEMENTE TAKES PLACE, YOU NEED TO DO THE VERBATIM CALL
            // MANUALLY.

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            // TODO: Check if caller is not EVM and override evmGasLeft and isStatic with their
            // appropriate values if so.

            // First, copy the contract's bytecode to be executed into tEdhe `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

            let returnOffset := MEM_OFFSET_INNER()
            let returnLen := 0

            <!-- @include EvmInterpreterLoop.yul -->

            return(returnOffset, returnLen)
        }
    }
}
