// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../interfaces/IPool.sol";
import "./IlluviumAware.sol";
import "./IlluviumCorePool.sol";
import "../token/EscrowedIlluviumERC20.sol";
import "../utils/Ownable.sol";

contract IlluviumPoolFactory is Ownable, IlluviumAware {
    uint256 public constant FACTORY_UID =
        0xc5cfd88c6e4d7e5c8a03c255f03af23c0918d8e82cac196f57466af3fd4a5ec7;

    struct PoolData {
        address poolToken;
        address poolAddress;
        uint32 weight;
        bool isFlashPool;
    }

    uint192 public ilvPerBlock;

    uint32 public totalWeight;

    uint32 public immutable blocksPerUpdate;

    uint32 public endBlock;

    uint32 public lastRatioUpdate;

    address public immutable silv;

    mapping(address => address) public pools;

    mapping(address => bool) public poolExists;

    event PoolRegistered(
        address indexed _by,
        address indexed poolToken,
        address indexed poolAddress,
        uint64 weight,
        bool isFlashPool
    );

    event WeightUpdated(
        address indexed _by,
        address indexed poolAddress,
        uint32 weight
    );

    event IlvRatioUpdated(address indexed _by, uint256 newIlvPerBlock);

    constructor(
        address _ilv,
        address _silv,
        uint192 _ilvPerBlock,
        uint32 _blocksPerUpdate,
        uint32 _initBlock,
        uint32 _endBlock
    ) IlluviumAware(_ilv) {
        require(_silv != address(0), "sILV address not set");
        require(_ilvPerBlock > 0, "ILV/block not set");
        require(_blocksPerUpdate > 0, "blocks/update not set");
        require(_initBlock > 0, "init block not set");
        require(
            _endBlock > _initBlock,
            "invalid end block: must be greater than init block"
        );

        require(
            EscrowedIlluviumERC20(_silv).TOKEN_UID() ==
                0xac3051b8d4f50966afb632468a4f61483ae6a953b74e387a01ef94316d6b7d62,
            "unexpected sILV TOKEN_UID"
        );

        silv = _silv;
        ilvPerBlock = _ilvPerBlock;
        blocksPerUpdate = _blocksPerUpdate;
        lastRatioUpdate = _initBlock;
        endBlock = _endBlock;
    }

    function getPoolAddress(address poolToken) external view returns (address) {
        return pools[poolToken];
    }

    function getPoolData(address _poolToken)
        public
        view
        returns (PoolData memory)
    {
        address poolAddr = pools[_poolToken];

        require(poolAddr != address(0), "pool not found");

        address poolToken = IPool(poolAddr).poolToken();
        bool isFlashPool = IPool(poolAddr).isFlashPool();
        uint32 weight = IPool(poolAddr).weight();

        return
            PoolData({
                poolToken: poolToken,
                poolAddress: poolAddr,
                weight: weight,
                isFlashPool: isFlashPool
            });
    }

    function shouldUpdateRatio() public view returns (bool) {
        if (blockNumber() > endBlock) {
            return false;
        }

        return blockNumber() >= lastRatioUpdate + blocksPerUpdate;
    }

    //mike 创建新池子并记录
    function createPool(
        address poolToken,
        uint64 initBlock,
        uint32 weight
    ) external virtual onlyOwner {
        IPool pool = new IlluviumCorePool(
            ilv,
            silv,
            this,
            poolToken,
            initBlock,
            weight
        );

        registerPool(address(pool));
    }

    //mike 将新pool记录一下
    function registerPool(address poolAddr) public onlyOwner {
        //mike 读取pool的信息
        address poolToken = IPool(poolAddr).poolToken();
        bool isFlashPool = IPool(poolAddr).isFlashPool();
        uint32 weight = IPool(poolAddr).weight();
        //mike 必须没注册过
        require(
            pools[poolToken] == address(0),
            "this pool is already registered"
        );

        pools[poolToken] = poolAddr;
        poolExists[poolAddr] = true;

        totalWeight += weight;

        emit PoolRegistered(
            msg.sender,
            poolToken,
            poolAddr,
            weight,
            isFlashPool
        );
    }

    function updateILVPerBlock() external {
        require(shouldUpdateRatio(), "too frequent");

        ilvPerBlock = (ilvPerBlock * 97) / 100;

        lastRatioUpdate = uint32(blockNumber());

        emit IlvRatioUpdated(msg.sender, ilvPerBlock);
    }

    function mintYieldTo(address _to, uint256 _amount) external {
        require(poolExists[msg.sender], "access denied");

        mintIlv(_to, _amount);
    }

    function changePoolWeight(address poolAddr, uint32 weight) external {
        require(msg.sender == owner() || poolExists[msg.sender]);

        totalWeight = totalWeight + weight - IPool(poolAddr).weight();

        IPool(poolAddr).setWeight(weight);

        emit WeightUpdated(msg.sender, poolAddr, weight);
    }

    function blockNumber() public view virtual returns (uint256) {
        return block.number;
    }
}
