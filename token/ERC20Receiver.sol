// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

interface ERC20Receiver {
    function onERC20Received(
        address _operator,
        address _from,
        uint256 _value,
        bytes calldata _data
    ) external returns (bytes4);
}
