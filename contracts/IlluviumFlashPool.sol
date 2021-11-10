// SPDX-License-Identifier: MIT

pragma solidity 0.8.1;

import "./IlluviumPoolBase.sol";

//mike mainnet 如axie 0x099A3B242dceC87e729cEfc6157632d7D5F1c4ef
//mike 闪电池，和corePool最大区别在于flashPool有endBlock，到时间就关闭挖矿
contract IlluviumFlashPool is IlluviumPoolBase {
    uint64 public endBlock; //mike 池子何时关闭

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

    //mike 本池子是否可以关闭
    function isPoolDisabled() public view returns (bool) {
        return blockNumber() >= endBlock;
    }

    //mike 从里面合约中有调用，然后这里又调用里面合约的具体实现。本合约没有_unstake，就直接用抽象合约中的unstake
    function _stake(
        address _staker,
        uint256 _amount,
        uint64 _lockedUntil,
        bool useSILV,
        bool isYield
    ) internal override {
        //mike 默认lock 365天
        super._stake(
            _staker,
            _amount,
            uint64(now256() + 365 days),
            useSILV,
            isYield
        );
    }

    function _sync() internal override {
        //mike 到了关闭池子的时候，置零退出
        if (isPoolDisabled()) {
            //mike 如果池子在factory那里有权重，直接自己置0
            if (weight != 0) {
                factory.changePoolWeight(address(this), 0);
            }

            return;
        }
        //mike 不然调用底层的sync函数
        super._sync();
    }
}
