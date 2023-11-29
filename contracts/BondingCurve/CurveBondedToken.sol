// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BancorBondingCurve.sol";

contract CurveBondedToken is BancorBondingCurve, ERC1155Supply {
    using SafeMath for uint256;

    uint256 constant public SCALE = 10**18;
    mapping(uint256 => uint256) public reserveBalance;
    uint256 public reserveRatio;

    event CurvedMint(address account, uint256 received, uint256 deposit);
    event CurvedBurn(address account, uint256 burned, uint256 received);

    constructor(uint256 _reserveRatio) ERC1155("") {
        reserveRatio = _reserveRatio;
    }

    function calculateCurvedMintReturn(uint256 _id, uint256 _amount)
        public
        view
        returns (uint256 mintAmount)
    {
        return
            calculatePurchaseReturn(
                totalSupply(_id),
                reserveBalance[_id],
                uint32(reserveRatio),
                _amount
            );
    }

    function calculateCurvedBurnReturn(uint256 _id, uint256 _amount)
        public
        view
        returns (uint256 burnAmount)
    {
        return
            calculateSaleReturn(
                totalSupply(_id),
                reserveBalance[_id],
                uint32(reserveRatio),
                _amount
            );
    }

    modifier validMint(uint256 _amount) {
        require(_amount > 0, "Deposit must be more than 0!");
        _;
    }

    modifier validBurn(uint256 _id, uint256 _amount) {
        require(_amount > 0, "Amount must be non-zero!");
        require(
            balanceOf(_msgSender(), _id) >= _amount,
            "Insufficient tokens to burn!"
        );
        _;
    }

    function _curvedMint(uint256 _id, uint256 _deposit)
        internal
        validMint(_deposit)
        returns (uint256)
    {
        uint256 amount = calculateCurvedMintReturn(_id, _deposit);
        reserveBalance[_id] = reserveBalance[_id].add(_deposit);
        _mint(_msgSender(), _id, amount, "");
        emit CurvedMint(_msgSender(), amount, _deposit);
        return amount;
    }

    function _curvedBurn(uint256 _id, uint256 _amount)
        internal
        validBurn(_id, _amount)
        returns (uint256)
    {
        uint256 reimburseAmount = calculateCurvedBurnReturn(_id, _amount);
        reserveBalance[_id] = reserveBalance[_id].sub(reimburseAmount);
        _burn(_msgSender(), _id, _amount);
        emit CurvedBurn(_msgSender(), _amount, reimburseAmount);
        return reimburseAmount;
    }
}
