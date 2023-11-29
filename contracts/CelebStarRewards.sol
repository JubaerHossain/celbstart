// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

import "./OracleClient/IOracleClient.sol";

contract CelebStarRewards is Ownable(msg.sender) {
    using SafeMath for uint256;
    uint256 public nextRewardId = 1;
    uint256 public availableRewardFunds = 0;
    uint256 public firstTimeRewardPercentage = 5000;

    IOracleClient private oracleClient;

    struct Reward {
        uint256 id;
        uint256 start;
        uint256 end;
        uint256 totalRewardAmount;
        uint256 celebId;
        uint256 totalRewardTokenSupply;
        bool celebIdFetched;
    }

    struct FirstTimeReward {
        uint256 celebId;
        uint256 rewardAmount;
        bool claimed;
    }

    // This mapping stores the last rewardId claimed by the address
    mapping(address => uint256) public claimed;

    mapping(uint256 => Reward) public rewards;

    // This mapping stores the first reward of the address
    mapping(address => FirstTimeReward) public accountFirstTimeReward; 

    event RewardScheduled(
        uint256 id,
        uint256 start,
        uint256 end,
        uint256 totalRewardAmount
    );
    event RewardClaimed(address account, uint256 rewardId, uint256 amount);
    event RewardFundCredited(address account, uint256 fundAmount);
    event RewardDataRequested(uint256 rewardId, bytes32 requestId);
    event FirstTimeRewardClaimed(address account, uint256 celebId, uint256 rewardAmount);

    constructor(address _oracleClientAddress) {
        oracleClient = IOracleClient(_oracleClientAddress);
    }

    function isRewardActive() public view returns (bool) {
        if (nextRewardId == 1) {
            return false;
        }

        return
            (block.number >= rewards[nextRewardId - 1].start) &&
            (block.number <= rewards[nextRewardId - 1].end);
    }

    function isRewardScheduled() public view returns (bool) {
        if (nextRewardId == 1) {
            return false;
        }

        return block.number < rewards[nextRewardId - 1].start;
    }

    function getActiveRewardId() public view returns (uint256 rewardId) {
        require(isRewardActive(), "No active rewards!");
        return nextRewardId - 1;
    }

    function getCelebIdToBeRewarded(uint256 _rewardId)
        public
        returns (bool celebIdFetched, uint256 celebId)
    {
        if (rewards[_rewardId].celebIdFetched) {
            return (true, rewards[_rewardId].celebId);
        }

        (uint256 celebIdToReward, bool responseReceived) = oracleClient
            .getExternalAPIResponse(_rewardId);

        if (responseReceived) {
            rewards[_rewardId].celebIdFetched = true;
            rewards[_rewardId].celebId = celebIdToReward;
            rewards[_rewardId].totalRewardTokenSupply = ERC1155Supply(
                address(this)
            ).totalSupply(celebIdToReward);
            return (true, celebIdToReward);
        }

        return (false, 0);
    }

    function requestRewardedCelebId(uint256 _celebTokenCount)
        internal
        returns (bytes32 requestId)
    {
        uint256 rewardId = getActiveRewardId();
        require(
            !rewards[rewardId].celebIdFetched,
            "Rewarded celeb id already fetched."
        );

        requestId = oracleClient.requestRewardData(rewardId, _celebTokenCount);

        emit RewardDataRequested(rewardId, requestId);
    }

    function calculateRewardAmount(uint256 _rewardId, uint256 _accountBalance)
        public
        view
        returns (uint256)
    {
        return
            rewards[_rewardId].totalRewardAmount.mul(_accountBalance).div(
                rewards[_rewardId].totalRewardTokenSupply
            );
    }

    function isRewardClaimed(address _account, uint256 _rewardId)
        public
        view
        returns (bool)
    {
        return (claimed[_account] == _rewardId);
    }

    function registerAndScheduleReward(
        uint256 _start,
        uint256 _end,
        uint256 _totalRewardAmount
    ) internal onlyOwner {
        require(_start >= block.number, "Cannot schedule for past date");

        require(_start < _end, "Invalid inputs!");

        require(
            availableRewardFunds >= _totalRewardAmount,
            "Not enough reward funds!"
        );

        require(
            !(isRewardActive() || isRewardScheduled()),
            "Rewards distribution is still active or already scheduled!"
        );

        require(
            oracleClient.hasRequiredLinkBalance(address(oracleClient)),
            "Not enough Link balance!"
        );

        uint256 rewardId = nextRewardId++;
        Reward memory rwd = Reward(
            rewardId,
            _start,
            _end,
            _totalRewardAmount,
            0,
            0,
            false
        );
        rewards[rewardId] = rwd;

        emit RewardScheduled(rewardId, _start, _end, _totalRewardAmount);
    }

    function markClaimed(
        address _account,
        uint256 _rewardId,
        uint256 _amount
    ) internal {
        claimed[_account] = _rewardId;
        availableRewardFunds = availableRewardFunds.sub(_amount);
        emit RewardClaimed(_account, _rewardId, _amount);
    }

    function depositRewardFunds(uint256 _deposit) internal {
        availableRewardFunds = availableRewardFunds.add(_deposit);
        emit RewardFundCredited(_msgSender(), _deposit);
    }

    function isFirstTimeMinter(address _account) public view returns(bool) {
        return accountFirstTimeReward[_account].rewardAmount == 0;
    }

    function hasMintedAtleastOnce(address _account) public view returns(bool) {
        return accountFirstTimeReward[_account].rewardAmount != 0;
    }

    function isFirstTimeRewardClaimed(address _account) public view returns(bool) {
        return accountFirstTimeReward[_account].claimed == true;
    }

    function calculateFirstTimeRewardAmount(uint256 _depositAmount) public view returns(uint256){
        return _depositAmount.mul(firstTimeRewardPercentage).div(10**5);
    }

    function setFirstTimeReward(address _account, uint256 _celebId, uint256 _rewardAmt) internal {
        FirstTimeReward memory firstTimeReward = FirstTimeReward(
            _celebId,
            _rewardAmt,
            false
        );
        accountFirstTimeReward[_account] = firstTimeReward;
    }

    function getFirstTimeRewardAmount(address _account) public view returns(uint256){
        return accountFirstTimeReward[_account].rewardAmount;
    }

    function markFirstTimeRewardClaimed(address _account) internal {
        require(availableRewardFunds >= accountFirstTimeReward[_account].rewardAmount, "Not enough reward funds!");
        accountFirstTimeReward[_account].claimed = true;
        availableRewardFunds = availableRewardFunds.sub(accountFirstTimeReward[_account].rewardAmount);
        emit FirstTimeRewardClaimed(_account, accountFirstTimeReward[_account].celebId, accountFirstTimeReward[_account].rewardAmount);
    }

    function updateFirstTimeRewardPercentage(uint256 percent) external onlyOwner {
        firstTimeRewardPercentage = percent;    
    }
 }
