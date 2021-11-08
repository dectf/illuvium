// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../utils/ERC20.sol";
import "../utils/AccessControl.sol";

contract EscrowedIlluviumERC20 is
    ERC20("Escrowed Illuvium", "sILV"),
    AccessControl
{
    uint256 public constant TOKEN_UID =
        0xac3051b8d4f50966afb632468a4f61483ae6a953b74e387a01ef94316d6b7d62;

    function mint(address recipient, uint256 amount) external {
        require(
            isSenderInRole(ROLE_TOKEN_CREATOR),
            "insufficient privileges (ROLE_TOKEN_CREATOR required)"
        );
        _mint(recipient, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
