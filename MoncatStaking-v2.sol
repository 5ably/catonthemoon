// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MoncatStaking is ReentrancyGuard, Ownable {
    IERC20 moncat;
    address[] public stakers; // array of all unique stakers
    address public taxAddress = 0xE09154F93aD9c9885b7bd828807655C05a2803B0;

    uint public constant MIN_VESTING_PERIOD = 1 days;
    uint public constant MAX_VESTING_PERIOD = 30 days;

    uint private constant FORFEIT_TAX = 40; // tax in percent for claiming before the end of the vesting period

    // rewards point per token per day with 1e12 decimals (1e12 = 1 point per token per day)
    uint public minRewardsRate; // rate for minimum vesting period
    uint public maxRewardsRate; // rate for maximum vesting period

    uint public totalMoncatStaked;
    uint lastRewardTimestamp;

    bool public rewardsOngoing = true;

    mapping(address => UserInfos) public usersInfos;
    mapping(address => bool) public managers; // addresses allowed to mint / burn points

    struct UserInfos {
        bool user;
        // staking
        uint amountStaked;
        uint vestingStartTimestamp;
        uint vestingPeriod;
        uint claimTimestamp;
        // accumulated rewards
        uint catnip;
    }

    constructor(
        address _moncat,
        uint _lowerRate,
        uint _upperRate
    ) Ownable(msg.sender) {
        moncat = IERC20(_moncat);

        minRewardsRate = _lowerRate;
        maxRewardsRate = _upperRate;

        managers[msg.sender] = true;
    }

    function setManager(address _manager, bool _isManager) external onlyOwner {
        managers[_manager] = _isManager;
    }

    function setTaxAddress(address _taxAddress) external onlyOwner {
        taxAddress = _taxAddress;
    }

    function switchRewardsOngoing() external onlyOwner {
        rewardsOngoing = !rewardsOngoing;
        lastRewardTimestamp = block.timestamp;
    }

    function setRewardsRates(
        uint _lowerRate,
        uint _upperRate,
        bool _update
    ) external onlyOwner {
        if (_update) forceUpdateRewards(0, 0);

        minRewardsRate = _lowerRate;
        maxRewardsRate = _upperRate;
    }

    function forceUpdateRewards(
        uint _startIndex,
        uint _endIndex
    ) public onlyOwner {
        if (_endIndex == 0) _endIndex = stakers.length - 1;
        for (uint i = _startIndex; i <= _endIndex; i++) {
            if (usersInfos[stakers[i]].amountStaked == 0) continue;
            _claimRewards(stakers[i]);
        }
    }

    // allow managers to mint reward points to any address
    function mintPoints(
        address[] calldata _addresses,
        uint[] calldata _amounts
    ) external {
        require(managers[msg.sender], "Not manager");
        for (uint i = 0; i < _addresses.length; i++) {
            usersInfos[_addresses[i]].catnip += _amounts[i];
        }
    }

    // allow managers to burn reward points from any address
    function burnPoints(
        address[] calldata _addresses,
        uint[] calldata _amounts
    ) external {
        require(managers[msg.sender], "Not manager");
        for (uint i = 0; i < _addresses.length; i++) {
            usersInfos[_addresses[i]].catnip -= _amounts[i];
        }
    }

    // deposit moncat with a certain vesting period between bounds
    // note : _vestingPeriod is not required (can be 0) if user is already staking
    function deposit(uint _amount, uint _vestingPeriod) external nonReentrant {
        require(_amount > 0, "Amount is 0");
        address user = msg.sender;

        _claimRewards(user); // claim pending rewards points

        moncat.transferFrom(user, address(this), _amount);

        if (usersInfos[user].amountStaked == 0) {
            require(
                _vestingPeriod >= MIN_VESTING_PERIOD &&
                    _vestingPeriod <= MAX_VESTING_PERIOD
            );

            if (!usersInfos[user].user) stakers.push(user); // add user to unique users array

            usersInfos[user] = UserInfos(
                true,
                _amount,
                block.timestamp,
                _vestingPeriod,
                block.timestamp,
                usersInfos[user].catnip
            );
        } else {
            usersInfos[user].amountStaked += _amount;
        }

        totalMoncatStaked += _amount;
    }

    // withdraw moncat from staking (will automatically forfeit if tokens are still locked)
    function withdraw() external nonReentrant {
        address user = msg.sender;
        require(
            usersInfos[user].amountStaked > 0,
            "Current staked amount is 0"
        );

        _claimRewards(user); // claim pending rewards points

        if (isUserVestingLocked(user)) {
            uint tax = (usersInfos[user].amountStaked * FORFEIT_TAX) / 100;
            moncat.transfer(user, usersInfos[user].amountStaked - tax);
            moncat.transfer(taxAddress, tax);
        } else moncat.transfer(user, usersInfos[user].amountStaked);

        totalMoncatStaked -= usersInfos[user].amountStaked;
        usersInfos[user].amountStaked = 0;
    }

    function claimRewards() external nonReentrant {
        _claimRewards(msg.sender);
    }

    function _claimRewards(address _user) internal {
        if (usersInfos[_user].amountStaked == 0) return;
        uint rewards = getClaimableRewards(_user);

        usersInfos[_user].claimTimestamp = (
            rewardsOngoing ? block.timestamp : lastRewardTimestamp
        );
        if (rewards > 0) usersInfos[_user].catnip += rewards;
    }

    function getDailyRewards(address _user) external view returns (uint) {
        return
            (getRewardsRate(usersInfos[_user].vestingPeriod) *
                usersInfos[_user].amountStaked) / 1e12;
    }

    // return rewards rate for a vesting period (linear between minRewardsRate to maxRewardsRate)
    function getRewardsRate(uint _vestingPeriod) public view returns (uint) {
        if (_vestingPeriod < MIN_VESTING_PERIOD) return 0;
        uint t = maxRewardsRate - minRewardsRate;
        return
            ((((_vestingPeriod - MIN_VESTING_PERIOD) * 1e8) /
                (MAX_VESTING_PERIOD - MIN_VESTING_PERIOD)) * t) /
            1e8 +
            minRewardsRate;
    }

    function staked(address _user) external view returns (uint) {
        return usersInfos[_user].amountStaked;
    }

    function getClaimableRewards(address _user) public view returns (uint) {
        uint elapsedTimestamp = (
            rewardsOngoing ? block.timestamp : lastRewardTimestamp
        ) - usersInfos[_user].claimTimestamp;
        return
            (((getRewardsRate(usersInfos[_user].vestingPeriod) *
                elapsedTimestamp) / (1 days)) *
                usersInfos[_user].amountStaked) / 1e12;
    }

    // return total catnip + claimable catnip
    function getTotalPoints(address _user) public view returns (uint) {
        return getClaimableRewards(_user) + usersInfos[_user].catnip;
    }

    // return true if user staking is still locked
    function isUserVestingLocked(address _user) public view returns (bool) {
        return
            usersInfos[_user].vestingStartTimestamp +
                usersInfos[_user].vestingPeriod >
            block.timestamp;
    }

    // get every users address and total points in a range
    function getUsersPoints(
        uint _startIndex,
        uint _endIndex
    ) external view returns (address[] memory, uint[] memory) {
        if (_endIndex == 0) _endIndex = stakers.length - 1;
        uint length = _endIndex - _startIndex + 1;
        address[] memory _stakers = new address[](length);
        uint[] memory _stakersRewards = new uint[](length);

        for (uint i = _startIndex; i <= _endIndex; i++) {
            _stakers[i] = stakers[i];
            _stakersRewards[i] = getTotalPoints(stakers[i]);
        }

        return (_stakers, _stakersRewards);
    }
}
