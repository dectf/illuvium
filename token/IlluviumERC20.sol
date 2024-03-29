// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../utils/AddressUtils.sol";
import "../utils/AccessControl.sol";
import "./ERC20Receiver.sol";

//mike mainnet 0x767FE9EDC9E0dF98E07454847909b5E959D7ca0E
//mike 集成了delegate的ilv
contract IlluviumERC20 is AccessControl {
    uint256 public constant TOKEN_UID =
        0x83ecb176af7c4f35a45ff0018282e3a05a1018065da866182df12285866f5a2c;

    string public constant name = "Illuvium";

    string public constant symbol = "ILV";

    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public tokenBalances;

    mapping(address => address) public votingDelegates;

    struct VotingPowerRecord {
        uint64 blockNumber;
        uint192 votingPower;
    }

    mapping(address => VotingPowerRecord[]) public votingPowerHistory;

    mapping(address => uint256) public nonces;

    mapping(address => mapping(address => uint256)) public transferAllowances;

    uint32 public constant FEATURE_TRANSFERS = 0x0000_0001;

    uint32 public constant FEATURE_TRANSFERS_ON_BEHALF = 0x0000_0002;

    uint32 public constant FEATURE_UNSAFE_TRANSFERS = 0x0000_0004;

    uint32 public constant FEATURE_OWN_BURNS = 0x0000_0008;

    uint32 public constant FEATURE_BURNS_ON_BEHALF = 0x0000_0010;

    uint32 public constant FEATURE_DELEGATIONS = 0x0000_0020;

    uint32 public constant FEATURE_DELEGATIONS_ON_BEHALF = 0x0000_0040;

    uint32 public constant ROLE_TOKEN_CREATOR = 0x0001_0000;

    uint32 public constant ROLE_TOKEN_DESTROYER = 0x0002_0000;

    uint32 public constant ROLE_ERC20_RECEIVER = 0x0004_0000;

    uint32 public constant ROLE_ERC20_SENDER = 0x0008_0000;

    bytes4 private constant ERC20_RECEIVED = 0x4fc35859;

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegate,uint256 nonce,uint256 expiry)");

    event Transfer(address indexed _from, address indexed _to, uint256 _value);

    event Approval(
        address indexed _owner,
        address indexed _spender,
        uint256 _value
    );

    event Minted(address indexed _by, address indexed _to, uint256 _value);

    event Burnt(address indexed _by, address indexed _from, uint256 _value);

    event Transferred(
        address indexed _by,
        address indexed _from,
        address indexed _to,
        uint256 _value
    );

    event Approved(
        address indexed _owner,
        address indexed _spender,
        uint256 _oldValue,
        uint256 _value
    );

    event DelegateChanged(
        address indexed _of,
        address indexed _from,
        address indexed _to
    );

    event VotingPowerChanged(
        address indexed _of,
        uint256 _fromVal,
        uint256 _toVal
    );

    constructor(address _initialHolder) {
        require(
            _initialHolder != address(0),
            "_initialHolder not set (zero address)"
        );

        mint(_initialHolder, 7_000_000e18);
    }

    function balanceOf(address _owner) public view returns (uint256 balance) {
        return tokenBalances[_owner];
    }

    function transfer(address _to, uint256 _value)
        public
        returns (bool success)
    {
        return transferFrom(msg.sender, _to, _value);
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public returns (bool success) {
        if (
            isFeatureEnabled(FEATURE_UNSAFE_TRANSFERS) ||
            isOperatorInRole(_to, ROLE_ERC20_RECEIVER) ||
            isSenderInRole(ROLE_ERC20_SENDER)
        ) {
            unsafeTransferFrom(_from, _to, _value);
        } else {
            safeTransferFrom(_from, _to, _value, "");
        }

        return true;
    }

    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _value,
        bytes memory _data
    ) public {
        unsafeTransferFrom(_from, _to, _value);
        //mike 如果to是一个合约地址，需要保证收到了token
        if (AddressUtils.isContract(_to)) {
            bytes4 response = ERC20Receiver(_to).onERC20Received(
                msg.sender,
                _from,
                _value,
                _data
            );

            require(
                response == ERC20_RECEIVED,
                "invalid onERC20Received response"
            );
        }
    }

    function unsafeTransferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public {
        require(
            (_from == msg.sender && isFeatureEnabled(FEATURE_TRANSFERS)) ||
                (_from != msg.sender &&
                    isFeatureEnabled(FEATURE_TRANSFERS_ON_BEHALF)),
            _from == msg.sender
                ? "transfers are disabled"
                : "transfers on behalf are disabled"
        );

        require(_from != address(0), "ERC20: transfer from the zero address");

        require(_to != address(0), "ERC20: transfer to the zero address");

        require(
            _from != _to,
            "sender and recipient are the same (_from = _to)"
        );

        require(
            _to != address(this),
            "invalid recipient (transfer to the token smart contract itself)"
        );

        if (_value == 0) {
            emit Transfer(_from, _to, _value);

            return;
        }

        if (_from != msg.sender) {
            uint256 _allowance = transferAllowances[_from][msg.sender];

            require(
                _allowance >= _value,
                "ERC20: transfer amount exceeds allowance"
            );

            _allowance -= _value;

            transferAllowances[_from][msg.sender] = _allowance;

            emit Approved(_from, msg.sender, _allowance + _value, _allowance);

            emit Approval(_from, msg.sender, _allowance);
        }

        require(
            tokenBalances[_from] >= _value,
            "ERC20: transfer amount exceeds balance"
        );

        tokenBalances[_from] -= _value;

        tokenBalances[_to] += _value;

        __moveVotingPower(votingDelegates[_from], votingDelegates[_to], _value);

        emit Transferred(msg.sender, _from, _to, _value);

        emit Transfer(_from, _to, _value);
    }

    function approve(address _spender, uint256 _value)
        public
        returns (bool success)
    {
        require(_spender != address(0), "ERC20: approve to the zero address");

        uint256 _oldValue = transferAllowances[msg.sender][_spender];

        transferAllowances[msg.sender][_spender] = _value;

        emit Approved(msg.sender, _spender, _oldValue, _value);

        emit Approval(msg.sender, _spender, _value);

        return true;
    }

    function allowance(address _owner, address _spender)
        public
        view
        returns (uint256 remaining)
    {
        return transferAllowances[_owner][_spender];
    }

    function increaseAllowance(address _spender, uint256 _value)
        public
        virtual
        returns (bool)
    {
        uint256 currentVal = transferAllowances[msg.sender][_spender];

        require(
            currentVal + _value > currentVal,
            "zero value approval increase or arithmetic overflow"
        );

        return approve(_spender, currentVal + _value);
    }

    function decreaseAllowance(address _spender, uint256 _value)
        public
        virtual
        returns (bool)
    {
        uint256 currentVal = transferAllowances[msg.sender][_spender];

        require(_value > 0, "zero value approval decrease");

        require(currentVal >= _value, "ERC20: decreased allowance below zero");

        return approve(_spender, currentVal - _value);
    }

    function mint(address _to, uint256 _value) public {
        require(
            isSenderInRole(ROLE_TOKEN_CREATOR),
            "insufficient privileges (ROLE_TOKEN_CREATOR required)"
        );

        require(_to != address(0), "ERC20: mint to the zero address");

        require(
            totalSupply + _value > totalSupply,
            "zero value mint or arithmetic overflow"
        );

        require(
            totalSupply + _value <= type(uint192).max,
            "total supply overflow (uint192)"
        );

        totalSupply += _value;

        tokenBalances[_to] += _value;

        __moveVotingPower(address(0), votingDelegates[_to], _value);

        emit Minted(msg.sender, _to, _value);

        emit Transferred(msg.sender, address(0), _to, _value);

        emit Transfer(address(0), _to, _value);
    }

    function burn(address _from, uint256 _value) public {
        if (!isSenderInRole(ROLE_TOKEN_DESTROYER)) {
            require(
                (_from == msg.sender && isFeatureEnabled(FEATURE_OWN_BURNS)) ||
                    (_from != msg.sender &&
                        isFeatureEnabled(FEATURE_BURNS_ON_BEHALF)),
                _from == msg.sender
                    ? "burns are disabled"
                    : "burns on behalf are disabled"
            );

            if (_from != msg.sender) {
                uint256 _allowance = transferAllowances[_from][msg.sender];

                require(
                    _allowance >= _value,
                    "ERC20: burn amount exceeds allowance"
                );

                _allowance -= _value;

                transferAllowances[_from][msg.sender] = _allowance;

                emit Approved(
                    msg.sender,
                    _from,
                    _allowance + _value,
                    _allowance
                );

                emit Approval(_from, msg.sender, _allowance);
            }
        }

        require(_value != 0, "zero value burn");

        require(_from != address(0), "ERC20: burn from the zero address");

        require(
            tokenBalances[_from] >= _value,
            "ERC20: burn amount exceeds balance"
        );

        tokenBalances[_from] -= _value;

        totalSupply -= _value;

        __moveVotingPower(votingDelegates[_from], address(0), _value);

        emit Burnt(msg.sender, _from, _value);

        emit Transferred(msg.sender, _from, address(0), _value);

        emit Transfer(_from, address(0), _value);
    }

    function getVotingPower(address _of) public view returns (uint256) {
        VotingPowerRecord[] storage history = votingPowerHistory[_of];

        return
            history.length == 0 ? 0 : history[history.length - 1].votingPower;
    }

    function getVotingPowerAt(address _of, uint256 _blockNum)
        public
        view
        returns (uint256)
    {
        require(_blockNum < block.number, "not yet determined");

        VotingPowerRecord[] storage history = votingPowerHistory[_of];

        if (history.length == 0) {
            return 0;
        }

        if (history[history.length - 1].blockNumber <= _blockNum) {
            return getVotingPower(_of);
        }

        if (history[0].blockNumber > _blockNum) {
            return 0;
        }

        return history[__binaryLookup(_of, _blockNum)].votingPower;
    }

    function getVotingPowerHistory(address _of)
        public
        view
        returns (VotingPowerRecord[] memory)
    {
        return votingPowerHistory[_of];
    }

    function getVotingPowerHistoryLength(address _of)
        public
        view
        returns (uint256)
    {
        return votingPowerHistory[_of].length;
    }

    function delegate(address _to) public {
        require(
            isFeatureEnabled(FEATURE_DELEGATIONS),
            "delegations are disabled"
        );

        __delegate(msg.sender, _to);
    }

    function delegateWithSig(
        address _to,
        uint256 _nonce,
        uint256 _exp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(
            isFeatureEnabled(FEATURE_DELEGATIONS_ON_BEHALF),
            "delegations on behalf are disabled"
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                block.chainid,
                address(this)
            )
        );

        bytes32 hashStruct = keccak256(
            abi.encode(DELEGATION_TYPEHASH, _to, _nonce, _exp)
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, hashStruct)
        );

        address signer = ecrecover(digest, v, r, s);

        require(signer != address(0), "invalid signature");
        require(_nonce == nonces[signer], "invalid nonce");
        require(block.timestamp < _exp, "signature expired");

        nonces[signer]++;

        __delegate(signer, _to);
    }

    function __delegate(address _from, address _to) private {
        address _fromDelegate = votingDelegates[_from];

        uint256 _value = tokenBalances[_from];

        votingDelegates[_from] = _to;

        __moveVotingPower(_fromDelegate, _to, _value);

        emit DelegateChanged(_from, _fromDelegate, _to);
    }

    function __moveVotingPower(
        address _from,
        address _to,
        uint256 _value
    ) private {
        if (_from == _to || _value == 0) {
            return;
        }

        if (_from != address(0)) {
            uint256 _fromVal = getVotingPower(_from);

            uint256 _toVal = _fromVal - _value;

            __updateVotingPower(_from, _fromVal, _toVal);
        }

        if (_to != address(0)) {
            uint256 _fromVal = getVotingPower(_to);

            uint256 _toVal = _fromVal + _value;

            __updateVotingPower(_to, _fromVal, _toVal);
        }
    }

    function __updateVotingPower(
        address _of,
        uint256 _fromVal,
        uint256 _toVal
    ) private {
        VotingPowerRecord[] storage history = votingPowerHistory[_of];

        if (
            history.length != 0 &&
            history[history.length - 1].blockNumber == block.number
        ) {
            history[history.length - 1].votingPower = uint192(_toVal);
        } else {
            history.push(
                VotingPowerRecord(uint64(block.number), uint192(_toVal))
            );
        }

        emit VotingPowerChanged(_of, _fromVal, _toVal);
    }

    //mike 二分查找
    function __binaryLookup(address _to, uint256 n)
        private
        view
        returns (uint256)
    {
        VotingPowerRecord[] storage history = votingPowerHistory[_to];

        uint256 i = 0;

        uint256 j = history.length - 1;

        while (j > i) {
            uint256 k = j - (j - i) / 2;

            VotingPowerRecord memory cp = history[k];

            if (cp.blockNumber == n) {
                return k;
            } else if (cp.blockNumber < n) {
                i = k;
            } else {
                j = k - 1;
            }
        }

        return i;
    }
}
