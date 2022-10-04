//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IBabyDogeRouter.sol";

contract BabyDogeBuyPromotions is AccessControl {
    struct TokenInfo {
        uint256 minBalance;
        bool isWhitelisted;
    }

    IERC20 public immutable babyDogeToken;
    IBabyDogeRouter public immutable router;
    address private immutable WETH;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");

    mapping(address => bool) public whitelistedNft;
    mapping(address => TokenInfo) public whitelistedToken;

    event Swap(
        address account,
        address whitelistedContract,
        bool isNFT,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );

    event WhitelistedNft(
        address guardian,
        address contractAddress,
        bool isWhitelisted
    );

    event WhitelistedToken(
        address guardian,
        address contractAddress,
        uint256 MinBalance,
        bool isWhitelisted
    );

    /**
     * @notice Checks if wallet/contract is allowed to buy BBD
     * @param whitelistedContract Address of whitelisted Token/NFT
     * @param isNFT Is this contract ERC721
     */
    modifier onlyAllowed(address whitelistedContract, bool isNFT) {
        bool isWhitelisted = hasRole(WHITELISTED_ROLE, msg.sender);
        require(msg.sender == tx.origin || isWhitelisted, "Non-whitelisted contract");

        require(
            isWhitelisted
            || (isNFT && whitelistedNft[whitelistedContract] && IERC721(whitelistedContract).balanceOf(msg.sender) > 0)
            || (whitelistedToken[whitelistedContract].isWhitelisted
                && IERC20(whitelistedContract).balanceOf(msg.sender) >= whitelistedToken[whitelistedContract].minBalance),
            "Not allowed!"
        );
        _;
    }

    /**
     * @notice Creates a contract
     * @param _babyDogeToken Address BBD token contract
     * @param _router BBD router address
     */
    constructor(
        IERC20 _babyDogeToken,
        IBabyDogeRouter _router
    ) {
        babyDogeToken = _babyDogeToken;
        router = _router;
        WETH = _router.WETH();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setRoleAdmin(WHITELISTED_ROLE, GUARDIAN_ROLE);
    }


    //function that receives ETH
    receive() external payable {}

    /**
     * @notice Swaps exact ETH for BBD Token
     * @param whitelistedContract Address of whitelisted ERC20 or ERC721 token. Any address (address(0)) for whitelisted user
     * @param isNFT Is whitelisted contract - ERC721?
     * @param amountOutMin Minimum amount of BBD Token to receive
     * @param to Receiver of BBD tokens
     * @param deadline Deadline until when swap should be executed
     * @dev Caller should be whitelisted or have enough of whitelisted ERC20 tokens or any whitelisted ERC721 token
     * @dev Smart contract always has to be whitelisted
     */
    function swapExactETHForTokens(
        address whitelistedContract,
        bool isNFT,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable onlyAllowed(whitelistedContract, isNFT) {
        address[] memory path = new address[](2);

        path[0] = WETH;
        path[1] = address(babyDogeToken);

        uint256[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            amountOutMin,
            path,
            address(this),
            deadline
        );

        uint256 amountOut = amounts[amounts.length - 1];
        babyDogeToken.transfer(to, amountOut);

        emit Swap(
            msg.sender,
            whitelistedContract,
            isNFT,
            WETH,
            msg.value,
            amounts[amounts.length - 1]
        );
    }


    /**
     * @notice Swaps ETH for exact amount of BBD tokens
     * @param whitelistedContract Address of whitelisted ERC20 or ERC721 token. Any address (address(0)) for whitelisted user
     * @param isNFT Is whitelisted contract - ERC721?
     * @param amountOut Amount of BBD Token to receive
     * @param to Receiver of BBD tokens
     * @param deadline Deadline until when swap should be executed
     * @dev Caller should be whitelisted or have enough of whitelisted ERC20 tokens or any whitelisted ERC721 token
     * @dev Smart contract always has to be whitelisted
     */
    function swapETHForExactTokens(
        address whitelistedContract,
        bool isNFT,
        uint256 amountOut,
        address to,
        uint256 deadline
    ) external payable onlyAllowed(whitelistedContract, isNFT) {
        address[] memory path = new address[](2);

        path[0] = WETH;
        path[1] = address(babyDogeToken);

        uint256 initialBalance = address(this).balance - msg.value;
        router.swapETHForExactTokens{value: msg.value}(
            amountOut,
            path,
            address(this),
            deadline
        );

        babyDogeToken.transfer(to, amountOut);
        //returning ETH leftovers
        uint256 leftoverETH = address(this).balance - initialBalance;
        (bool success,) = payable(msg.sender).call{value: (leftoverETH)}("");
        require(success, "ETH transfer failed");

        emit Swap(
            msg.sender,
            whitelistedContract,
            isNFT,
            WETH,
            msg.value - leftoverETH,
            amountOut
        );
    }


    /**
     * @notice Swaps Tokens for exact amount of BBD tokens
     * @param whitelistedContract Address of whitelisted ERC20 or ERC721 token. Any address (address(0)) for whitelisted user
     * @param isNFT Is whitelisted contract - ERC721?
     * @param amountOut Amount of BBD Token to receive
     * @param amountInMax Maximum amount of input token to be spend
     * @param path Array of tokens [inputTokenAddress, ... , bbdTokenAddress] to swap
     * @param to Receiver of BBD tokens
     * @param deadline Deadline until when swap should be executed
     * @dev Caller should be whitelisted or have enough of whitelisted ERC20 tokens or any whitelisted ERC721 token
     * @dev Smart contract always has to be whitelisted
     */
    function swapTokensForExactTokens(
        address whitelistedContract,
        bool isNFT,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external onlyAllowed(whitelistedContract, isNFT) {
        require(path[path.length - 1] == address(babyDogeToken), "Only BBD token purchase!");
        uint256 initialBalance = IERC20(path[0]).balanceOf(address(this));
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountInMax);

        if (IERC20(path[0]).allowance(address(this), address(router)) < amountInMax) {
            IERC20(path[0]).approve(address(router), type(uint256).max);
        }

        uint256[] memory amounts = router.swapTokensForExactTokens(
            amountOut,
            amountInMax,
            path,
            address(this),
            deadline
        );

        babyDogeToken.transfer(to, amounts[amounts.length - 1]);
        //transfer leftovers
        uint256 amountIn = amountInMax - (IERC20(path[0]).balanceOf(address(this)) - initialBalance);
        IERC20(path[0]).transfer(
            msg.sender,
            IERC20(path[0]).balanceOf(address(this)) - initialBalance
        );

        emit Swap(
            msg.sender,
            whitelistedContract,
            isNFT,
            path[0],
            amountIn,
            amounts[amounts.length - 1]
        );
    }


    /**
     * @notice Swaps exact amount of tokens for BBD tokens
     * @param whitelistedContract Address of whitelisted ERC20 or ERC721 token. Any address (address(0)) for whitelisted user
     * @param isNFT Is whitelisted contract - ERC721?
     * @param amountIn Amount of input tokens to spend
     * @param amountOutMin Minimum amount of BBD tokens to receive
     * @param path Array of tokens [inputTokenAddress, ... , bbdTokenAddress] to swap
     * @param to Receiver of BBD tokens
     * @param deadline Deadline until when swap should be executed
     * @dev Caller should be whitelisted or have enough of whitelisted ERC20 tokens or any whitelisted ERC721 token
     * @dev Smart contract always has to be whitelisted
     */
    function swapExactTokensForTokens(
        address whitelistedContract,
        bool isNFT,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external onlyAllowed(whitelistedContract, isNFT) {
        require(path[path.length - 1] == address(babyDogeToken), "Only BBD token purchase!");
        uint256 initialBalance = babyDogeToken.balanceOf(address(this));
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        if (IERC20(path[0]).allowance(address(this), address(router)) < amountIn) {
            IERC20(path[0]).approve(address(router), type(uint256).max);
        }

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline
        );

        uint256 amountOut = babyDogeToken.balanceOf(address(this)) - initialBalance;
        babyDogeToken.transfer(
            to,
            amountOut
        );

        emit Swap(
            msg.sender,
            whitelistedContract,
            isNFT,
            path[0],
            amountIn,
            amountOut
        );
    }


    /**
     * @notice Adds to or removes NFT from the whitelist
     * @param contractAddress Address of NFT contract
     * @param isWhitelisted true - add to whitelist, false - remove from whitelist
     * @dev Only for Guardian role
     */
    function setWhitelistedNft(
        address contractAddress,
        bool isWhitelisted
    ) external onlyRole(GUARDIAN_ROLE) {
        require(whitelistedNft[contractAddress] != isWhitelisted, "Already set");
        whitelistedNft[contractAddress] = isWhitelisted;
        emit WhitelistedNft(msg.sender, address(contractAddress), isWhitelisted);
    }


    /**
     * @notice Adds to or removes ERC20 token from the whitelist
     * @param contractAddress Address of ERC20 token contract
     * @param minBalance Minimum balance of this token which should allow account to buy BBD Token
     * @param isWhitelisted true - add to whitelist, false - remove from whitelist
     * @dev Only for Guardian role
     */
    function setWhitelistedToken(
        address contractAddress,
        uint256 minBalance,
        bool isWhitelisted
    ) external onlyRole(GUARDIAN_ROLE) {
        require(whitelistedToken[contractAddress].isWhitelisted != isWhitelisted, "Already set");
        whitelistedToken[contractAddress] = TokenInfo({
            minBalance: minBalance,
            isWhitelisted: isWhitelisted
        });
        emit WhitelistedToken(msg.sender, address(contractAddress), minBalance, isWhitelisted);
    }
}
