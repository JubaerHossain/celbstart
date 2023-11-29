// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IOracleClientIOracleClient {
    function getExternalAPIResponse(uint256 _rewardId) external view returns(uint256, bool);
    function requestRewardData(uint256 _rewardId, uint256 _celebTokenCount) external returns (bytes32 requestId);
    function hasRequiredLinkBalance(address _account) external view returns (bool);
    function fulfill(bytes32 _requestId, uint256 _celebIdToReward) external;
}
