//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract RouterFeeSetter is AccessControl{
    IBabyDogeRouter public router;

    bytes32 public constant ROLE_SETTER = keccak256("ROLE_SETTER");
    bytes32 public constant PAIR_FEE_GUARDIAN = keccak256("PAIR_FEE_GUARDIAN");
    bytes32 public constant TRADE_FEE_GUARDIAN = keccak256("TRADE_FEE_GUARDIAN");
    bytes32 public constant WHITELIST_ADDRESS_GUARDIAN = keccak256("WHITELIST_ADDRESS_GUARDIAN");
    bytes32 public constant WHITELIST_SWITCH_GUARDIAN = keccak256("WHITELIST_SWITCH_GUARDIAN");

    event AddressWhitelisted(address _address, bool _whitelistStatus);
    event WhitelistEnabled(bool);
    event FeeSetterChanged(address);
    event NewTradeFees(uint256[] _values, uint256[] _fee);
    event NewPairFee(address _lpAddress, uint256 _fee);

    constructor(IBabyDogeRouter _router){
        router = _router;

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        // setting ROLE_SETTER as admin roles of all roles but WHITELIST_SWITCH_GUARDIAN
        // this way we can renounce DEFAULT_ADMIN_ROLE to block enabling whitelist forever
        _setRoleAdmin(PAIR_FEE_GUARDIAN, ROLE_SETTER);
        _setRoleAdmin(TRADE_FEE_GUARDIAN, ROLE_SETTER);
        _setRoleAdmin(WHITELIST_ADDRESS_GUARDIAN, ROLE_SETTER);
    }

    /**
     * @notice Sets special offer fee for specific pair
     * @param _lpAddress LP token address
     * @param _fee Amount of special fee for this pair (1000000 - no fee)
     * @dev Only PAIR_FEE_GUARDIAN role
     */
    function setPairFee(
        address _lpAddress,
        uint256 _fee
    ) external onlyRole(PAIR_FEE_GUARDIAN) {
        require(_fee <= 1_000_000, "Invalid fee");
        router.setPairFee(_lpAddress, _fee);
        emit NewPairFee(_lpAddress, _fee);
    }


    /**
     * @notice Function sets new trade fees and corresponding balance values
     * @param _values - List of Doge Token balance values, that should correspond list of fees
     * @param _fee - List of fees, will be applied to users according to their balances
     * @dev Only TRADE_FEE_GUARDIAN role
     */
    function setTradeFee(uint256[] calldata _values, uint256[] calldata _fee)
    external onlyRole(TRADE_FEE_GUARDIAN)
    {
        router.setTradeFee(_values, _fee);
        emit NewTradeFees(_values, _fee);
    }


    /**
     * @notice Allows or restricts account from trading
     * @param _address - Account address
     * @param _whitelistStatus - Should he be allowed to interact with exchange
     * @dev Only WHITELIST_ADDRESS_GUARDIAN role
     */
    function whitelistAddress(address _address, bool _whitelistStatus)
    external onlyRole(WHITELIST_ADDRESS_GUARDIAN)
    {
        router.whitelistAddress(_address, _whitelistStatus);
        emit AddressWhitelisted(_address, _whitelistStatus);
    }


    /**
     * @notice Enables or disables whitelist requirement
     * @param _require - true - enable, false - disable
     * @dev Only WHITELIST_SWITCH_GUARDIAN role
     */
    function setWhitelistRequire(bool _require)
    external onlyRole(WHITELIST_SWITCH_GUARDIAN)
    {
        router.setWhitelistRequire(_require);
        emit WhitelistEnabled(_require);
    }


    /**
     * @notice Function sets new Fee Setter
     * @param _feeSetter - Who do you want to become Fee Setter?
     * @dev This contract will become useless after changing fee setter
     */
    function setFeeSetter(address _feeSetter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeSetter != address(0), "Invalid address");
        router.setFeeSetter(_feeSetter);
        emit FeeSetterChanged(_feeSetter);
    }
}


interface IBabyDogeRouter {
    function setPairFee(address _lpAddress, uint256 _fee) external;
    function setFeeSetter(address _feeSetter) external;
    function setTradeFee(uint256[] memory _values, uint256[] memory _fee) external;
    function whitelistAddress(address _address, bool _whitelistStatus) external;
    function setWhitelistRequire(bool _require) external;
}