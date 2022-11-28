pragma solidity =0.5.16;

import "./interfaces/IBabyDogeFactory.sol";
import "./BabyDogePair.sol";

contract BabyDogeFactory is IBabyDogeFactory {
    address public feeTo;
    address public feeToTreasury;
    address public feeToSetter;
    address public router;
    bytes32 public constant INIT_CODE_PAIR_HASH =
        keccak256(abi.encodePacked(type(BabyDogePair).creationCode));
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair)
    {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "PAIR_EXISTS"); // single check is sufficient
        bytes memory bytecode = type(BabyDogePair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IBabyDogePair(pair).initialize(token0, token1, router);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(
        address _feeTo,
        address _feeToTreasury
    ) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        require(
            (_feeTo != address(0) && _feeToTreasury != address(0))
            || (_feeTo == address(0) && _feeToTreasury == address(0)),
            "Can't turn off single fee"
        );

        feeTo = _feeTo;
        feeToTreasury = _feeToTreasury;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    /**
     * @notice Only our router will be able to communicate with the pair contracts.
     *         Flash Swaps disabled
     *         Router controls the amount of fees swapper is paying
     * @param _router Address of the router that will be deployed
     */

    function setRouter(address _router) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        router = _router;
    }
}
