// SPDX-License-Identifier: MIT

pragma solidity 0.8.1;

import "./IlluviumPoolBase.sol";

//mike mainnet ilv-eth 0x8B4d8443a0229349A9892D4F7CbE89eF5f843F72
//mike mainnet ilv 0x25121EDDf746c884ddE4619b573A7B10714E2a36
contract IlluviumCorePool is IlluviumPoolBase {
    bool public constant override isFlashPool = false;

    address public vault;

    uint256 public vaultRewardsPerWeight;

    uint256 public poolTokenReserve;

    event VaultRewardsReceived(address indexed _by, uint256 amount);

    event VaultRewardsClaimed(
        address indexed _by,
        address indexed _to,
        uint256 amount
    );

    event VaultUpdated(address indexed _by, address _fromVal, address _toVal);

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

    function pendingVaultRewards(address _staker)
        public
        view
        returns (uint256 pending)
    {
        User memory user = users[_staker];

        return
            weightToReward(user.totalWeight, vaultRewardsPerWeight) -
            user.subVaultRewards;
    }

    function setVault(address _vault) external {
        require(factory.owner() == msg.sender, "access denied");

        require(_vault != address(0), "zero input");

        emit VaultUpdated(msg.sender, vault, _vault);

        vault = _vault;
    }

    function receiveVaultRewards(uint256 _rewardsAmount) external {
        require(msg.sender == vault, "access denied");

        if (_rewardsAmount == 0) {
            return;
        }
        require(usersLockingWeight > 0, "zero locking weight");

        transferIlvFrom(msg.sender, address(this), _rewardsAmount);

        vaultRewardsPerWeight += rewardToWeight(
            _rewardsAmount,
            usersLockingWeight
        );

        if (poolToken == ilv) {
            poolTokenReserve += _rewardsAmount;
        }

        emit VaultRewardsReceived(msg.sender, _rewardsAmount);
    }

    function processRewards(bool _useSILV) external override {
        _processRewards(msg.sender, _useSILV, true);
    }

    function stakeAsPool(address _staker, uint256 _amount) external {
        require(factory.poolExists(msg.sender), "access denied");
        _sync();
        User storage user = users[_staker];
        if (user.tokenAmount > 0) {
            _processRewards(_staker, true, false);
        }
        uint256 depositWeight = _amount * YEAR_STAKE_WEIGHT_MULTIPLIER;
        Deposit memory newDeposit = Deposit({
            tokenAmount: _amount,
            lockedFrom: uint64(now256()),
            lockedUntil: uint64(now256() + 365 days),
            weight: depositWeight,
            isYield: true
        });
        user.tokenAmount += _amount;
        user.totalWeight += depositWeight;
        user.deposits.push(newDeposit);

        usersLockingWeight += depositWeight;

        user.subYieldRewards = weightToReward(
            user.totalWeight,
            yieldRewardsPerWeight
        );
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
        pendingYield = super._processRewards(_staker, _useSILV, _withUpdate);

        if (poolToken == ilv && !_useSILV) {
            poolTokenReserve += pendingYield;
        }
    }

    function _processVaultRewards(address _staker) private {
        User storage user = users[_staker];
        uint256 pendingVaultClaim = pendingVaultRewards(_staker);
        if (pendingVaultClaim == 0) return;

        uint256 ilvBalance = IERC20(ilv).balanceOf(address(this));
        require(
            ilvBalance >= pendingVaultClaim,
            "contract ILV balance too low"
        );

        if (poolToken == ilv) {
            poolTokenReserve -= pendingVaultClaim > poolTokenReserve
                ? poolTokenReserve
                : pendingVaultClaim;
        }

        user.subVaultRewards = weightToReward(
            user.totalWeight,
            vaultRewardsPerWeight
        );

        transferIlv(_staker, pendingVaultClaim);

        emit VaultRewardsClaimed(msg.sender, _staker, pendingVaultClaim);
    }
}
