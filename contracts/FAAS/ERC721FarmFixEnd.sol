//SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IFarmDeployer.sol";

contract ERC721FarmFixEnd is Ownable, ReentrancyGuard, IERC721FarmFixEnd{

    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event Deposit(
        address indexed user,
        uint256[] tokenIds,
        uint256 rewardsAmount
    );
    event EmergencyWithdraw(address indexed user, uint256[] tokenIds);
    event NewStartBlock(uint256);
    event NewEndBlock(uint256);
    event NewMinimumLockTime(uint256);
    event NewUserStakeLimit(uint256);
    event Withdraw(
        address indexed user,
        uint256[] tokenIds,
        uint256 rewardsAmount
    );
    event RewardIncome(uint256);

    IERC721 public stakeToken;
    IERC20 public rewardToken;
    IFarmDeployer private farmDeployer;


    uint256 public startBlock;
    uint256 public endBlock;
    uint256 public lastRewardBlock;
    uint256 public userStakeLimit;
    uint256 public minimumLockTime;
    uint256 public stakeTokenSupply = 0;
    uint256 public rewardTotalShares = 0;
    uint256 public totalPendingReward = 0;
    uint256 public defaultRewardPPS;

    // Accrued token per share
    uint256 public accTokenPerShare;

    // The precision factor
    uint256 public PRECISION_FACTOR;

    // Info of each user that stakes tokens (stakeToken)
    mapping(address => UserInfo) public userInfo;
    bool private initialized = false;

    struct UserInfo {
        uint256[] tokenIds; // List of token IDs
        uint256 rewardDebt; // Reward debt
        uint256 depositBlock; // Reward debt
    }

    /*
     * @notice Initialize the contract
     * @param _stakeToken: stake token address
     * @param _rewardToken: reward token address
     * @param _startBlock: start block
     * @param _endBlock: end block of reward distribution
     * @param _userStakeLimit: maximum amount of tokens a user is allowed to stake (if any, else 0)
     * @param _minimumLockTime: minimum number of blocks user should wait after deposit to withdraw without fee
     * @param owner: admin address with ownership
     */
    function initialize(
        address _stakeToken,
        address _rewardToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime,
        address contractOwner
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;

        transferOwnership(contractOwner);
        farmDeployer = IFarmDeployer(IFarmDeployer721(msg.sender).farmDeployer());

        stakeToken = IERC721(_stakeToken);
        rewardToken = IERC20(_rewardToken);
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;
        endBlock = _endBlock;
        userStakeLimit = _userStakeLimit;
        minimumLockTime = _minimumLockTime;

        uint256 decimalsRewardToken = uint256(
            IERC20Metadata(_rewardToken).decimals()
        );
        require(decimalsRewardToken < 30, "Must be inferior to 30");
        PRECISION_FACTOR = uint256(10**(30 - decimalsRewardToken));
        defaultRewardPPS = 10 ** (decimalsRewardToken / 2);
    }


    /*
     * @notice Deposit staked tokens on behalf of msg.sender and collect reward tokens (if any)
     * @param tokenIds: Array of token index IDs to deposit
     */
    function deposit(uint256[] calldata tokenIds) external {
        _deposit(tokenIds, address(msg.sender));
    }


    /*
     * @notice Deposit staked tokens on behalf account and collect reward tokens (if any)
     * @param tokenIds: Array of token index IDs to deposit
     * @param account: future owner of deposit
     */
    function depositOnBehalf(uint256[] calldata tokenIds, address account) external {
        _deposit(tokenIds, account);
    }


    /*
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @dev Requires approval for all to be set
     * @param tokenIds: Array of token index IDs to deposit
     * @param account: Future owner of deposit
     */
    function _deposit (
        uint256[] calldata tokenIds,
        address account
    ) internal nonReentrant {
        require(block.number >= startBlock, "Pool is not active yet");
        require(block.number < endBlock, "Pool has ended");
        require(stakeToken.isApprovedForAll(msg.sender, address(this)), "Not approved");

        UserInfo storage user = userInfo[account];
        uint256 amountOfTokens = user.tokenIds.length;

        if (userStakeLimit > 0) {
            require(
                tokenIds.length + amountOfTokens <= userStakeLimit,
                "User amount above limit"
            );
        }

        _updatePool();

        uint256 pending = 0;
        uint256 rewardsAmount = 0;
        if (amountOfTokens > 0) {
            pending = amountOfTokens * accTokenPerShare / PRECISION_FACTOR - user.rewardDebt;
            if (pending > 0) {
                rewardsAmount = _transferReward(account, pending);
                if (totalPendingReward >= pending) {
                    totalPendingReward -= pending;
                } else {
                    totalPendingReward = 0;
                }
            }
        }

        for(uint i = 0; i < tokenIds.length; i++) {
            require(stakeToken.ownerOf(tokenIds[i]) == msg.sender, "Not an owner");
            user.tokenIds.push(tokenIds[i]);
            stakeToken.transferFrom(
                address(msg.sender),
                address(this),
                tokenIds[i]
            );
        }

        stakeTokenSupply += tokenIds.length;

        user.rewardDebt = user.tokenIds.length * accTokenPerShare / PRECISION_FACTOR;
        user.depositBlock = block.number;

        emit Deposit(account, tokenIds, rewardsAmount);
    }


    /*
     * @notice Withdraw staked tokens and collect reward tokens
     * @notice Withdrawal before minimum lock time is impossible
     * @param tokenIds: Array of token index IDs to withdraw
     */
    function withdraw(uint256[] calldata tokenIds) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amountOfTokens = user.tokenIds.length;
        require(amountOfTokens >= tokenIds.length, "Invalid IDs");

        uint256 earliestBlockToWithdrawWithoutFee = user.depositBlock + minimumLockTime;
        require(block.number >= earliestBlockToWithdrawWithoutFee, "Can't withdraw yet");

        _updatePool();

        uint256 pending = amountOfTokens * accTokenPerShare / PRECISION_FACTOR - user.rewardDebt;

        if (tokenIds.length > 0) {
            for(uint i = 0; i < tokenIds.length; i++){
                bool tokenTransferred = false;
                for(uint j = 0; j < user.tokenIds.length; j++){
                    if(tokenIds[i] == user.tokenIds[j]) {
                        user.tokenIds[j] = user.tokenIds[user.tokenIds.length - 1];
                        user.tokenIds.pop();
                        stakeToken.transferFrom(address(this), msg.sender, tokenIds[i]);
                        tokenTransferred = true;
                        break;
                    }
                }
                require(tokenTransferred, "Token not found");
            }
            stakeTokenSupply -= tokenIds.length;
        }

        uint256 rewardsAmount = 0;
        if (pending > 0) {
            rewardsAmount = _transferReward(address(msg.sender), pending);
            if (totalPendingReward >= pending) {
                totalPendingReward -= pending;
            } else {
                totalPendingReward = 0;
            }
        }

        user.rewardDebt = user.tokenIds.length * accTokenPerShare / PRECISION_FACTOR;

        emit Withdraw(msg.sender, tokenIds, rewardsAmount);
    }


    /*
     * @notice Withdraw staked tokens without caring about rewards rewards
     * @dev Needs to be for emergency.
     */
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        uint256[] memory tokenArray = user.tokenIds;
        uint256 tokensAmount = tokenArray.length;
        uint256 pending = tokensAmount * accTokenPerShare / PRECISION_FACTOR - user.rewardDebt;
        if (totalPendingReward >= pending) {
            totalPendingReward -= pending;
        } else {
            totalPendingReward = 0;
        }
        delete user.tokenIds;
        user.rewardDebt = 0;

        if(tokensAmount > 0){
            for(uint i = 0; i < tokenArray.length; i++) {
                stakeToken.transferFrom(
                    address(this),
                    address(msg.sender),
                    tokenArray[i]
                );
            }
            stakeTokenSupply -= tokensAmount;
        }

        emit EmergencyWithdraw(msg.sender, tokenArray);
    }


    /*
     * @notice Calculates the reward per block shares amount
     * @return Amount of reward shares
     * @dev Internal function for smart contract calculations
     */
    function _rewardPerBlock() private view returns (uint256) {
        if(endBlock < lastRewardBlock) {
            return 0;
        }
        return (rewardTotalShares - totalPendingReward) / (endBlock - lastRewardBlock);
    }


    /*
     * @notice Calculates the reward per block shares amount
     * @return Amount of reward shares
     * @dev External function for the front end
     */
    function rewardPerBlock() external view returns (uint256) {
        uint256 firstBlock = stakeTokenSupply == 0 ? block.number : lastRewardBlock;
        if(endBlock < firstBlock) {
            return 0;
        }
        return (rewardTotalShares - totalPendingReward) / (endBlock - firstBlock);
    }


    /*
     * @notice Calculates Price Per Reward of Reward token
     * @return Price Per Share of Reward token
     */
    function rewardPPS() public view returns(uint256) {
        if(rewardTotalShares > 1000) {
            return rewardToken.balanceOf(address(this)) / rewardTotalShares;
        }
        return defaultRewardPPS;
    }


    /*
     * @notice Allows Owner to withdraw ERC20 tokens from the contract
     * @param _tokenAddress: Address of ERC20 token contract
     * @param _tokenAmount: Amount of tokens to withdraw
     */
    function recoverERC20(
        address _tokenAddress,
        uint256 _tokenAmount
    ) external onlyOwner {
        _updatePool();
        if(_tokenAddress == address(rewardToken)){
            uint256 _rewardPPS = rewardPPS();
            uint256 allowedAmount = (rewardTotalShares - totalPendingReward) * _rewardPPS;
            require(_tokenAmount <= allowedAmount, "Over pending rewards");
            if(rewardTotalShares * _rewardPPS > _tokenAmount) {
                rewardTotalShares -= _tokenAmount / _rewardPPS;
            } else {
                rewardTotalShares = 0;
            }
        }

        IERC20(_tokenAddress).transfer(address(msg.sender), _tokenAmount);
        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }


    /*
     * @notice Sets start block of the pool
     * @param _startBlock: Number of start block
     */
    function setStartBlock(uint256 _startBlock) public onlyOwner {
        require(_startBlock >= block.number, "Can't set past block");
        require(startBlock >= block.number, "Staking has already started");
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;

        emit NewStartBlock(_startBlock);
    }


    /*
     * @notice Sets end block of reward distribution
     * @param _endBlock: End block
     */
    function setEndBlock(uint256 _endBlock) public onlyOwner {
        require(block.number < _endBlock, "Invalid number");
        _updatePool();
        endBlock = _endBlock;

        emit NewEndBlock(_endBlock);
    }


    /*
     * @notice Sets maximum amount of tokens 1 user is able to stake. 0 for no limit
     * @param _userStakeLimit: Maximum amount of tokens allowed to stake
     */
    function setUserStakeLimit(uint256 _userStakeLimit) public onlyOwner {
        require(_userStakeLimit != 0);
        userStakeLimit = _userStakeLimit;

        emit NewUserStakeLimit(_userStakeLimit);
    }


    /*
     * @notice Sets minimum amount of blocks that should pass before user can withdraw his deposit
     * @param _minimumLockTime: Number of blocks
     */
    function setMinimumLockTime(uint256 _minimumLockTime) public onlyOwner {
        require(_minimumLockTime <= farmDeployer.maxLockTime(),"Over max lock time");
        require(_minimumLockTime < minimumLockTime, "Can't increase");
        minimumLockTime = _minimumLockTime;

        emit NewMinimumLockTime(_minimumLockTime);
    }


    /*
     * @notice Sets farm variables
     * @param _startBlock: Number of start block
     * @param _endBlock: End block
     * @param _userStakeLimit: Maximum amount of tokens allowed to stake
     * @param _minimumLockTime: Number of blocks
     */
    function setFarmValues(
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _userStakeLimit,
        uint256 _minimumLockTime
    ) external onlyOwner {
        //start block
        if (startBlock != _startBlock) {
            setStartBlock(_startBlock);
        }

        //reward per block
        if (endBlock != _endBlock) {
            setEndBlock(_endBlock);
        }

        //user stake limit
        if (userStakeLimit != _userStakeLimit) {
            setUserStakeLimit(_userStakeLimit);
        }

        //min lock time
        if (minimumLockTime != _minimumLockTime) {
            setMinimumLockTime(_minimumLockTime);
        }
    }


    /*
     * @notice Adds reward to the pool
     * @param amount: Amount of reward token
     */
    function addReward(uint256 amount) external {
        require(amount != 0);
        rewardToken.transferFrom(msg.sender, address(this), amount);

        uint256 incomeFee = farmDeployer.incomeFee();
        uint256 feeAmount = 0;
        if (incomeFee > 0) {
            feeAmount = amount * farmDeployer.incomeFee() / 10_000;
            rewardToken.transfer(farmDeployer.feeReceiver(), feeAmount);
        }
        uint256 finalAmount = amount - feeAmount;

        rewardTotalShares += finalAmount / rewardPPS();
        emit RewardIncome(finalAmount);
    }


    /*
     * @notice View function to get deposited tokens array.
     * @param _user User address
     * @return tokenIds Deposited token IDs array
     */
    function getUserStakedTokenIds(address _user)
        external
        view
        returns(uint256[] memory tokenIds)
    {
        return userInfo[_user].tokenIds;
    }


    /*
     * @notice View function to see pending reward on frontend.
     * @param _user: user address
     * @return Pending reward for a given user
     */
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (block.number > lastRewardBlock && stakeTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
            uint256 cakeReward = multiplier * _rewardPerBlock();
            uint256 adjustedTokenPerShare = accTokenPerShare +
                cakeReward * PRECISION_FACTOR / stakeTokenSupply;
            return (user.tokenIds.length * adjustedTokenPerShare / PRECISION_FACTOR - user.rewardDebt)
                    * rewardPPS();
        } else {
            return (user.tokenIds.length * accTokenPerShare / PRECISION_FACTOR - user.rewardDebt)
                    * rewardPPS();
        }
    }


    /*
     * @notice Updates pool variables
     */
    function _updatePool() private {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (stakeTokenSupply == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
        uint256 cakeReward = multiplier == 0 ? 0 : multiplier * _rewardPerBlock();
        totalPendingReward += cakeReward;
        accTokenPerShare = accTokenPerShare +
            cakeReward * PRECISION_FACTOR / stakeTokenSupply;
        lastRewardBlock = block.number;
    }


    /*
     * @notice Calculates number of blocks to pay reward for.
     * @param _from: Starting block
     * @param _to: Ending block
     * @return Number of blocks, that should be rewarded
     */
    function _getMultiplier(
        uint256 _from,
        uint256 _to
    )
    private
    view
    returns (uint256)
    {
        if (_to <= endBlock) {
            return _to - _from;
        } else if (_from >= endBlock) {
            return 0;
        } else {
            return endBlock - _from;
        }
    }


    /*
     * @notice Transfers specific amount of shares of reward tokens.
     * @param receiver: Receiver address
     * @param shares: Amount of shares
     * @return rewardsAmount rewardsAmount
     */
    function _transferReward(address receiver, uint256 shares)
    private returns(uint256 rewardsAmount){
        rewardsAmount = shares * rewardPPS();
        rewardToken.transfer(receiver, rewardsAmount);
        rewardTotalShares -= shares;
    }
}
