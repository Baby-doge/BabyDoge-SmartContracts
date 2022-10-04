//SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IFarmDeployer.sol";


contract FarmDeployerAdmin is Ownable, IFarmDeployer {

    event DeployedERC20Farm(
        address farmAddress,
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _rewardPerBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        uint256 _earlyWithdrawalFee,
        address _feeReceiver,
        bool _keepReflectionOnDeposit,
        address owner
    );

    event DeployedERC20FarmFixEnd(
        address farmAddress,
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        uint256 _earlyWithdrawalFee,
        address _feeReceiver,
        address owner
    );

    event DeployedERC721Farm(
        address farmAddress,
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _rewardPerBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        address owner
    );

    event DeployedERC721FarmFixEnd(
        address farmAddress,
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        address owner
    );

    event NewIncomeFee(uint256);
    event NewMaxLockTime(uint256);
    event NewFeeReceiver(address payable);
    event SetFarmDeployers(
        IFarmDeployer20 farmDeployer20,
        IFarmDeployer20FixEnd farmDeployer20FixEnd,
        IFarmDeployer721 farmDeployer721,
        IFarmDeployer721 farmDeployer721FixEnd
    );

    uint256 public maxLockTime;
    uint256 public incomeFee;
    address payable public feeReceiver;

    IFarmDeployer20 public farmDeployer20;
    IFarmDeployer20FixEnd public farmDeployer20FixEnd;
    IFarmDeployer721 public farmDeployer721;
    IFarmDeployer721 public farmDeployer721FixEnd;


    /*
     * @notice Initialize the contract
     * @param _maxLockTime: Maximum number of blocks, that pools are allowed
     * to demand for locking deposits
     * @param _incomeFee: Amount of income fee (for reward tokens, in basis points)
     * @param _feeReceiver: Address of receiver for deployment cost fee and reward tokens fee
     */
    constructor(
        uint256 _maxLockTime,
        uint256 _incomeFee,
        address payable _feeReceiver
    ) {
        require(_feeReceiver != address(0));
        maxLockTime = _maxLockTime;
        feeReceiver = _feeReceiver;
        incomeFee = _incomeFee;
    }


    /*
     * @notice Deploys ERC20Farm contract. Requires amount of BNB to be paid
     * @param _stakeToken: Stake token contract address
     * @param _rewardToken: Reward token contract address
     * @param _startBlock: Start block
     * @param _rewardPerBlock: Reward per block (in rewardToken)
     * @param _userStakeLimit: Maximum amount of tokens a user is allowed to stake (if any, else 0)
     * @param _minimumLockTime: Minimum number of blocks user should wait after deposit to withdraw without fee
     * @param _earlyWithdrawalFee: Fee for early withdrawal - in basis points
     * @param _feeReceiver: Receiver of early withdrawal fees
     * @param _keepReflectionOnDeposit: Should the farm keep track of reflection tokens on deposit?
     * @return farmAddress: Address of deployed pool contract
     */
    function deployERC20Farm(
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _rewardPerBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        uint256 _earlyWithdrawalFee,
        address _feeReceiver,
        bool _keepReflectionOnDeposit
    ) external onlyOwner returns(address farmAddress){
        require(_minimumLockTime <= maxLockTime, "Over max lock time");
        require(_earlyWithdrawalFee <= 10000);

        farmAddress = farmDeployer20.deploy(
                _stakeToken,
                _rewardToken,
                _startBlock,
                _rewardPerBlock,
                _userStakeLimit,
                _minimumLockTime,
                _earlyWithdrawalFee,
                _feeReceiver,
                _keepReflectionOnDeposit,
                msg.sender
            );

        emit DeployedERC20Farm(
            farmAddress,
            _stakeToken,
            _rewardToken,
            _startBlock,
            _rewardPerBlock,
            _userStakeLimit,
            _minimumLockTime,
            _earlyWithdrawalFee,
            _feeReceiver,
            _keepReflectionOnDeposit,
            msg.sender
        );
    }


    /*
     * @notice Deploys ERC20FarmFixEnd contract. Requires amount of BNB to be paid
     * @param _stakeToken: Stake token contract address
     * @param _rewardToken: Reward token contract address
     * @param _startBlock: Start block
     * @param _endBlock: End block of reward distribution
     * @param _userStakeLimit: Maximum amount of tokens a user is allowed to stake (if any, else 0)
     * @param _minimumLockTime: Minimum number of blocks user should wait after deposit to withdraw without fee
     * @param _earlyWithdrawalFee: Fee for early withdrawal - in basis points
     * @param _feeReceiver: Receiver of early withdrawal fees
     * @param _keepReflectionOnDeposit: Should the farm keep track of reflection tokens on deposit?
     * @return farmAddress: Address of deployed pool contract
     */
    function deployERC20FarmFixEnd(
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        uint256 _earlyWithdrawalFee,
        address _feeReceiver
    ) external onlyOwner returns(address farmAddress){
        require(_minimumLockTime <= maxLockTime, "Over max lock time");
        require(_earlyWithdrawalFee <= 10000);

        farmAddress = farmDeployer20FixEnd.deploy(
                _stakeToken,
                _rewardToken,
                _startBlock,
                _endBlock,
                _userStakeLimit,
                _minimumLockTime,
                _earlyWithdrawalFee,
                _feeReceiver,
                msg.sender
            );

        emit DeployedERC20FarmFixEnd(
            farmAddress,
            _stakeToken,
            _rewardToken,
            _startBlock,
            _endBlock,
            _userStakeLimit,
            _minimumLockTime,
            _earlyWithdrawalFee,
            _feeReceiver,
            msg.sender
        );
    }


    /*
     * @notice Deploys ERC721Farm contract. Requires amount of BNB to be paid
     * @param _stakeToken: Stake token address
     * @param _rewardToken: Reward token address
     * @param _startBlock: Start block
     * @param _rewardPerBlock: Reward per block (in rewardToken)
     * @param _userStakeLimit: Maximum amount of tokens a user is allowed to stake (if any, else 0)
     * @param _minimumLockTime: Minimum number of blocks user should wait after deposit to withdraw without fee
     * @return farmAddress: Address of deployed pool contract
     */
    function deployERC721Farm(
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _rewardPerBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime
    ) external onlyOwner returns(address farmAddress){
        require(_minimumLockTime <= maxLockTime, "Over max lock time");

        farmAddress = farmDeployer721.deploy(
                _stakeToken,
                _rewardToken,
                _startBlock,
                _rewardPerBlock,
                _userStakeLimit,
                _minimumLockTime,
                msg.sender
            );

        emit DeployedERC721Farm(
            farmAddress,
            _stakeToken,
            _rewardToken,
            _startBlock,
            _rewardPerBlock,
            _userStakeLimit,
            _minimumLockTime,
            msg.sender
        );
    }


    /*
     * @notice Deploys ERC721FarmFixEnd contract. Requires amount of BNB to be paid
     * @param _stakeToken: Stake token address
     * @param _rewardToken: Reward token address
     * @param _startBlock: Start block
     * @param _endBlock: End block of reward distribution
     * @param _userStakeLimit: Maximum amount of tokens a user is allowed to stake (if any, else 0)
     * @param _minimumLockTime: Minimum number of blocks user should wait after deposit to withdraw without fee
     * @return farmAddress: Address of deployed pool contract
     */
    function deployERC721FarmFixEnd(
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime
    ) external onlyOwner returns(address farmAddress){
        require(_minimumLockTime <= maxLockTime, "Over max lock time");

        farmAddress = farmDeployer721FixEnd.deploy(
                _stakeToken,
                _rewardToken,
                _startBlock,
                    _endBlock,
                _userStakeLimit,
                _minimumLockTime,
                msg.sender
            );

        emit DeployedERC721FarmFixEnd(
            farmAddress,
            _stakeToken,
            _rewardToken,
            _startBlock,
            _endBlock,
            _userStakeLimit,
            _minimumLockTime,
            msg.sender
        );
    }


    /*
     * @notice Sets farm deployers contracts
     * @param _farmDeployer20: ERC20 farm deployer address with fixed reward per block
     * @param _farmDeployer20FixEnd: ERC20 farm deployer address with fixed end block
     * @param _farmDeployer721: ERC721 farm deployer address with fixed reward per block
     * @param _farmDeployer721FixEnd: ERC721 farm deployer address with fixed end block
     */
    function setDeployers(
        IFarmDeployer20 _farmDeployer20,
        IFarmDeployer20FixEnd _farmDeployer20FixEnd,
        IFarmDeployer721 _farmDeployer721,
        IFarmDeployer721 _farmDeployer721FixEnd
    ) external onlyOwner {
        farmDeployer20 = _farmDeployer20;
        farmDeployer20FixEnd = _farmDeployer20FixEnd;
        farmDeployer721 = _farmDeployer721;
        farmDeployer721FixEnd = _farmDeployer721FixEnd;

        emit SetFarmDeployers(
            _farmDeployer20,
            _farmDeployer20FixEnd,
            _farmDeployer721,
            _farmDeployer721FixEnd
        );
    }


    /*
     * @notice Sets fee receiver address
     * @param _feeReceiver: Address of fee receiver
     */
    function setFeeReceiver(address payable _feeReceiver) external onlyOwner {
        require(feeReceiver != _feeReceiver, "Already set");
        require(address(0) != _feeReceiver);
        feeReceiver = _feeReceiver;

        emit NewFeeReceiver(_feeReceiver);
    }


    /*
     * @notice Sets income fee share for the pools
     * @param _incomeFee: Income fee (in basis points)
     * (can't be higher than 5000 (50%)
     */
    function setIncomeFee(uint256 _incomeFee) external onlyOwner {
        require(_incomeFee <= 5000, "Over 50%");
        incomeFee = _incomeFee;

        emit NewIncomeFee(_incomeFee);
    }


    /*
     * @notice Sets Maximum number of blocks, that pools are allowed
     * to demand for locking deposits
     * @param _maxLockTime: Maximum number of blocks, that pools are allowed
     * to demand for locking deposits
     */
    function setMaxLockTime(uint256 _maxLockTime) external onlyOwner {
        require(maxLockTime != _maxLockTime, "Already set");
        maxLockTime = _maxLockTime;

        emit NewMaxLockTime(_maxLockTime);
    }
}
