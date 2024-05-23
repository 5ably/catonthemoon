// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMoncatStaking {
    function mintPoints(
        address[] calldata _addresses,
        uint[] calldata _amounts
    ) external;

    function burnPoints(
        address[] calldata _addresses,
        uint[] calldata _amounts
    ) external;
}

contract MoncatLottery is ReentrancyGuard, Ownable {
    IMoncatStaking public MoncatStaking;

    uint public packPrice = 10000e9;
    uint public packsMinted;
    uint public totalSpent;
    uint public totalEarned;

    uint public minOpeningDelay = 1;
    uint public maxOpeningDelay = 250;

    uint[5] public rewardsRate = [50, 5, 200, 500, 2500];

    struct PackInfo {
        uint minOpeningBlock;
        uint maxOpeningBlock;
    }

    mapping(address => uint[]) public ownedPacks;
    mapping(uint => PackInfo) public packsInfos;

    constructor(address _moncatStaking) Ownable(msg.sender) {
        MoncatStaking = IMoncatStaking(_moncatStaking);
    }

    function setParameters(
        uint _packPrice,
        uint _minOpeningDelay,
        uint _maxOpeningDelay
    ) external onlyOwner {
        packPrice = _packPrice;
        minOpeningDelay = _minOpeningDelay;
        maxOpeningDelay = _maxOpeningDelay;
    }

    function purchasePacks(uint _amount) external nonReentrant {
        MoncatStaking.burnPoints(
            getArray(msg.sender),
            getArray(_amount * packPrice)
        );

        totalSpent += _amount * packPrice;

        for (uint i = 0; i < _amount; i++) {
            packsInfos[packsMinted] = PackInfo(
                block.number + minOpeningDelay,
                block.number + maxOpeningDelay
            );
            ownedPacks[msg.sender].push(packsMinted);
            packsMinted++;
        }
    }

    function openPacks() external nonReentrant returns (uint totalGains) {
        address user = msg.sender;

        uint i;
        while (i < ownedPacks[user].length) {
            uint _mintId = ownedPacks[user][i];
            if (block.number <= packsInfos[_mintId].minOpeningBlock) {
                i++;
                continue;
            }

            if (block.number > packsInfos[_mintId].maxOpeningBlock) {
                totalGains += getRewardsFromRateId(1);
            } else {
                totalGains += getRandomizedRewards(
                    _mintId,
                    packsInfos[_mintId].minOpeningBlock
                );
            }

            ownedPacks[user][i] = ownedPacks[user][ownedPacks[user].length - 1];
            ownedPacks[user].pop();
        }

        if (totalGains > 0)
            MoncatStaking.mintPoints(getArray(user), getArray(totalGains));
        totalEarned += totalGains;
    }

    function areOpenable(address _user) external view returns (bool) {
        for (uint i = 0; i < ownedPacks[_user].length; i++) {
            if (
                block.number <= packsInfos[ownedPacks[_user][i]].minOpeningBlock
            ) return false;
        }
        return true;
    }

    function getArray(
        address _address
    ) public pure returns (address[] memory array) {
        array = new address[](1);
        array[0] = _address;
    }

    function getArray(uint _uint) public pure returns (uint[] memory array) {
        array = new uint[](1);
        array[0] = _uint;
    }

    function getRewardsFromRateId(uint _rateId) public view returns (uint) {
        return (packPrice * rewardsRate[_rateId]) / 100;
    }

    function getRandomizedRewards(
        uint _mintId,
        uint _minClaimBlock
    ) public view returns (uint) {
        uint seed = (uint(
            keccak256(
                abi.encodePacked(msg.sender, blockhash(_minClaimBlock), _mintId)
            )
        ) % 10000);

        if (seed <= 7991) return getRewardsFromRateId(0);
        if (seed <= 9589) return getRewardsFromRateId(1);
        if (seed <= 9909) return getRewardsFromRateId(2);
        if (seed <= 9973) return getRewardsFromRateId(3);
        return getRewardsFromRateId(4);
    }

    function getOwnedPacks(
        address _user
    ) external view returns (uint[] memory) {
        return ownedPacks[_user];
    }
}
