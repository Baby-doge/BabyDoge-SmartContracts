//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/IBabyDogePair.sol";
import "./utils/IBabyDogeRouter.sol";

contract TreasuryFeeManager is AccessControl {
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

    event PairFailure(address pair, bytes err);
    event RemoveLiquidityFailure(address pair, bytes err);
    event SwapFailure(bytes err, address[] path);

    event TransferredToTreasury();
    event NewLpBatchNumber(uint256);
    event SwappedToStables();

    event NewLP(
        address LPTokenAddress,
        uint32 slippage0,
        uint32 slippage1,
        address[] LPTokenPath1,
        address[] LPTokenPath2
    );

    event ReplacedLP(
        address LPTokenAddress,
        uint32 slippage0,
        uint32 slippage1,
        address[] LPTokenPath1,
        address[] LPTokenPath2
    );

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    address public router;
    address public WETH;
    address public stableCoin;
    address public treasuryAddress;
    uint256 public lpBatchNumber = 100;
    uint256 public lpUnwrapStartingIndex;

    // LP => TokenA <- True / TokenB <- False => Path to WETH
    mapping(address => mapping(bool => address[])) public lpTokenUnwrapPath;
    LpTokenData[] public lpTokenToUnwrap;

    /*
     * Params
     * address _WETH - WETH/WBNB address
     * address _router - Uniswap/Pancakeswap router address
     * address _stableCoin - Address of stablecoin to which will be swapped part of WETH/WBNB
     * address _treasuryAddress - Address of treasury, which will receive stablecoins
     * uint256 _toTreasuryPercent - Share of WETH/WBNB that will be converted to stablecoins
     * in basis points (75% == 7500)
     */
    constructor(
        address _WETH,
        address _router,
        address _stableCoin,
        address _treasuryAddress
    ) {
        WETH = _WETH;
        router = _router;
        stableCoin = _stableCoin;
        treasuryAddress = _treasuryAddress;

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MANAGER_ROLE, _msgSender());
        _setupRole(OWNER_ROLE, _msgSender());
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
    ) external onlyRole(MANAGER_ROLE) {
        _checkLP(_lpTokenData, _pathTokenA, _pathTokenB);
        require(
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][true].length == 0 &&
                lpTokenUnwrapPath[_lpTokenData.tokenAddress][false].length == 0,
            "LP already added"
        );
        lpTokenToUnwrap.push(_lpTokenData);
        if (_pathTokenA.length > 0) {
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][true] = _pathTokenA;
        }
        if (_pathTokenB.length > 0) {
            lpTokenUnwrapPath[_lpTokenData.tokenAddress][false] = _pathTokenB;
        }

        emit NewLP(
            _lpTokenData.tokenAddress,
            _lpTokenData.slippage0,
            _lpTokenData.slippage1,
            _pathTokenA,
            _pathTokenB
        );
    }

    /*
     * Params
     * address _treasuryAddress - Address of treasury
     *
     * Function updates treasury address
     */
    function setTreasuryAddress(address _treasuryAddress)
        external
        onlyRole(OWNER_ROLE)
    {
        require(_treasuryAddress != address(0), "Cant set 0 address");
        treasuryAddress = _treasuryAddress;
    }

    /*
     * Params
     * uint256 _lpTokenIndex - Array index of the token you want to replace
     * TokenData _lpTokenData - Address of lp token contract and swap slippage in basis points
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
    ) external onlyRole(MANAGER_ROLE) {
        _checkLP(_lpTokenData, _pathTokenA, _pathTokenB);
        address oldLpTokenAddress = lpTokenToUnwrap[_lpTokenIndex].tokenAddress;
        if (oldLpTokenAddress != _lpTokenData.tokenAddress) {
            delete lpTokenUnwrapPath[oldLpTokenAddress][true];
            delete lpTokenUnwrapPath[oldLpTokenAddress][false];
        }

        lpTokenToUnwrap[_lpTokenIndex] = _lpTokenData;
        lpTokenUnwrapPath[_lpTokenData.tokenAddress][true] = _pathTokenA;
        lpTokenUnwrapPath[_lpTokenData.tokenAddress][false] = _pathTokenB;

        emit ReplacedLP(
            _lpTokenData.tokenAddress,
            _lpTokenData.slippage0,
            _lpTokenData.slippage1,
            _pathTokenA,
            _pathTokenB
        );
    }

    /*
     * Params
     * uint256 _lpBatchNumber - Maximum number of LP tokens
     *** allowed during single unwrapTokens function execution
     *
     * Function sets different lpBatchNumber
     */
    function setLpBatchNumber(uint256 _lpBatchNumber)
        external
        onlyRole(OWNER_ROLE)
    {
        require(
            _lpBatchNumber > 0 && _lpBatchNumber != lpBatchNumber,
            "Invalid value"
        );
        lpBatchNumber = _lpBatchNumber;

        emit NewLpBatchNumber(_lpBatchNumber);
    }

    /*
     * Function unwraps LP tokens in batches of 100 (lpBatchNumber).
     * Function removes liquidity in exchange for lp tokens and swaps both tokens for WETH/WBNB
     */
    function unwrapTokens() external onlyRole(MANAGER_ROLE) {
        //gas saving
        LpTokenData[] memory _lpTokenToUnwrap = lpTokenToUnwrap;
        uint256 _startingIndex = lpUnwrapStartingIndex;
        uint256 _endingIndex = _startingIndex + lpBatchNumber;
        if (_endingIndex >= _lpTokenToUnwrap.length) {
            _endingIndex = _lpTokenToUnwrap.length;
            lpUnwrapStartingIndex = 0;
        } else {
            lpUnwrapStartingIndex = _endingIndex;
        }

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
                try
                    IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress).token0()
                returns (address _token) {
                    tokenA = _token;
                } catch (bytes memory _err) {
                    emit PairFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                address tokenB;
                try
                    IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress).token1()
                returns (address _token) {
                    tokenB = _token;
                } catch (bytes memory _err) {
                    emit PairFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                if (tokenA == address(0) || tokenB == address(0)) {
                    continue;
                }

                IBabyDogePair(_lpTokenToUnwrap[current].tokenAddress).approve(
                    router,
                    liquidity
                );
                try
                    IBabyDogeRouter(router).removeLiquidity(
                        tokenA,
                        tokenB,
                        liquidity,
                        0,
                        0,
                        address(this),
                        block.timestamp + 1200
                    )
                {} catch (bytes memory _err) {
                    emit RemoveLiquidityFailure(_lpTokenToUnwrap[current].tokenAddress, _err);
                }

                if (
                    lpTokenUnwrapPath[_lpTokenToUnwrap[current].tokenAddress][true].length >
                    0
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

        if (_endingIndex == _lpTokenToUnwrap.length) {
            swapToStable();
        }
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

        try IBabyDogeRouter(router).getAmountsOut(amountIn, path) returns (
            uint256[] memory amounts
        ) {
            address to = address(this);
            uint256 deadline = block.timestamp + 1200; //20 minutes to complete transaction
            try
                IBabyDogeRouter(router)
                    .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        amountIn,
                        amounts[path.length - 1] * slippage / 10000,
                        path,
                        to,
                        deadline
                    )
            {} catch (bytes memory _err) {
                emit SwapFailure(_err, path);
            }
        } catch (bytes memory _err) {
            emit SwapFailure(_err, path);
        }
    }

    /*
     * Function swaps correct percent of WETH/WBNB balance
     * to stablecoins and sends them to treasury
     */
    function swapToStable() internal {
        // Swap a portion and send to treasury
        uint256 amountToStable = IERC20(WETH).balanceOf(address(this));
        //swap to stable
        IERC20(WETH).approve(router, amountToStable);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = stableCoin;

        uint256[] memory amountOutMin = IBabyDogeRouter(router)
            .getAmountsOut(amountToStable, path);
        try
            IBabyDogeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountToStable,
                amountOutMin[1],
                path,
                treasuryAddress,
                block.timestamp + 1200
        ) {
            emit TransferredToTreasury();
        } catch (bytes memory _err) {
            emit SwapFailure(_err, path);
        }
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
        onlyRole(OWNER_ROLE)
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
    ) external onlyRole(OWNER_ROLE) {
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
     * uint256 startSearchIndex - Start index to search for the token. 0 - to start searching from the start
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
