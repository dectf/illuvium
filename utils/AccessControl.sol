// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

contract AccessControl {
    uint256 public constant ROLE_ACCESS_MANAGER =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    uint256 private constant FULL_PRIVILEGES_MASK = type(uint256).max;

    mapping(address => uint256) public userRoles;

    event RoleUpdated(
        address indexed _by,
        address indexed _to,
        uint256 _requested,
        uint256 _actual
    );

    constructor() {
        userRoles[msg.sender] = FULL_PRIVILEGES_MASK;
    }

    function features() public view returns (uint256) {
        return userRoles[address(0)];
    }

    function updateFeatures(uint256 _mask) public {
        updateRole(address(0), _mask);
    }

    function updateRole(address operator, uint256 role) public {
        require(
            isSenderInRole(ROLE_ACCESS_MANAGER),
            "insufficient privileges (ROLE_ACCESS_MANAGER required)"
        );

        userRoles[operator] = evaluateBy(msg.sender, userRoles[operator], role);

        emit RoleUpdated(msg.sender, operator, role, userRoles[operator]);
    }

    function evaluateBy(
        address operator,
        uint256 target,
        uint256 desired
    ) public view returns (uint256) {
        uint256 p = userRoles[operator];

        target |= p & desired;

        target &= FULL_PRIVILEGES_MASK ^ (p & (FULL_PRIVILEGES_MASK ^ desired));

        return target;
    }

    function isFeatureEnabled(uint256 required) public view returns (bool) {
        return __hasRole(features(), required);
    }

    //mike 是否
    function isSenderInRole(uint256 required) public view returns (bool) {
        return isOperatorInRole(msg.sender, required);
    }

    function isOperatorInRole(address operator, uint256 required)
        public
        view
        returns (bool)
    {
        return __hasRole(userRoles[operator], required);
    }

    function __hasRole(uint256 actual, uint256 required)
        internal
        pure
        returns (bool)
    {
        return actual & required == required;
    }
}
