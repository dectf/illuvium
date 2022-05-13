// SPDX-License-Identifier: MIT

pragma solidity 0.8.1;

import "./IlluviumPoolBase.sol";

//mike mainnet ilv-eth 0x8B4d8443a0229349A9892D4F7CbE89eF5f843F72
//mike mainnet ilv 0x25121EDDf746c884ddE4619b573A7B10714E2a36
//mike 核心池，奖励分为两部分：yield和vault奖励，目前vault奖励没有
contract IlluviumCorePool is IlluviumPoolBase {
    bool public constant override isFlashPool = false;

    address public vault; //mike 目前是0x0，没有vault奖励

    uint256 public vaultRewardsPerWeight; //mike 目前是0，basePool里还有一个yieldReward

    uint256 public poolTokenReserve; //mike 当前池子里的poolToken数

    event VaultRewardsReceived(address indexed _by, uint256 amount);

    event VaultRewardsClaimed(
        address indexed _by,
        address indexed _to,
        uint256 amount
    );

    event VaultUpdated(address indexed _by, address _fromVal, address _toVal);

    //mike 基于basePool初始化
    constructor(
        address _ilv,
        address _silv,
        IlluviumPoolFactory _factory,
        address _poolToken,
        uint64 _initBlock,
        uint32 _weight
    )
        IlluviumPoolBase(_ilv, _silv, _factory, _poolToken, _initBlock, _weight)
    {}

    //mike 查看staker的vault中的pending奖励，0
    function pendingVaultRewards(address _staker)
        public
        view
        returns (uint256 pending)
    {
        User memory user = users[_staker];

        //mike 用户的weight乘以weight单价，再减掉上一次claim的
        return
            weightToReward(user.totalWeight, vaultRewardsPerWeight) -
            user.subVaultRewards;
    }

    //mike 需由factory调用
    function setVault(address _vault) external {
        //mike 多签地址
        require(factory.owner() == msg.sender, "access denied");

        require(_vault != address(0), "zero input");

        emit VaultUpdated(msg.sender, vault, _vault);

        vault = _vault;
    }

    //mike vault转奖励到本合约，然后增加weight的价格
    //mike 目前似乎没有vault来调用
    function receiveVaultRewards(uint256 _rewardsAmount) external {
        //mike vault调用receive
        require(msg.sender == vault, "access denied");

        if (_rewardsAmount == 0) {
            return;
        }
        require(usersLockingWeight > 0, "zero locking weight");
        //mike 从vault转ilv给本地址
        transferIlvFrom(msg.sender, address(this), _rewardsAmount);

        //mike 增加weight的价格
        vaultRewardsPerWeight += rewardToWeight(
            _rewardsAmount,
            usersLockingWeight
        );

        if (poolToken == ilv) {
            //mike 如果本池子是ilv代币
            poolTokenReserve += _rewardsAmount;
        }

        emit VaultRewardsReceived(msg.sender, _rewardsAmount);
    }

    //mike 将自己的ilv收益复投或变为silv
    function processRewards(bool _useSILV) external override {
        _processRewards(msg.sender, _useSILV, true);
    }

    //mike 非ilv的池子来调用ilv池子中的stake函数，帮staker把ilv收益存进ilv池子并mint silv给staker
    function stakeAsPool(address _staker, uint256 _amount) external {
        require(factory.poolExists(msg.sender), "access denied");
        _sync();
        User storage user = users[_staker];
        if (user.tokenAmount > 0) {
            //mike 如果ilv池子中staker有token，mint silv给staker，别的啥也没干，在上面和最下面更新了收益
            _processRewards(_staker, true, false);
        }
        //mike 奖励两倍复投
        uint256 depositWeight = _amount * YEAR_STAKE_WEIGHT_MULTIPLIER;
        Deposit memory newDeposit = Deposit({
            tokenAmount: _amount,
            lockedFrom: uint64(now256()),
            lockedUntil: uint64(now256() + 365 days),
            weight: depositWeight,
            isYield: true //mike ilv可以mint
        });
        user.tokenAmount += _amount;
        user.totalWeight += depositWeight;
        user.deposits.push(newDeposit);

        usersLockingWeight += depositWeight;
        //mike 更新用户的yield打卡点
        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );
        //mike vault奖励似乎一直是0
        user.subVaultRewards = weightToReward(
            user.totalWeight,
            vaultRewardsPerWeight
        );

        poolTokenReserve += _amount;
    }

    function _stake(
        address _staker,
        uint256 _amount,
        uint64 _lockedUntil,
        bool _useSILV,
        bool _isYield
    ) internal override {
        super._stake(_staker, _amount, _lockedUntil, _useSILV, _isYield);
        User storage user = users[_staker];
        //mike 暂时无用
        user.subVaultRewards = weightToReward(
            user.totalWeight,
            vaultRewardsPerWeight
        );

        poolTokenReserve += _amount;
    }

    function _unstake(
        address _staker,
        uint256 _depositId,
        uint256 _amount,
        bool _useSILV
    ) internal override {
        User storage user = users[_staker];
        Deposit memory stakeDeposit = user.deposits[_depositId];
        require(
            stakeDeposit.lockedFrom == 0 || now256() > stakeDeposit.lockedUntil,
            "deposit not yet unlocked"
        );

        poolTokenReserve -= _amount;
        super._unstake(_staker, _depositId, _amount, _useSILV);
        //mike 暂时无用
        user.subVaultRewards = weightToReward(
            user.totalWeight,
            vaultRewardsPerWeight
        );
    }

    function _processRewards(
        address _staker,
        bool _useSILV,
        bool _withUpdate
    ) internal override returns (uint256 pendingYield) {
        _processVaultRewards(_staker);
        //mike 得到staker的pendingYield
        pendingYield = super._processRewards(_staker, _useSILV, _withUpdate);
        //mike 如果是ilv池子并且不使用silv，就把池子token数加上yield
        if (poolToken == ilv && !_useSILV) {
            poolTokenReserve += pendingYield;
        }
    }

    function _processVaultRewards(address _staker) private {
        User storage user = users[_staker];
        //mike 查询可以claim的ilv奖励
        uint256 pendingVaultClaim = pendingVaultRewards(_staker);
        if (pendingVaultClaim == 0) return;

        uint256 ilvBalance = IERC20(ilv).balanceOf(address(this));
        require(
            ilvBalance >= pendingVaultClaim,
            "contract ILV balance too low"
        );
        //mike 如果stake的token就是ilv，需要保证claim的不能超过池子里的ilv余额
        if (poolToken == ilv) {
            poolTokenReserve -= pendingVaultClaim > poolTokenReserve
                ? poolTokenReserve
                : pendingVaultClaim;
        }
        //mike 暂时无用
        user.subVaultRewards = weightToReward(
            user.totalWeight,
            vaultRewardsPerWeight
        );
        //mike 将ilv奖励转给staker
        transferIlv(_staker, pendingVaultClaim);

        emit VaultRewardsClaimed(msg.sender, _staker, pendingVaultClaim);
    }
}
