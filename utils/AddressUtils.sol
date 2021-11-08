// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

library AddressUtils {
    function isContract(address addr) internal view returns (bool) {
        uint256 size = 0;

        assembly {
            size := extcodesize(addr)
        }

        return size > 0;
    }
}
