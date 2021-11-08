// SPDX-License-Identifier: MIT

pragma solidity 0.8.1;

import "./IlluviumPoolBase.sol";

contract IlluviumFlashPool is IlluviumPoolBase {
    uint64 public endBlock;

    bool public constant override isFlashPool = true;

    constructor(
        address _ilv,
        address _silv,
        IlluviumPoolFactory _factory,
        address _poolToken,
        uint64 _initBlock,
        uint32 _weight,
        uint64 _endBlock
    ) IlluviumPoolBase(_ilv, _silv, _factory, _poolToken, _initBlock, _weight) {
        require(
            _endBlock > _initBlock,
            "end block must be higher than init block"
        );

        endBlock = _endBlock;
    }

    function isPoolDisabled() public view returns (bool) {
        return blockNumber() >= endBlock;
    }

    function _stake(
        address _staker,
        uint256 _amount,
        uint64 _lockedUntil,
        bool useSILV,
        bool isYield
    ) internal override {
        super._stake(
            _staker,
            _amount,
            uint64(now256() + 365 days),
            useSILV,
            isYield
        );
    }

    function _sync() internal override {
        if (isPoolDisabled()) {
            if (weight != 0) {
                factory.changePoolWeight(address(this), 0);
            }

            return;
        }

        super._sync();
    }
}
