// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


interface IMinerLooter {
    function currentGeneration() external view returns (uint8);
}

contract RandomPicker is OwnableUpgradeable {
    address public miner;
    uint256 public nonce;

    function initialize(
        address _miner
    ) external initializer {
        __Ownable_init();
        nonce = 0;
        miner = _miner;
    }

    modifier onlyMiner {
        require(miner == msg.sender, "no auth miner!");
        _;
    }

    function setMiner(address _miner) public onlyOwner {
        miner = _miner;
    }

    function getRandom(uint256 seed) public view returns (uint256) {
        uint256 r = uint256(keccak256(abi.encodePacked(
            tx.origin,
            blockhash(block.number - 1),
            block.timestamp,
            seed,
            nonce
        )));
        return r;
    }

    function addNonce() public onlyMiner {
        nonce++;
        NFTInfo memory info = whiteList[tx.origin];
        if (info.count > 0) {
            info.count -= 1;
            if (info.count == 0) {
                info.level = 1;
            }
            whiteList[tx.origin] = info;
        }
    }
}
