// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BondingCurve/CurveBondedToken.sol";
import "./CelebStarRewards.sol"; 

contract CelebStar is CurveBondedToken, CelebStarRewards {
    using SafeMath for uint256;

    uint256 private _currentTokenID = 0;
    IERC20 private talContract;

    uint256 public collectedOperationsFee = 0;

    // OPERATION_FEE_PERCENTAGE is in 3 decimal digits
    // So value 100 means the percentage is 100 * 10^-3 = 0.1%
    uint32 public constant OPERATION_FEE_PERCENTAGE = 100;

    enum ClaimStatusCode {
        NoActiveReward,
        RewardAlreadyClaimed,
        InsufficientBalance,
        TransferFailed,
        RewardedCelebIdNotFetched,
        ClaimSuccess
    }

    event RegisteredCelebToken(address from, uint256 id);
    event FirstTimeRewardEnabled(address account, uint256 celebId, uint256 amount);

    constructor(
        uint256 _reserveRatio,
        address _talContractAddress,
        address _oracleClientAddress
    ) CurveBondedToken(_reserveRatio) CelebStarRewards(_oracleClientAddress) {
        talContract = IERC20(_talContractAddress);
    }

    function mint(uint256 _id, uint256 _deposit) external payable {
        require(_id < _currentTokenID, "Invalid token id.");

        bool status = false;
        ClaimStatusCode claimStatusCode;
        string memory claimMsg;
        uint256 rewardAmt;
        (status, claimStatusCode, claimMsg, rewardAmt) = processRewardClaim(_msgSender());
        if (claimStatusCode == ClaimStatusCode.RewardedCelebIdNotFetched) {
            revert("mint/burn temporarily unavailable!");
        }
        enableFirstTimeReward(_msgSender(), _id, _deposit);

        // Before minting user should approve this contract to send the base tokens amounting to the _deposit.
        uint256 operationFee = collectOperationFee(_deposit);
        uint256 depositAfterFee = _deposit.sub(operationFee);
        _curvedMint(_id, depositAfterFee);
        
        require(
            talContract.transferFrom(_msgSender(), address(this), _deposit),
            "TAL token transer failed."
        );


        transferRewardAmountIfClaimIsSuccessful(claimStatusCode, rewardAmt);
    }

    function burn(uint256 _id, uint256 _amount) external {
        require(_id < _currentTokenID, "Invalid token id.");

        bool status = false;
        ClaimStatusCode claimStatusCode;
        string memory claimMsg;
        uint256 rewardAmt;
        (status, claimStatusCode, claimMsg, rewardAmt) = processRewardClaim(_msgSender());
        if (claimStatusCode == ClaimStatusCode.RewardedCelebIdNotFetched) {
            revert("mint/burn temporarily unavailable!");
        }

        uint256 returnAmount = _curvedBurn(_id, _amount);

        uint256 operationFee = collectOperationFee(returnAmount);
        uint256 returnAmountAfterFee = returnAmount.sub(operationFee);

        transferRewardAmountIfClaimIsSuccessful(claimStatusCode, rewardAmt);

        require(
            talContract.transfer(_msgSender(), returnAmountAfterFee),
            "TAL token transer failed."
        );
    }

    function collectOperationFee(uint256 amount)
        internal
        returns (uint256 operationFee)
    {
        operationFee = calculateOperationFee(amount);
        collectedOperationsFee = collectedOperationsFee.add(operationFee);
    }

    function calculateOperationFee(uint256 _amount) public pure returns(uint256 operationFee) {
        /**
            If Value of OPERATION_FEE_PERCENTAGE = x
            then original percentage value = x * 10^-3

            so (x * 10^-3)% of amount = amount * ((x * 10^-3) / 100)
                                      = amount * x / 10^5
         */
        return _amount.mul(OPERATION_FEE_PERCENTAGE).div(10**5);
    }

    function registerNewCelebrity() external onlyOwner returns (uint256 celebId) {
        // Before registering owner should approve this contract to send (1 * SCALE) base tokens.
        require(
            talContract.transferFrom(_msgSender(), address(this), 1 * SCALE),
            "TAL token transer failed."
        );

        uint256 newCelebId = _currentTokenID++;
        reserveBalance[newCelebId] = 1 * SCALE;
        _mint(_msgSender(), newCelebId, 1 * SCALE, "");
        emit RegisteredCelebToken(_msgSender(), newCelebId);
        return newCelebId;
    }

    function scheduleReward(
        uint256 _start,
        uint256 _end,
        uint256 _commitRewardAmount
    ) external onlyOwner {
        registerAndScheduleReward(_start, _end, _commitRewardAmount);
    }

    function claimRewards(address _account) external {
        bool status = false;
        ClaimStatusCode claimStatusCode;
        string memory claimMsg;
        uint256 rewardAmt;
        (status, claimStatusCode, claimMsg, rewardAmt) = processRewardClaim(_account);
        transferRewardAmountIfClaimIsSuccessful(claimStatusCode, rewardAmt);
        require(status, claimMsg);
    }

    function claimFirstTimeReward(address _account) external {
        require(hasMintedAtleastOnce(_account), "Mint atleast once");
        require(!isFirstTimeRewardClaimed(_account), "Reward already claimed!");
        uint256 firstTimeRewardAmount = getFirstTimeRewardAmount(_account);
        markFirstTimeRewardClaimed(_account);
        require(
            talContract.transfer(_account, firstTimeRewardAmount),
            "TAL token transer failed."
        );
    }

    function addRewardFunds(uint256 _deposit) external {
        // Before calling this method user should approve this contract to send the base tokens amounting to the _deposit.
        require(
            talContract.transferFrom(_msgSender(), address(this), _deposit),
            "TAL token transer failed!"
        );
        depositRewardFunds(_deposit);
    }

    function processRewardClaim(address _account)
        internal
        returns (
            bool status,
            ClaimStatusCode claimStatusCode,
            string memory claimMsg,
            uint256 rewardAmount
        )
    {
        if (!isRewardActive()) {
            return (
                false,
                ClaimStatusCode.NoActiveReward,
                "No active rewards!",
                0
            );
        }

        uint256 rewardId = getActiveRewardId();
        if (isRewardClaimed(_account, rewardId)) {
            return (
                false,
                ClaimStatusCode.RewardAlreadyClaimed,
                "Reward already claimed!",
                0
            );
        }

        (bool celebIdFetched, uint256 celebIdToReward) = getCelebIdToBeRewarded(
            rewardId
        );
        if (!celebIdFetched) {
            return (
                false,
                ClaimStatusCode.RewardedCelebIdNotFetched,
                "Rewarded celeb id not available!",
                0
            );
        }

        uint256 bal = balanceOf(_account, celebIdToReward);
        if (bal == 0) {
            markClaimed(_account, rewardId, 0);
            return (
                false,
                ClaimStatusCode.InsufficientBalance,
                "Not eligible for reward!",
                0
            );
        }

        uint256 rewardAmt = calculateRewardAmount(rewardId, bal);
        markClaimed(_account, rewardId, rewardAmt);

        return (
            true,
            ClaimStatusCode.ClaimSuccess,
            "Rewards claimed successfully",
            rewardAmt
        );
    }

    function requestRewardedCelebId() external returns (bytes32 _requestId) {
        return super.requestRewardedCelebId(_currentTokenID);
    }

    function enableFirstTimeReward(address _account, uint256 _celebId, uint256 _deposit) internal {
        if(isFirstTimeMinter(_account)) {
            uint256 rewardAmt = calculateFirstTimeRewardAmount(_deposit);
            setFirstTimeReward(_account, _celebId, rewardAmt);        
            emit FirstTimeRewardEnabled(_account, _celebId, rewardAmt);
        }
       
    }

    function calculatePurchaseReturnAfterDeductingFee(uint256 _id, uint256 _amount) external view returns(uint256 purchaseReturn) {
        uint256 operationFee = calculateOperationFee(_amount);
        uint256 depositAfterFee = _amount.sub(operationFee);
        return calculateCurvedMintReturn(_id, depositAfterFee);    
    }

    function calculateSellReturnAfterDeductingFee(uint256 _id, uint256 _amount) external view returns(uint256 sellAmount) {
        uint256 sellReturn = calculateCurvedBurnReturn(_id, _amount);
        uint256 operationFee = calculateOperationFee(sellReturn);
        return sellReturn.sub(operationFee);
    }

    function getCountOfRegisteredCelebrities() external view returns(uint256) {
        return _currentTokenID;
    }

    function transferRewardAmountIfClaimIsSuccessful(ClaimStatusCode claimStatusCode, uint256 rewardAmt) private {
        if (claimStatusCode == ClaimStatusCode.ClaimSuccess) {
            require(
                talContract.transfer(_msgSender(), rewardAmt),
                "TAL token transer failed."
            );
        }
    }

}
