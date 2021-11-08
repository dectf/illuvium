// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../token/IlluviumERC20.sol";
import "../interfaces/ILinkedToILV.sol";

abstract contract IlluviumAware is ILinkedToILV {
    address public immutable override ilv;

    constructor(address _ilv) {
        require(_ilv != address(0), "ILV address not set");
        require(
            IlluviumERC20(_ilv).TOKEN_UID() ==
                0x83ecb176af7c4f35a45ff0018282e3a05a1018065da866182df12285866f5a2c,
            "unexpected TOKEN_UID"
        );

        ilv = _ilv;
    }

    function transferIlv(address _to, uint256 _value) internal {
        transferIlvFrom(address(this), _to, _value);
    }

    function transferIlvFrom(
        address _from,
        address _to,
        uint256 _value
    ) internal {
        IlluviumERC20(ilv).transferFrom(_from, _to, _value);
    }

    function mintIlv(address _to, uint256 _value) internal {
        IlluviumERC20(ilv).mint(_to, _value);
    }
}
