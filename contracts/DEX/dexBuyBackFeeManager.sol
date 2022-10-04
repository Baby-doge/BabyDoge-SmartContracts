//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/IBabyDogePair.sol";
import "./utils/IBabyDogeRouter.sol";

contract BuyBackFeeManager is AccessControl {
    struct TokenData {
        address tokenAddress;
        uint32 slippage;
    }

    struct LpTokenData {
        address tokenAddress;
        uint32 slippage0;
        uint32 slippage1;
    }

    struct LpTokenFullData {
        uint256 index;
        uint32 slippage0;
        uint32 slippage1;
        address[] unwrapPath0;
        address[] unwrapPath1;
    }

    modifier onlyLPGuardian {
        require(LPGuardian[msg.sender] == true, "Only LP Guardian allowed");
        _;
    }

    event PairFailure(address pair, bytes err);
    event RemoveLiquidityFailure(address pair, bytes err);
    event SwapFailure(bytes err, address[] path);

    event BuyBackAllocations(uint256 buyBack0, uint256 buyBack1);
    event BuyBackTokensAddresses(TokenData, TokenData);
    event BurnedBuyback();
    event NewRewardPerSecond(uint256);
    event NewRewardPerSecondPerLP(uint256);
    event NewUnwrapPeriod(uint256);
    event NewLpBatchNumber(uint256);
    event LpsUnwrapped(uint256 wbnbReceive);
    event NewLPGuardian(address);
    event RevokedLPGuardian(address);

    event NewLP (
        address LPGuardian,
        address LPTokenAddress,
        uint32 slippage0,
        uint32 slippage1,
        address[] LPTokenPath1,
        address[] LPTokenPath2
    );

    event ReplacedLP (
        address LPGuardian,
        address LPTokenAddress,
        uint32 slippage0,
        uint32 slippage1,
        address[] LPTokenPath1,
        address[] LPTokenPath2
    );

    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    address public router;
    address public WETH;
    TokenData public buyBackCoin0;
    TokenData public buyBackCoin1;

    uint256 public toBuyBackCoin0Percent;
    uint256 public buyBackAmount0;
    uint256 public buyBackAmount1;

    uint256 public unwrapPeriod;
    uint256 public lastLpFullUnwrapTime;
    uint256 public timeToBurn;
    uint256 public lpUnwrapStartingIndex;
    uint256 public rewardPerSecond;
    uint256 public rewardPerSecondPerLP;
    uint256 public lpBatchNumber = 100;

    bool public instantSwapToStable = true;
    bool public hasBurned = true;

    // LP => TokenA <- True / TokenB <- False => Path to WETH
    mapping(address => mapping(bool => address[])) public lpTokenUnwrapPath;
    mapping(address => bool) public LPGuardian;
    LpTokenData[] public lpTokenToUnwrap;

    /*
     * Params
     * address _WETH - WETH/WBNB address
     * address _router - Uniswap/Pancakeswap router address
     * TokenData _buyBackCoin0 - Address of buyback coin to which will be swapped part of WETH/WBNB and slippage in basis points
     * TokenData _buyBackCoin1 - Address of buyback coin to which will be swapped part of WETH/WBNB and slippage in basis points
     * uint256 _toBuyBackCoin0Percent - Share of WETH/WBNB that will be converted to buy back token #1.
     *** the rest will go to buyback token #2
     * uint256 _unwrapPeriod - Unwrap period in seconds
     * in basis points (75% == 7500)
     */
    constructor(
        address _WETH,
        address _router,
        TokenData memory _buyBackCoin0,
        TokenData memory _buyBackCoin1,
        uint256 _toBuyBackCoin0Percent,
        uint256 _rewardPerSecond,
        uint256 _rewardPerSecondPerLP,
        uint256 _unwrapPeriod
    ) {
        WETH = _WETH;
        router = _router;
        toBuyBackCoin0Percent = _toBuyBackCoin0Percent;
        buyBackCoin0 = _buyBackCoin0;
        buyBackCoin1 = _buyBackCoin1;
        rewardPerSecond = _rewardPerSecond;
        rewardPerSecondPerLP = _rewardPerSecondPerLP;
        unwrapPeriod = _unwrapPeriod;

        lastLpFullUnwrapTime = block.timestamp;

        require(
            _toBuyBackCoin0Percent <= 10000,
            "Allocations Below 10000"
        );

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(GOVERNANCE_ROLE, _msgSender());
    }

    //allows contract to receive ETH
    receive() external payable {}


    /*
     * Params
     * LpTokenData _lpTokenData - Address of lp token contract and swap slippages for both paths in basis points
     * address[] calldata _pathTokenA - Path for swapping tokenA to WETH/WBNB
     * address[] calldata _pathTokenB - Path for swapping tokenB to WETH/WBNB
     *
     * Function checks paths and adds them to internal storage
     */
    function addLP(
        LpTokenData calldata _lpTokenData,
        address[] calldata _pathTokenA,
        address[] calldata _pathTokenB
    ) external onlyLPGuardian {
        require(
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][true].length == 0 &&
                lpTokenUnwrapPath[_lpTokenData.tokenAddress][false].length == 0,
            "LP already added"
        );
        _checkLP(_lpTokenData, _pathTokenA, _pathTokenB);

        lpTokenToUnwrap.push(_lpTokenData);
        if (_pathTokenA.length > 0) {
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][true] = _pathTokenA;
        }
        if (_pathTokenB.length > 0) {
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][false] = _pathTokenB;
        }

        emit NewLP (
            msg.sender,
            _lpTokenData.tokenAddress,
            _lpTokenData.slippage0,
            _lpTokenData.slippage1,
            _pathTokenA,
            _pathTokenB
        );
    }


    /*
     * Params
     * uint256 _lpTokenIndex - Array index of the token you want to replace
     * LpTokenData _lpTokenData - Address of lp token contract and swap slippages fot both paths in basis points
     * address[] calldata _pathTokenA - Path for swapping tokenA to WETH/WBNB
     * address[] calldata _pathTokenB - Path for swapping tokenB to WETH/WBNB
     *
     * Function checks paths and replaces lp token info in internal storage
     */
    function replaceLP(
        uint256 _lpTokenIndex,
        LpTokenData calldata _lpTokenData,
        address[] calldata _pathTokenA,
        address[] calldata _pathTokenB
    ) external onlyLPGuardian {
        _checkLP(_lpTokenData, _pathTokenA, _pathTokenB);
        address oldLpTokenAddress = lpTokenToUnwrap[_lpTokenIndex].tokenAddress;
        if(oldLpTokenAddress != _lpTokenData.tokenAddress) {
            delete lpTokenUnwrapPath[oldLpTokenAddress][true];
            delete lpTokenUnwrapPath[oldLpTokenAddress][false];
        }

        lpTokenToUnwrap[_lpTokenIndex] = _lpTokenData;
        lpTokenUnwrapPath[_lpTokenData.tokenAddress][true] = _pathTokenA;
        lpTokenUnwrapPath[_lpTokenData.tokenAddress][false] = _pathTokenB;

        emit ReplacedLP (
            msg.sender,
            _lpTokenData.tokenAddress,
            _lpTokenData.slippage0,
            _lpTokenData.slippage1,
            _pathTokenA,
            _pathTokenB
        );
    }


    /*
     * Params
     * uint256 _toBuyBackCoin0Percent - Percent of WETH/WBNB to be converted to Buy back coin #1
     *
     * Function updates percent of WETH/WBNB to be converted to
     * stablecoins and sent to burn wallet
     */
    function setAllocationSettings(
        uint256 _toBuyBackCoin0Percent
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            _toBuyBackCoin0Percent <= 10000,
            "Has to be <= 10000"
        );

        toBuyBackCoin0Percent = _toBuyBackCoin0Percent;

        emit BuyBackAllocations(_toBuyBackCoin0Percent, 10000 - _toBuyBackCoin0Percent);
    }


    /*
     * Params
     * address user - Address of the user you want to appoint as LP Guardian
     *
     * Function adds LPGuardian rights to the user
     */
    function addLPGuardian(
        address user
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            LPGuardian[user] == false,
            "Already appointed"
        );
        LPGuardian[user] = true;

        emit NewLPGuardian(user);
    }


    /*
     * Params
     * address user - Address of the user you want to revoke from LP Guardians list
     *
     * Function revokes LPGuardian rights from the user
     */
    function revokeLPGuardian(
        address user
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            LPGuardian[user] == true,
            "Not LPGuardian"
        );
        LPGuardian[user] = false;

        emit RevokedLPGuardian(user);
    }


    /*
     * Params
     * uint256 _lpBatchNumber - Maximum number of LP tokens
     *** allowed during single unwrapTokens function execution
     *
     * Function sets different lpBatchNumber
     */
    function setLpBatchNumber(
        uint256 _lpBatchNumber
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            _lpBatchNumber > 0 && _lpBatchNumber != lpBatchNumber,
            "Invalid value"
        );
        lpBatchNumber = _lpBatchNumber;

        emit NewLpBatchNumber(_lpBatchNumber);
    }


    /*
     * Params
     * TokenData  _buyBackCoin0 - Token address that will be bought back using WETH/BNB and slippage in basis points
     * TokenData  _buyBackCoin1 - Token address that will be bought back using WETH/BNB and slippage in basis points
     *
     * Function changes the addresses of tokens that are bought back
     */
    function setBuybackTokens(TokenData calldata _buyBackCoin0, TokenData calldata _buyBackCoin1)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        buyBackCoin0 = _buyBackCoin0;
        buyBackCoin1 = _buyBackCoin1;

        emit BuyBackTokensAddresses(_buyBackCoin0, _buyBackCoin1);
    }


    /*
     * Params
     * uint256 _rewardPerSecond - Reward per second for swapToBuyBackAndBurn() function
     *
     * Rewards start accumulating starting from the end of unwrapPeriod after last full tokens unwrap.
     */
    function setRewardPerSecond(uint256 _rewardPerSecond)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(_rewardPerSecond != rewardPerSecond, "Already set");
        rewardPerSecond = _rewardPerSecond;
        emit NewRewardPerSecond(_rewardPerSecond);
    }


    /*
     * Params
     * uint256 _rewardPerSecondPerLP - Reward per second for unwrapTokens() function
     *
     * Rewards start accumulating starting from the end of unwrapPeriod after last full tokens unwrap.
     * Final reward depends on the number of LP tokens that need to be unwrapped during function call
     */
    function setRewardPerSecondPerLP(uint256 _rewardPerSecondPerLP)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(_rewardPerSecondPerLP != rewardPerSecondPerLP, "Already set");
        rewardPerSecondPerLP = _rewardPerSecondPerLP;
        emit NewRewardPerSecondPerLP(_rewardPerSecondPerLP);
    }


    /*
     * Params
     * uint256 _unwrapPeriod - Unwrap period in seconds
     */
    function setUnwrapPeriod(uint256 _unwrapPeriod)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(_unwrapPeriod != unwrapPeriod, "Already set");
        unwrapPeriod = _unwrapPeriod;
        emit NewUnwrapPeriod(_unwrapPeriod);
    }


    /*
     * Function unwraps LP tokens in batches of 100 (lpBatchNumber).
     * Full LP tokens unwrap may be done once in 7 days
     * Function removes liquidity in exchange for lp tokens and swaps both tokens for WETH/WBNB
     */
    function unwrapTokens()
        external
    {
        uint256 _lastLpFullUnwrapTime = lastLpFullUnwrapTime;
        require(
            lpUnwrapStartingIndex != 0
            || _lastLpFullUnwrapTime + unwrapPeriod < block.timestamp,
            "Already unwrapped"
        );
        //gas saving
        LpTokenData[] memory _lpTokenToUnwrap = lpTokenToUnwrap;
        uint256 _startingIndex = lpUnwrapStartingIndex;
        uint256 _endingIndex = _startingIndex + lpBatchNumber;
        if(_endingIndex >= _lpTokenToUnwrap.length) {
            _endingIndex = _lpTokenToUnwrap.length;
            lastLpFullUnwrapTime = block.timestamp;
            lpUnwrapStartingIndex = 0;
            hasBurned = false;
            timeToBurn = block.timestamp;
        } else {
            lpUnwrapStartingIndex = _endingIndex;
        }

        uint256 reward = (_endingIndex - _startingIndex)
            * rewardPerSecondPerLP
            * (block.timestamp - (_lastLpFullUnwrapTime + unwrapPeriod));

        require(msg.sender == tx.origin, "Only Wallet");
        for (
            uint256 current = _startingIndex;
            current < _endingIndex;
            current++
        ) {
            uint256 liquidity = IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress)
                .balanceOf(address(this));
            if (liquidity > 0) {
                // LP token is Stable coin of choice or WETH unwrap and swap
                address tokenA;
                try IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress)
                    .token0() returns(address _token) {
                    tokenA = _token;
                } catch (bytes memory _err) {
                    emit PairFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                address tokenB;
                try IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress)
                    .token1() returns(address _token) {
                    tokenB = _token;
                } catch (bytes memory _err) {
                    emit PairFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                if(tokenA == address(0) || tokenB == address(0)) {
                    continue;
                }

                IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress).approve(
                    router,
                    liquidity
                );
                try IBabyDogeRouter(router).removeLiquidity(
                    tokenA,
                    tokenB,
                    liquidity,
                    0,
                    0,
                    address(this),
                    block.timestamp + 1200
                ) {}
                catch (bytes memory _err) {
                    emit RemoveLiquidityFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                if (
                    lpTokenUnwrapPath[_lpTokenToUnwrap[current].tokenAddress][true].length > 0
                ) {
                    swapTokens(
                        lpTokenUnwrapPath[_lpTokenToUnwrap[current].tokenAddress][true],
                        _lpTokenToUnwrap[current].slippage0
                    );
                }
                if (
                    lpTokenUnwrapPath[_lpTokenToUnwrap[current].tokenAddress][false].length >
                    0
                ) {
                    swapTokens(
                        lpTokenUnwrapPath[_lpTokenToUnwrap[current].tokenAddress][false],
                        _lpTokenToUnwrap[current].slippage1
                    );
                }
            }
        }

        uint256 newWETHBalance = IERC20(WETH).balanceOf(address(this)) -
            (buyBackAmount0 + buyBackAmount1);
        if(reward > newWETHBalance) {
            reward = newWETHBalance;
        }
        newWETHBalance -= reward;
        if (reward > 0) IERC20(WETH).transfer(msg.sender, reward);

        if(newWETHBalance > 0) {
            uint256 addBuyBackAmount0 = (newWETHBalance * toBuyBackCoin0Percent) / 10000;
            buyBackAmount0 += addBuyBackAmount0;
            buyBackAmount1 += newWETHBalance - addBuyBackAmount0;
        }

        emit LpsUnwrapped(newWETHBalance);
    }

    /*
     * Params
     * address[] storage path - Path for swapping token to WETH/WBNB
     * uint32 slippage - Swap slippage in basis points (10000 - no slippage)
     *
     * Function swaps full balance of token to WETH/WBNB
     * The first element of path is the input token, the last is the output token,
     * and any intermediate elements represent intermediate pairs to trade
     */
    function swapTokens(address[] storage path, uint32 slippage) internal {
        uint256 amountIn = IERC20(path[0]).balanceOf(address(this));
        IERC20(path[0]).approve(router, amountIn);

        try IBabyDogeRouter(router).getAmountsOut(amountIn, path)
        returns (uint256[] memory amounts) {
            address to = address(this);
            uint256 deadline = block.timestamp + 1200; //20 minutes to complete transaction
            try IBabyDogeRouter(router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amountIn,
                    amounts[path.length - 1] * slippage / 10000,
                    path,
                    to,
                    deadline
            ) {} catch (bytes memory _err) {
                emit SwapFailure(
                    _err,
                    path
                );
            }
        } catch (bytes memory _err) {
            emit SwapFailure(
                _err,
                path
            );
        }
    }

    /*
     * Function swaps correct percent of WETH/WBNB balance to buyback coins
     * and sends these coins to buyback wallet
     * You can call this function only when LP tokens are fully unwrapped
     * Caller will receive WETH reward for each second since this function can be called.
     * LP tokens must be unwrapped first
     */
    function swapToBuyBackAndBurn() external {
        // Swap X amount to buyback token. Keep in the contract.
        uint256 WETHBalance = IERC20(WETH).balanceOf(address(this));
        require(WETHBalance > 0, "Nothing to swap. Unwrap first");

        require(
            lpUnwrapStartingIndex == 0
            && lastLpFullUnwrapTime + unwrapPeriod > block.timestamp,
            "Not Unwrapped yet"
        );

        require(hasBurned == false,"Already burned");
        hasBurned = true;

        uint256 rewardAmount = (block.timestamp - timeToBurn) * rewardPerSecond;
        if(rewardAmount > WETHBalance) {
            rewardAmount = WETHBalance;
        }
        IERC20(WETH).transfer(msg.sender, rewardAmount);
        WETHBalance -= rewardAmount;

        //gas saving
        uint256 _buyBackAmount0 = buyBackAmount0;
        uint256 _buyBackAmount1 = buyBackAmount1;
        _buyBackAmount0 = WETHBalance * _buyBackAmount0/(_buyBackAmount0 + _buyBackAmount1);
        _buyBackAmount1 = WETHBalance - _buyBackAmount0;

        TokenData memory _buyBackCoin0 = buyBackCoin0;
        TokenData memory _buyBackCoin1 = buyBackCoin1;

        if (_buyBackCoin0.tokenAddress != address(0)) {
            IERC20(WETH).approve(router, _buyBackAmount0 + _buyBackAmount1);
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = _buyBackCoin0.tokenAddress;

            uint256[] memory amountOutMin = IBabyDogeRouter(router)
                .getAmountsOut(_buyBackAmount0, path);

            try IBabyDogeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _buyBackAmount0,
                amountOutMin[1] * _buyBackCoin0.slippage / 10000,
                path,
                0x000000000000000000000000000000000000dEaD,
                block.timestamp + 1200
            ) {
                buyBackAmount0 = 0;
            } catch (bytes memory _err) {
                emit SwapFailure(
                    _err,
                    path
                );
            }
        }

        if (_buyBackCoin1.tokenAddress != address(0)) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = _buyBackCoin1.tokenAddress;

            uint256[] memory amountOutMin = IBabyDogeRouter(router)
                .getAmountsOut(_buyBackAmount1, path);

            try IBabyDogeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _buyBackAmount1,
                amountOutMin[1] * _buyBackCoin1.slippage / 10000,
                path,
                0x000000000000000000000000000000000000dEaD,
                block.timestamp + 1200
            ) {
                buyBackAmount1 = 0;
            } catch (bytes memory _err) {
                emit SwapFailure(
                    _err,
                    path
                );
            }
        }

        emit BurnedBuyback();
    }


    /*
     * Params
     * address payable _address - Address that will receive WETH/WBNB
     * uint256 amount - Amount of WETH/WBNB to receive
     *
     * Function withdraws any WETH/WBNB to specific address
     */
    function withdrawETH(address payable _address, uint256 amount)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(address(this).balance >= amount, "Not enough ETH");
        _address.transfer(amount);
    }

    /*
     * Params
     * address _address - Address that will receive ERC20
     * address tokenAddress - Address of ERC20 token contract
     * uint256 amount - Amount of ERC20 to receive
     *
     * Function withdraws any ERC20 tokens to specific address
     * Can't withdraw active LP tokens
     */
    function withdrawERC20(
        address _address,
        address tokenAddress,
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(
            IERC20(tokenAddress).balanceOf(address(this)) >= amount,
            "Not enough ERC20"
        );

        require(
            lpTokenUnwrapPath[tokenAddress][true].length == 0 &&
            lpTokenUnwrapPath[tokenAddress][false].length == 0,
            "Can't withdraw LP tokens"
        );

        IERC20(tokenAddress).transfer(_address, amount);
    }

    /*
     * Params
     * address tokenAddress - Address LP token
     * bool isTokenA - Do you want to get path for TokenA?
     *** true = TokenA, false = tokenB
     *
     * Function returns unwrap path of the token
     */
    function getLpTokenUnwrapPath(
        address tokenAddress,
        bool isTokenA
    ) external view returns(address[] memory) {
        return lpTokenUnwrapPath[tokenAddress][isTokenA];
    }


    /*
     * LpTokenData _lpTokenData - Address of lp token contract and swap slippages for both paths in basis points
     * address[] calldata _pathTokenA - Path for swapping tokenA to WETH/WBNB
     * address[] calldata _pathTokenB - Path for swapping tokenB to WETH/WBNB
     *
     * Checks unwrap paths
     */
    function _checkLP (
        LpTokenData calldata _lpTokenData,
        address[] calldata _pathTokenA,
        address[] calldata _pathTokenB
    ) private view {
        address _WETH = WETH;
        require(_pathTokenA.length != 0 || _pathTokenB.length != 0, "Invalid paths");

        address token0 = IBabyDogePair(_lpTokenData.tokenAddress).token0();
        address token1 = IBabyDogePair(_lpTokenData.tokenAddress).token1();

        if (_pathTokenA.length != 0) {
            require(
                (_pathTokenA[0] == token0
                || _pathTokenA[0] == token1)
                && _pathTokenA[_pathTokenA.length - 1] == _WETH,
                "Invalid path A"
            );
        }

        if (_pathTokenB.length != 0) {
            require(
                (_pathTokenB[0] == token0
                || _pathTokenB[0] == token1)
                && _pathTokenB[_pathTokenB.length - 1] == _WETH,
                "Invalid path B"
            );
        }

        if (_pathTokenA.length != 0 && _pathTokenB.length != 0) {
            require(_pathTokenA[0] != _pathTokenB[0], "Invalid paths");
        } else {
            require(token0 == _WETH || token1 == _WETH, "Invalid empty path");
        }
    }


    /*
     * Params
     * address tokenAddress - Address LP token
     * startSearchIndex - Start index to search for the token. 0 - to start searching from the start
     *
     * Function returns full data about the token
     */
    function getLpTokenFullData(
        address lpTokenAddress,
        uint256 startSearchIndex
    ) external view returns(LpTokenFullData memory) {
        LpTokenData memory lpTokenData;
        uint256 index = 0;
        for(uint i = startSearchIndex; i < lpTokenToUnwrap.length; i++) {
            if (lpTokenToUnwrap[i].tokenAddress == lpTokenAddress) {
                lpTokenData = lpTokenToUnwrap[i];
                index = i;
                break;
            }
        }

        return LpTokenFullData({
            index: index,
            slippage0: lpTokenData.slippage0,
            slippage1: lpTokenData.slippage1,
            unwrapPath0: lpTokenUnwrapPath[lpTokenAddress][true],
            unwrapPath1: lpTokenUnwrapPath[lpTokenAddress][false]
        });
    }


    /*
     * Params
     * uint256 startIndex - Start index of the batch
     * uint256 batchSize - Token array length
     *
     * Function returns array of tokens to unwrap
     */
    function getLpTokensToUnwrap(
        uint256 startIndex,
        uint256 batchSize
    ) external view returns(address[] memory) {
        uint256 maxLength = lpTokenToUnwrap.length - startIndex;
        uint256 arrayLength = maxLength < batchSize
        ? maxLength
        : batchSize;

        address[] memory tokens = new address[](arrayLength);

        for(uint i = 0; i < arrayLength; i++) {
            tokens[i] = lpTokenToUnwrap[i + startIndex].tokenAddress;
        }

        return tokens;
    }
}
