// SPDX-License-Identifier: MIT

// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "./ILinkedToILV.sol";

interface IPool is ILinkedToILV {
    struct Deposit {
        uint256 tokenAmount;
        uint256 weight;
        uint64 lockedFrom;
        uint64 lockedUntil;
        bool isYield;
    }

    function silv() external view returns (address);

    function poolToken() external view returns (address);

    function isFlashPool() external view returns (bool);

    function weight() external view returns (uint32);

    function lastYieldDistribution() external view returns (uint64);

    function yieldRewardsPerWeight() external view returns (uint256);

    function usersLockingWeight() external view returns (uint256);

    function pendingYieldRewards(address _user) external view returns (uint256);

    function balanceOf(address _user) external view returns (uint256);

    function getDeposit(address _user, uint256 _depositId)
        external
        view
        returns (Deposit memory);

    function getDepositsLength(address _user) external view returns (uint256);

    function stake(
        uint256 _amount,
        uint64 _lockedUntil,
        bool useSILV
    ) external;

    function unstake(
        uint256 _depositId,
        uint256 _amount,
        bool useSILV
    ) external;

    function sync() external;

    function processRewards(bool useSILV) external;

    function setWeight(uint32 _weight) external;
}
