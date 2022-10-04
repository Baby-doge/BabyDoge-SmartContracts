//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract BNBWrapper {
    IWETH public immutable weth;

    constructor(IWETH _weth) {
        weth = _weth;
    }


    /*
     * @notice Wraps BNB into WBNB and transfers
     * @param receiver WBNB receiver
     */
    function wrapAndTransfer(
        address receiver
    ) external payable {
        weth.deposit{value: msg.value}();
        weth.transfer(receiver, msg.value);
    }


    /*
     * @notice Wraps BNB into WBNB and calls addReward function on farm contract
     * @param farm Farm contract
     */
    function wrapAndAddReward(
        IFarm farm
    ) external payable {
        uint256 amount = msg.value;
        weth.deposit{value: amount}();
        if (weth.allowance(address(this), address(farm)) < amount) {
            weth.approve(address(farm), type(uint256).max);
        }
        farm.addReward(amount);
    }
}


interface IFarm {
    function addReward(uint256 amount) external;
}

interface IWETH {
    function deposit() external payable;
    function transfer(address dst, uint wad) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

