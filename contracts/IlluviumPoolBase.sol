// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../interfaces/IPool.sol";
import "../interfaces/ICorePool.sol";
import "./ReentrancyGuard.sol";
import "./IlluviumPoolFactory.sol";
import "../utils/SafeERC20.sol";
import "../token/EscrowedIlluviumERC20.sol";

abstract contract IlluviumPoolBase is IPool, IlluviumAware, ReentrancyGuard {
    struct User {
        uint256 tokenAmount;
        uint256 totalWeight;
        uint256 subYieldRewards;
        uint256 subVaultRewards;
        Deposit[] deposits;
    }

    mapping(address => User) public users;

    address public immutable override silv;

    IlluviumPoolFactory public immutable factory;

    address public immutable override poolToken;

    uint32 public override weight;

    uint64 public override lastYieldDistribution;

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

    function pendingYieldRewards(address _staker)
        external
        view
        override
        returns (uint256)
    {
        uint256 newYieldRewardsPerWeight;

        if (blockNumber() > lastYieldDistribution && usersLockingWeight != 0) {
            uint256 endBlock = factory.endBlock();
            uint256 multiplier = blockNumber() > endBlock
                ? endBlock - lastYieldDistribution
                : blockNumber() - lastYieldDistribution;
            uint256 ilvRewards = (multiplier * weight * factory.ilvPerBlock()) /
                factory.totalWeight();

            newYieldRewardsPerWeight =
                rewardToWeight(ilvRewards, usersLockingWeight) +
                yieldRewardsPerWeight;
        } else {
            newYieldRewardsPerWeight = yieldRewardsPerWeight;
        }

        User memory user = users[_staker];
        uint256 pending = weightToReward(
            user.totalWeight,
            newYieldRewardsPerWeight
        ) - user.subYieldRewards;

        return pending;
    }

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

    function stake(
        uint256 _amount,
        uint64 _lockUntil,
        bool _useSILV
    ) external override {
        _stake(msg.sender, _amount, _lockUntil, _useSILV, false);
    }

    function unstake(
        uint256 _depositId,
        uint256 _amount,
        bool _useSILV
    ) external override {
        _unstake(msg.sender, _depositId, _amount, _useSILV);
    }

    function updateStakeLock(
        uint256 depositId,
        uint64 lockedUntil,
        bool useSILV
    ) external {
        _sync();
        _processRewards(msg.sender, useSILV, false);

        _updateStakeLock(msg.sender, depositId, lockedUntil);
    }

    function sync() external override {
        _sync();
    }

    function processRewards(bool _useSILV) external virtual override {
        _processRewards(msg.sender, _useSILV, true);
    }

    function setWeight(uint32 _weight) external override {
        require(msg.sender == address(factory), "access denied");

        emit PoolWeightUpdated(msg.sender, weight, _weight);

        weight = _weight;
    }

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

        _sync();

        User storage user = users[_staker];

        if (user.tokenAmount > 0) {
            _processRewards(_staker, _useSILV, false);
        }

        uint256 previousBalance = IERC20(poolToken).balanceOf(address(this));

        transferPoolTokenFrom(address(msg.sender), address(this), _amount);

        uint256 newBalance = IERC20(poolToken).balanceOf(address(this));

        uint256 addedAmount = newBalance - previousBalance;

        uint64 lockFrom = _lockUntil > 0 ? uint64(now256()) : 0;
        uint64 lockUntil = _lockUntil;

        uint256 stakeWeight = (((lockUntil - lockFrom) * WEIGHT_MULTIPLIER) /
            365 days +
            WEIGHT_MULTIPLIER) * addedAmount;

        assert(stakeWeight > 0);

        Deposit memory deposit = Deposit({
            tokenAmount: addedAmount,
            weight: stakeWeight,
            lockedFrom: lockFrom,
            lockedUntil: lockUntil,
            isYield: _isYield
        });

        user.deposits.push(deposit);

        user.tokenAmount += addedAmount;
        user.totalWeight += stakeWeight;
        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );

        usersLockingWeight += stakeWeight;

        emit Staked(msg.sender, _staker, _amount);
    }

    function _unstake(
        address _staker,
        uint256 _depositId,
        uint256 _amount,
        bool _useSILV
    ) internal virtual {
        require(_amount > 0, "zero amount");

        User storage user = users[_staker];

        Deposit storage stakeDeposit = user.deposits[_depositId];

        bool isYield = stakeDeposit.isYield;

        require(stakeDeposit.tokenAmount >= _amount, "amount exceeds stake");

        _sync();

        _processRewards(_staker, _useSILV, false);

        uint256 previousWeight = stakeDeposit.weight;
        uint256 newWeight = (((stakeDeposit.lockedUntil -
            stakeDeposit.lockedFrom) * WEIGHT_MULTIPLIER) /
            365 days +
            WEIGHT_MULTIPLIER) * (stakeDeposit.tokenAmount - _amount);

        if (stakeDeposit.tokenAmount - _amount == 0) {
            delete user.deposits[_depositId];
        } else {
            stakeDeposit.tokenAmount -= _amount;
            stakeDeposit.weight = newWeight;
        }

        user.tokenAmount -= _amount;
        user.totalWeight = user.totalWeight - previousWeight + newWeight;
        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );

        usersLockingWeight = usersLockingWeight - previousWeight + newWeight;

        if (isYield) {
            factory.mintYieldTo(msg.sender, _amount);
        } else {
            transferPoolToken(msg.sender, _amount);
        }

        emit Unstaked(msg.sender, _staker, _amount);
    }

    function _sync() internal virtual {
        if (factory.shouldUpdateRatio()) {
            factory.updateILVPerBlock();
        }

        uint256 endBlock = factory.endBlock();
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

        uint256 currentBlock = blockNumber() > endBlock
            ? endBlock
            : blockNumber();
        uint256 blocksPassed = currentBlock - lastYieldDistribution;
        uint256 ilvPerBlock = factory.ilvPerBlock();

        uint256 ilvReward = (blocksPassed * ilvPerBlock * weight) /
            factory.totalWeight();

        yieldRewardsPerWeight += rewardToWeight(ilvReward, usersLockingWeight);
        lastYieldDistribution = uint64(currentBlock);

        emit Synchronized(
            msg.sender,
            yieldRewardsPerWeight,
            lastYieldDistribution
        );
    }

    function _processRewards(
        address _staker,
        bool _useSILV,
        bool _withUpdate
    ) internal virtual returns (uint256 pendingYield) {
        if (_withUpdate) {
            _sync();
        }

        pendingYield = _pendingYieldRewards(_staker);

        if (pendingYield == 0) return 0;

        User storage user = users[_staker];

        if (_useSILV) {
            mintSIlv(_staker, pendingYield);
        } else if (poolToken == ilv) {
            uint256 depositWeight = pendingYield * YEAR_STAKE_WEIGHT_MULTIPLIER;

            Deposit memory newDeposit = Deposit({
                tokenAmount: pendingYield,
                lockedFrom: uint64(now256()),
                lockedUntil: uint64(now256() + 365 days),
                weight: depositWeight,
                isYield: true
            });
            user.deposits.push(newDeposit);

            user.tokenAmount += pendingYield;
            user.totalWeight += depositWeight;

            usersLockingWeight += depositWeight;
        } else {
            address ilvPool = factory.getPoolAddress(ilv);
            ICorePool(ilvPool).stakeAsPool(_staker, pendingYield);
        }

        if (_withUpdate) {
            user.subYieldRewards = weightToReward(
                user.totalWeight,
                yieldRewardsPerWeight
            );
        }

        emit YieldClaimed(msg.sender, _staker, _useSILV, pendingYield);
    }

    function _updateStakeLock(
        address _staker,
        uint256 _depositId,
        uint64 _lockedUntil
    ) internal {
        require(_lockedUntil > now256(), "lock should be in the future");

        User storage user = users[_staker];

        Deposit storage stakeDeposit = user.deposits[_depositId];

        require(_lockedUntil > stakeDeposit.lockedUntil, "invalid new lock");

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

    function weightToReward(uint256 _weight, uint256 rewardPerWeight)
        public
        pure
        returns (uint256)
    {
        return (_weight * rewardPerWeight) / REWARD_PER_WEIGHT_MULTIPLIER;
    }

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

    function mintSIlv(address _to, uint256 _value) private {
        EscrowedIlluviumERC20(silv).mint(_to, _value);
    }

    function transferPoolToken(address _to, uint256 _value)
        internal
        nonReentrant
    {
        SafeERC20.safeTransfer(IERC20(poolToken), _to, _value);
    }

    function transferPoolTokenFrom(
        address _from,
        address _to,
        uint256 _value
    ) internal nonReentrant {
        SafeERC20.safeTransferFrom(IERC20(poolToken), _from, _to, _value);
    }
}
