// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../interfaces/IPool.sol";
import "../interfaces/ICorePool.sol";
import "./ReentrancyGuard.sol";
import "./IlluviumPoolFactory.sol";
import "../utils/SafeERC20.sol";
import "../token/EscrowedIlluviumERC20.sol";

//mike 收益池子的基础合约，其他池子会继承这里
abstract contract IlluviumPoolBase is IPool, IlluviumAware, ReentrancyGuard {
    struct User {
        uint256 tokenAmount; //mike 总的token成本数
        uint256 totalWeight; //mike 总的token成本数对应的weight
        uint256 subYieldRewards; //mike yield奖励
        uint256 subVaultRewards; //mike 似乎只在corePool中使用
        Deposit[] deposits; //mike deposit流水
    }
    //mike 记录用户的stake信息
    mapping(address => User) public users;

    address public immutable override silv; //mike es代币 0x398AeA1c9ceb7dE800284bb399A15e0Efe5A9EC2

    IlluviumPoolFactory public immutable factory;

    address public immutable override poolToken; //mike 本池子的token，可以是ilv，也可以eth-ilv slp

    uint32 public override weight; //mike 当前池子的weight，相较于factory中其他池子而言

    uint64 public override lastYieldDistribution;
    //mike 每weight值多少奖励，只会在sync后逐渐增大
    uint256 public override yieldRewardsPerWeight;

    uint256 public override usersLockingWeight;

    uint256 internal constant WEIGHT_MULTIPLIER = 1e6;

    uint256 internal constant YEAR_STAKE_WEIGHT_MULTIPLIER =
        2 * WEIGHT_MULTIPLIER;

    uint256 internal constant REWARD_PER_WEIGHT_MULTIPLIER = 1e12;

    event Staked(address indexed _by, address indexed _from, uint256 amount);

    event StakeLockUpdated(
        address indexed _by,
        uint256 depositId,
        uint64 lockedFrom,
        uint64 lockedUntil
    );

    event Unstaked(address indexed _by, address indexed _to, uint256 amount);

    event Synchronized(
        address indexed _by,
        uint256 yieldRewardsPerWeight,
        uint64 lastYieldDistribution
    );

    event YieldClaimed(
        address indexed _by,
        address indexed _to,
        bool sIlv,
        uint256 amount
    );

    event PoolWeightUpdated(
        address indexed _by,
        uint32 _fromVal,
        uint32 _toVal
    );

    constructor(
        address _ilv,
        address _silv,
        IlluviumPoolFactory _factory,
        address _poolToken,
        uint64 _initBlock,
        uint32 _weight
    ) IlluviumAware(_ilv) {
        require(_silv != address(0), "sILV address not set");
        require(
            address(_factory) != address(0),
            "ILV Pool fct address not set"
        );
        require(_poolToken != address(0), "pool token address not set");
        require(_initBlock > 0, "init block not set");
        require(_weight > 0, "pool weight not set");

        require(
            EscrowedIlluviumERC20(_silv).TOKEN_UID() ==
                0xac3051b8d4f50966afb632468a4f61483ae6a953b74e387a01ef94316d6b7d62,
            "unexpected sILV TOKEN_UID"
        );

        require(
            _factory.FACTORY_UID() ==
                0xc5cfd88c6e4d7e5c8a03c255f03af23c0918d8e82cac196f57466af3fd4a5ec7,
            "unexpected FACTORY_UID"
        );

        silv = _silv;
        factory = _factory;
        poolToken = _poolToken;
        weight = _weight;

        lastYieldDistribution = _initBlock;
    }

    //mike 查看pending中的yield奖励，跟时间、weight价格和staker拥有的weight有关
    function pendingYieldRewards(address _staker)
        external
        view
        override
        returns (uint256)
    {
        uint256 newYieldRewardsPerWeight;
        //mike 如果还在发放时间范围内
        if (blockNumber() > lastYieldDistribution && usersLockingWeight != 0) {
            uint256 endBlock = factory.endBlock();
            //mike 区块范围
            uint256 multiplier = blockNumber() > endBlock
                ? endBlock - lastYieldDistribution
                : blockNumber() - lastYieldDistribution;
            //mike 这段区块范围内的ilv该分多少给本池子
            uint256 ilvRewards = (multiplier * weight * factory.ilvPerBlock()) /
                factory.totalWeight();
            //mike weight的单价增加一点delta
            newYieldRewardsPerWeight =
                rewardToWeight(ilvRewards, usersLockingWeight) +
                yieldRewardsPerWeight;
        } else {
            newYieldRewardsPerWeight = yieldRewardsPerWeight;
        }

        User memory user = users[_staker];
        //mike 计算pending的收益
        uint256 pending = weightToReward(
            user.totalWeight,
            newYieldRewardsPerWeight
        ) - user.subYieldRewards;

        return pending;
    }

    //mike 看用户stake进来了多少token
    function balanceOf(address _user) external view override returns (uint256) {
        return users[_user].tokenAmount;
    }

    function getDeposit(address _user, uint256 _depositId)
        external
        view
        override
        returns (Deposit memory)
    {
        return users[_user].deposits[_depositId];
    }

    function getDepositsLength(address _user)
        external
        view
        override
        returns (uint256)
    {
        return users[_user].deposits.length;
    }

    //mike 用户stake
    function stake(
        uint256 _amount,
        uint64 _lockUntil,
        bool _useSILV
    ) external override {
        //mike false表示不是yield产生的ilv，只能用已有ilv支付
        _stake(msg.sender, _amount, _lockUntil, _useSILV, false);
    }

    //mike 用户unstake
    function unstake(
        uint256 _depositId,
        uint256 _amount,
        bool _useSILV
    ) external override {
        //mike 调用外面的unstake，外面unstake再调用下面的unstake
        _unstake(msg.sender, _depositId, _amount, _useSILV);
    }

    //mike 所有用户可调，修改锁定期
    function updateStakeLock(
        uint256 depositId,
        uint64 lockedUntil,
        bool useSILV
    ) external {
        //mike 更新weight价格
        _sync();

        _processRewards(msg.sender, useSILV, false);
        //mike 更新某一次deposit流水的锁定期以及boost倍数
        _updateStakeLock(msg.sender, depositId, lockedUntil);
    }

    //mike 更新一下weight价格
    function sync() external override {
        _sync();
    }

    //mike 将ilv奖励进行复投
    function processRewards(bool _useSILV) external virtual override {
        _processRewards(msg.sender, _useSILV, true);
    }

    //mike 必须factory才可以set本池子的weight
    function setWeight(uint32 _weight) external override {
        require(msg.sender == address(factory), "access denied");

        emit PoolWeightUpdated(msg.sender, weight, _weight);

        weight = _weight;
    }

    //mike pending中的yield奖励
    function _pendingYieldRewards(address _staker)
        internal
        view
        returns (uint256 pending)
    {
        User memory user = users[_staker];

        return
            weightToReward(user.totalWeight, yieldRewardsPerWeight) -
            user.subYieldRewards;
    }

    //mike eoa用户发起stake操作，会将poolToken转进来
    function _stake(
        address _staker,
        uint256 _amount,
        uint64 _lockUntil,
        bool _useSILV,
        bool _isYield
    ) internal virtual {
        require(_amount > 0, "zero amount");
        require(
            _lockUntil == 0 ||
                (_lockUntil > now256() && _lockUntil - now256() <= 365 days),
            "invalid lock interval"
        );
        //mike 更新weight价格
        _sync();

        User storage user = users[_staker];

        if (user.tokenAmount > 0) {
            //mike 在上面和最下面更新yield
            _processRewards(_staker, _useSILV, false);
        }
        //mike 先记录池子中原来有多少token
        uint256 previousBalance = IERC20(poolToken).balanceOf(address(this));
        //mike 从sender转一些token到本池子
        transferPoolTokenFrom(address(msg.sender), address(this), _amount);

        uint256 newBalance = IERC20(poolToken).balanceOf(address(this));
        //mike 新-旧，得到转进来了多少
        uint256 addedAmount = newBalance - previousBalance;

        uint64 lockFrom = _lockUntil > 0 ? uint64(now256()) : 0;
        uint64 lockUntil = _lockUntil;
        //mike 计算stake的权重，时间越久或stake越多，权重越大
        uint256 stakeWeight = (((lockUntil - lockFrom) * WEIGHT_MULTIPLIER) /
            365 days +
            WEIGHT_MULTIPLIER) * addedAmount;

        assert(stakeWeight > 0);

        Deposit memory deposit = Deposit({
            tokenAmount: addedAmount,
            weight: stakeWeight,
            lockedFrom: lockFrom,
            lockedUntil: lockUntil,
            isYield: _isYield //mike 是否是yield产生的ilv，是的话，可以mint ilv来支付
        });
        //mike 记录一次用户的deposit日志
        user.deposits.push(deposit);
        //mike 加到用户的amount
        user.tokenAmount += addedAmount;
        //mike 加到用户的weight
        user.totalWeight += stakeWeight;
        //mike 从此刻的rewards开始打卡，后面yieldRewardsPerWeight会逐渐增大
        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );

        usersLockingWeight += stakeWeight; //mike stake进来的权重

        emit Staked(msg.sender, _staker, _amount);
    }

    //mike 用户unstake某次流水中一定数量的token，将对应数量的poolToken转出去
    function _unstake(
        address _staker,
        uint256 _depositId,
        uint256 _amount,
        bool _useSILV
    ) internal virtual {
        require(_amount > 0, "zero amount");

        User storage user = users[_staker];
        //mike 获取用户该次流水中deposit了多少
        Deposit storage stakeDeposit = user.deposits[_depositId];

        bool isYield = stakeDeposit.isYield;

        require(stakeDeposit.tokenAmount >= _amount, "amount exceeds stake");
        //mike 更新一下weight价格
        _sync();
        //mike 收割一下，不更新yield，在最下面更新
        _processRewards(_staker, _useSILV, false);

        uint256 previousWeight = stakeDeposit.weight;
        //mike 更新一下新weight
        uint256 newWeight = (((stakeDeposit.lockedUntil -
            stakeDeposit.lockedFrom) * WEIGHT_MULTIPLIER) /
            365 days +
            WEIGHT_MULTIPLIER) * (stakeDeposit.tokenAmount - _amount);
        //mike 如果全部取出了，就直接删除用户这条deposit信息
        if (stakeDeposit.tokenAmount - _amount == 0) {
            delete user.deposits[_depositId];
        } else {
            stakeDeposit.tokenAmount -= _amount;
            stakeDeposit.weight = newWeight;
        }
        //mike 用户stake的数量减少一点
        user.tokenAmount -= _amount;
        //mike 更新
        user.totalWeight = user.totalWeight - previousWeight + newWeight;
        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );
        //mike 更新一下所有用户的总权重
        usersLockingWeight = usersLockingWeight - previousWeight + newWeight;
        //mike 如果可增发，直接mint，否则从pool里面转
        if (isYield) {
            factory.mintYieldTo(msg.sender, _amount);
        } else {
            transferPoolToken(msg.sender, _amount);
        }

        emit Unstaked(msg.sender, _staker, _amount);
    }

    //mike 总矿厂根据时间间隔挖一下，更新weight价格并更新最近一次收益发放的时间
    function _sync() internal virtual {
        //mike 是否可以同步一下区块奖励
        if (factory.shouldUpdateRatio()) {
            factory.updateILVPerBlock();
        }
        //mike 读取收益的endblock
        uint256 endBlock = factory.endBlock();
        //mike 确认当前区块是否可以sync
        if (lastYieldDistribution >= endBlock) {
            return;
        }
        if (blockNumber() <= lastYieldDistribution) {
            return;
        }

        if (usersLockingWeight == 0) {
            lastYieldDistribution = uint64(blockNumber());
            return;
        }
        //mike 本池子有效的区块号，取小的
        uint256 currentBlock = blockNumber() > endBlock
            ? endBlock
            : blockNumber();
        uint256 blocksPassed = currentBlock - lastYieldDistribution;
        uint256 ilvPerBlock = factory.ilvPerBlock();
        //mike 这段时间内的ilv奖励
        uint256 ilvReward = (blocksPassed * ilvPerBlock * weight) /
            factory.totalWeight();
        //mike 每权重对应的奖励增加一点，相当于修改了weight对应的价格
        yieldRewardsPerWeight += rewardToWeight(ilvReward, usersLockingWeight);
        lastYieldDistribution = uint64(currentBlock);

        emit Synchronized(
            msg.sender,
            yieldRewardsPerWeight,
            lastYieldDistribution
        );
    }

    //mike 处理用户奖励，可以silv形式，也可以双倍复投
    function _processRewards(
        address _staker,
        bool _useSILV,
        bool _withUpdate
    ) internal virtual returns (uint256 pendingYield) {
        //mike 更新weight价格
        if (_withUpdate) {
            _sync();
        }
        //mike 得到pending的yield奖励
        pendingYield = _pendingYieldRewards(_staker);

        if (pendingYield == 0) return 0;

        User storage user = users[_staker];

        if (_useSILV) {
            //mike 将奖励mint成silv给staker
            mintSIlv(_staker, pendingYield);
        } else if (poolToken == ilv) {
            //mike 奖励的部分有两倍的权重
            uint256 depositWeight = pendingYield * YEAR_STAKE_WEIGHT_MULTIPLIER;

            Deposit memory newDeposit = Deposit({
                tokenAmount: pendingYield,
                lockedFrom: uint64(now256()),
                lockedUntil: uint64(now256() + 365 days),
                weight: depositWeight,
                isYield: true //mike 是否是yield产生的ilv，是的话，可增发ilv
            });
            user.deposits.push(newDeposit);

            user.tokenAmount += pendingYield; //mike 用户的stake增加一点
            user.totalWeight += depositWeight; //mike 用户的weight增加更多一点
            usersLockingWeight += depositWeight; //mike 总锁定的weight增加更多一点
        } else {
            //mike token为非ilv情况下
            address ilvPool = factory.getPoolAddress(ilv);
            //mike 以本合约的身份去帮staker将奖励stake到ilv池，实际上是走的ilv池子的第一步，且_withUpdate为false
            ICorePool(ilvPool).stakeAsPool(_staker, pendingYield);
        }
        //mike 更新该用户的yield收益打卡点
        if (_withUpdate) {
            user.subYieldRewards = weightToReward(
                user.totalWeight,
                yieldRewardsPerWeight
            );
        }

        emit YieldClaimed(msg.sender, _staker, _useSILV, pendingYield);
    }

    //@audit
    //mike 更新staker的某一次deposit流水的锁定日期，以及相应的weight倍数
    function _updateStakeLock(
        address _staker,
        uint256 _depositId, //mike 要更新的deposit流水
        uint64 _lockedUntil
    ) internal {
        require(_lockedUntil > now256(), "lock should be in the future");

        User storage user = users[_staker];

        Deposit storage stakeDeposit = user.deposits[_depositId];

        require(_lockedUntil > stakeDeposit.lockedUntil, "invalid new lock");

        //mike 如果没有lockedFrom，就以现在时刻计
        if (stakeDeposit.lockedFrom == 0) {
            require(
                _lockedUntil - now256() <= 365 days,
                "max lock period is 365 days"
            );
            stakeDeposit.lockedFrom = uint64(now256());
        } else {
            require(
                _lockedUntil - stakeDeposit.lockedFrom <= 365 days,
                "max lock period is 365 days"
            );
        }

        stakeDeposit.lockedUntil = _lockedUntil;
        //mike！！ 计算用户新的weight，最大两倍
        uint256 newWeight = (((stakeDeposit.lockedUntil -
            stakeDeposit.lockedFrom) * WEIGHT_MULTIPLIER) /
            365 days +
            WEIGHT_MULTIPLIER) * stakeDeposit.tokenAmount;

        uint256 previousWeight = stakeDeposit.weight;

        stakeDeposit.weight = newWeight;

        user.totalWeight = user.totalWeight - previousWeight + newWeight;
        usersLockingWeight = usersLockingWeight - previousWeight + newWeight;

        emit StakeLockUpdated(
            _staker,
            _depositId,
            stakeDeposit.lockedFrom,
            _lockedUntil
        );
    }

    //mike 计算weight对应的奖励
    function weightToReward(uint256 _weight, uint256 rewardPerWeight)
        public
        pure
        returns (uint256)
    {
        return (_weight * rewardPerWeight) / REWARD_PER_WEIGHT_MULTIPLIER;
    }

    //mike weight单价delta值
    function rewardToWeight(uint256 reward, uint256 rewardPerWeight)
        public
        pure
        returns (uint256)
    {
        return (reward * REWARD_PER_WEIGHT_MULTIPLIER) / rewardPerWeight;
    }

    function blockNumber() public view virtual returns (uint256) {
        return block.number;
    }

    function now256() public view virtual returns (uint256) {
        return block.timestamp;
    }

    //mike mint托管的silv代币给to
    function mintSIlv(address _to, uint256 _value) private {
        EscrowedIlluviumERC20(silv).mint(_to, _value);
    }

    //mike 转移池子中的token代币
    function transferPoolToken(address _to, uint256 _value)
        internal
        nonReentrant
    {
        SafeERC20.safeTransfer(IERC20(poolToken), _to, _value);
    }

    //mike 池子帮助转移token代币
    function transferPoolTokenFrom(
        address _from,
        address _to,
        uint256 _value
    ) internal nonReentrant {
        SafeERC20.safeTransferFrom(IERC20(poolToken), _from, _to, _value);
    }
}
