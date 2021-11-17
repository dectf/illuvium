// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../interfaces/IPool.sol";
import "./IlluviumAware.sol";
import "./IlluviumCorePool.sol";
import "../token/EscrowedIlluviumERC20.sol";
import "../utils/Ownable.sol";

//mike mainnet 0x2996222cb2bF3675e5f5f88A5F211736197F03C7
//mike 可以创建池子的工厂合约，注册池子，更新每区块ilv，mint ilv和修改池子权重
contract IlluviumPoolFactory is Ownable, IlluviumAware {
    uint256 public constant FACTORY_UID =
        0xc5cfd88c6e4d7e5c8a03c255f03af23c0918d8e82cac196f57466af3fd4a5ec7;

    struct PoolData {
        address poolToken;
        address poolAddress;
        uint32 weight;
        bool isFlashPool;
    }

    uint192 public ilvPerBlock; //mike 随时间递减

    uint32 public totalWeight;

    uint32 public immutable blocksPerUpdate;

    uint32 public endBlock; //mike 19856916

    uint32 public lastRatioUpdate;

    address public immutable silv;

    mapping(address => address) public pools; //mike 记录token对应的池子

    mapping(address => bool) public poolExists; //mike 已创建的池子

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

    //mike 实例化IlluviumAware
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

    //mike 获取token对应的池子地址
    function getPoolAddress(address poolToken) external view returns (address) {
        return pools[poolToken];
    }

    //mike 读取池子信息
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

    //mike 如果factory关闭了，就不更新ilvPerBlock；否则，每隔一些区块更新一次
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

    //mike 时间到了以后，每个区块的收益降低为原来的0.97
    //mike 现在每隔14天有人update一次，https://etherscan.io/address/0x2996222cb2bf3675e5f5f88a5f211736197f03c7/advanced#events
    function updateILVPerBlock() external {
        require(shouldUpdateRatio(), "too frequent");

        ilvPerBlock = (ilvPerBlock * 97) / 100;
        //mike 更新时间
        lastRatioUpdate = uint32(blockNumber());

        emit IlvRatioUpdated(msg.sender, ilvPerBlock);
    }

    //mike basePool池子调用，给to mint ilv
    function mintYieldTo(address _to, uint256 _amount) external {
        require(poolExists[msg.sender], "access denied");
        //mike mint ilv给to
        mintIlv(_to, _amount);
    }

    //mike 修改池子权重为weight
    function changePoolWeight(address poolAddr, uint32 weight) external {
        //mike 要么是owner，要么是池子自己调用
        require(msg.sender == owner() || poolExists[msg.sender]);
        //mike 总权重先加后减，相当于改变权重
        totalWeight = totalWeight + weight - IPool(poolAddr).weight();
        //mike 池子本身权重直接设置
        IPool(poolAddr).setWeight(weight);

        emit WeightUpdated(msg.sender, poolAddr, weight);
    }

    //mike 当前区块号
    function blockNumber() public view virtual returns (uint256) {
        return block.number;
    }
}
