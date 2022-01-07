// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "./interfaces/IERC721Receiver.sol";
import "./interfaces/IMiner.sol";
import "./interfaces/IERC721.sol";
import "./library/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

interface IMinerNFT is IERC721, IMiner{
}

interface ISpice {
    function mint(address to, uint256 amount) external;
}

contract Barn is IERC721Receiver, OwnableUpgradeable, PausableUpgradeable {
    // struct to store a stake's token, owner, and earning values
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address owner, uint256 tokenId, uint256 value);
    event MinerClaimed(uint256 tokenId, uint256 earned, bool unstaked);
    event LooterClaimed(uint256 tokenId, uint256 earned, bool unstaked);

    IMinerNFT public miner;
    ISpice public spice;


    // maps tokenId to stake
    mapping(uint256 => Stake) public barn; 

    // maps level to all Looter stakes with that level
    mapping(uint256 => Stake[]) public pack;

    // tracks location of each Wolf in Pack
    mapping(uint256 => uint256) public packIndices; 

    // total level scores staked
    uint256 public totalLevelStaked; 

    // any rewards distributed when no looters are staked
    uint256 public unaccountedRewards; 

    // amount of $SPICE due for each level point staked
    uint256 public spicePerLevel;

    // miner earn $SPICE per day
    uint256[8] public DAILY_SPICE_EARN;
    
    // miners must have 2 days worth of $SPICE to unstake or else it's too cold
    uint256 public constant MINIMUM_TO_EXIT = 2 days;

    // looters take a 20% tax on all $SPICE claimed
    uint256 public constant MINER_CLAIM_TAX_PERCENTAGE = 20;

    // there will only ever be (roughly) 0.4 billion $SPICE earned through staking
    uint256 public constant MAXIMUM_GLOBAL_SPICE = 400000000 ether;

    // amount of $SPICE earned so far
    uint256 public totalSpiceEarned;

    // number of Miner staked in the Barn for each level
    uint256[8] public totalMinerStakedOfEachLevel;

    // the last time $SPICE was claimed
    uint256 public lastClaimTimestamp;

    // emergency rescue to allow unstaking without any checks but without $SPICE
    bool public rescueEnabled;

    function initialize(address _miner, address _spice) external initializer {
        require(_miner != address(0));
        require(_spice != address(0));

        __Ownable_init();
        __Pausable_init();

        miner = IMinerNFT(_miner);
        spice = ISpice(_spice);
        rescueEnabled = false;
        totalLevelStaked = 0;
        unaccountedRewards = 0;
        spicePerLevel = 0;

        DAILY_SPICE_EARN = [300, 600, 1200, 2400, 4800, 7500, 15000, 22500];
    }

    function setRescueEnabled(bool rescueEnabled_) external onlyOwner {
        rescueEnabled = rescueEnabled_;
    }

    /** STAKING */

    /**
     * adds Miners and Looters to the Barn and Pack
     * @param account the address of the staker
     * @param tokenIds the IDs of the Minters and Looters to stake
    */
    function addManyToBarnAndPack(address account, uint16[] calldata tokenIds) external {
        require(account == _msgSender() || _msgSender() == address(miner), "DONT GIVE YOUR TOKENS AWAY");
        for (uint i = 0; i < tokenIds.length; i++) {
        if (_msgSender() != address(miner)) { // dont do this step if its a mint + stake
            require(miner.ownerOf(tokenIds[i]) == _msgSender(), "AINT YO TOKEN");
            miner.transferFrom(_msgSender(), address(this), tokenIds[i]);
        } else if (tokenIds[i] == 0) {
            continue; // there may be gaps in the array for stolen tokens
        }

        //nftType 0: miner 1: looter
        if (nftType(tokenIds[i]) == 0) 
            _addMinerToBarn(account, tokenIds[i]);
        else 
            _addLooterToPack(account, tokenIds[i]);
        }
    }

    /**
     * adds a single Miner to the Barn
     * @param account the address of the staker
     * @param tokenId the ID of the Miner to add to the Barn
    */
    function _addMinerToBarn(address account, uint256 tokenId) internal whenNotPaused _updateEarnings {
        uint8 level = nftLevel(tokenId);
        require(level > 0, "Invalid level");
        barn[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        totalMinerStakedOfEachLevel[level - 1] += 1;
        emit TokenStaked(account, tokenId, block.timestamp);
    }

    /**
     * adds a single Looter to the Pack
     * @param account the address of the staker
     * @param tokenId the ID of the Looter to add to the Pack
    */
    function _addLooterToPack(address account, uint256 tokenId) internal {
        uint8 level = nftLevel(tokenId);
        require(level > 0, "Invalid level");
        totalLevelStaked += level; // Portion of earnings ranges from 1 to 5
        packIndices[tokenId] = pack[level].length; // Store the location of the Looter in the Pack
        pack[level].push(Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(spicePerLevel)
        })); // Add the looter to the Pack
        emit TokenStaked(account, tokenId, spicePerLevel);
    }

    /** CLAIMING / UNSTAKING */

    /**
     * realize $SPICE earnings and optionally unstake tokens from the Barn / Pack
     * to unstake a Miner it will require it has 2 days worth of $SPICE unclaimed
     * @param tokenIds the IDs of the tokens to claim earnings from
     * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
    */
    function claimManyFromBarnAndPack(uint16[] calldata tokenIds, bool unstake) external whenNotPaused _updateEarnings {
        require(tx.origin == _msgSender(), "Only EOA");
        uint256 owed = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            if (nftType(tokenIds[i]) == 0)
                owed += _claimMinerFromBarn(tokenIds[i], unstake);
            else
                owed += _claimLooterFromPack(tokenIds[i], unstake);
        }
        if (owed == 0) return;
        spice.mint(_msgSender(), owed);
    }

    /**
     * realize $SPICE earnings for a single Miners and optionally unstake it
     * if not unstaking, pay a 20% tax to the staked Looters
     * if unstaking, there is a 50% chance all $SPICE is stolen
     * @param tokenId the ID of the Miners to claim earnings from
     * @param unstake whether or not to unstake the Miners
     * @return owed - the amount of $SPICE earned
    */
    function _claimMinerFromBarn(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
        require(miner.ownerOf(tokenId) == address(this), "AINT A PART OF THE PACK");

        Stake memory stake = barn[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        require(!(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT), "GONNA BE COLD WITHOUT TWO DAY'S SPICE");
        
        uint8 level = nftLevel(tokenId);
        require(level > 0, "Invalid level"); 

        if (totalSpiceEarned < MAXIMUM_GLOBAL_SPICE) {
            owed = (block.timestamp - stake.value) * DAILY_SPICE_EARN[level - 1] / 1 days;
        } else if (stake.value > lastClaimTimestamp) {
            owed = 0; // $SPICE production stopped already
        } else {
            owed = (lastClaimTimestamp - stake.value) * DAILY_SPICE_EARN[level - 1] / 1 days; // stop earning additional $SPICE if it's all been earned
        }
        if (unstake) {
            if (random(tokenId) & 1 == 1) { // 50% chance of all $SPICE stolen
                _payLooterTax(owed);
                owed = 0;
            }
            delete barn[tokenId];
            totalMinerStakedOfEachLevel[level - 1] -= 1;
            miner.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Miner
        } else {
            uint256 tax = owed * MINER_CLAIM_TAX_PERCENTAGE / 100;
            _payLooterTax(tax); // percentage tax to staked Looters
            owed -= tax; // remainder goes to Miner owner
            barn[tokenId].value = uint80(block.timestamp); // reset stake value
        }
        emit MinerClaimed(tokenId, owed, unstake);
    }

    /**
     * realize $SPICE earnings for a single Looter and optionally unstake it
     * Wolves earn $SPICE proportional to their Level rank
     * @param tokenId the ID of the Looter to claim earnings from
     * @param unstake whether or not to unstake the Looter
     * @return owed - the amount of $SPICE earned
    */
    function _claimLooterFromPack(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
        require(miner.ownerOf(tokenId) == address(this), "AINT A PART OF THE PACK");
        uint8 level = nftLevel(tokenId);
        require(level > 0, "Invalid level"); 
        uint256 pos = packIndices[tokenId];
        Stake memory stake = pack[level][pos];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        owed = (level) * (spicePerLevel - stake.value); // Calculate portion of tokens based on Level
        if (unstake) {
            totalLevelStaked -= level; // Remove Level from total staked
            Stake memory lastStake = pack[level][pack[level].length - 1];
            pack[level][pos] = lastStake; // Shuffle last Looter to current position
            packIndices[lastStake.tokenId] = pos;
            pack[level].pop(); // Remove duplicate
            delete packIndices[tokenId]; // Delete old mapping
            miner.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Looter
        } else {
            pack[level][pos].value = uint80(spicePerLevel);
        }
        emit LooterClaimed(tokenId, owed, unstake);
    }

    /**
     * emergency unstake tokens
     * @param tokenIds the IDs of the tokens to claim earnings from
    */
    function rescue(uint256[] calldata tokenIds) external {
        require(rescueEnabled, "RESCUE DISABLED");
        uint256 tokenId;
        Stake memory stake;
        Stake memory lastStake;
        for (uint i = 0; i < tokenIds.length; i++) {
            tokenId = tokenIds[i];
            if (nftType(tokenId) == 0) {
                stake = barn[tokenId];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                delete barn[tokenId];
                uint8 level = nftLevel(tokenId);
                require(level > 0, "Invalid level"); 
                totalMinerStakedOfEachLevel[level - 1] -= 1;
                miner.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Miner
                emit MinerClaimed(tokenId, 0, true);
            } else {
                uint8 level = nftLevel(tokenId);
                require(level > 0, "Invalid level"); 
                uint256 pos = packIndices[tokenId];
                stake = pack[level][pos];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                totalLevelStaked -= level; // Remove Level from total staked
                lastStake = pack[level][pack[level].length - 1];
                pack[level][pos] = lastStake; // Shuffle last Wolf to current position
                packIndices[lastStake.tokenId] = pos;
                pack[level].pop(); // Remove duplicate
                delete packIndices[tokenId]; // Delete old mapping
                miner.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Looter
                emit LooterClaimed(tokenId, 0, true);
            }
        }
    }

    /** ACCOUNTING */

    /** 
     * add $SPICE to claimable pot for the Pack
     * @param amount $SPICE to add to the pot
    */
    function _payLooterTax(uint256 amount) internal {
        if (totalLevelStaked == 0) { // if there's no staked looters
            unaccountedRewards += amount; // keep track of $SPICE due to looters
            return;
        }
        // makes sure to include any unaccounted $SPICE 
        spicePerLevel += (amount + unaccountedRewards) / totalLevelStaked;
        unaccountedRewards = 0;
    }

    /**
     * tracks $SPICE earnings to ensure it stops once 0.4 billion is eclipsed
    */
    modifier _updateEarnings() {
        if (lastClaimTimestamp >= block.timestamp) {
            return;
        }

        if (totalSpiceEarned < MAXIMUM_GLOBAL_SPICE) {
            for (uint256 i = 0; i < 8; ++i) {
                uint256 stakedCount = totalMinerStakedOfEachLevel[i];
                if (stakedCount == 0) {
                    continue;
                }

                uint256 earned = (block.timestamp - lastClaimTimestamp) * stakedCount * DAILY_SPICE_EARN[i] / 1 days;
                totalSpiceEarned += earned;
            }
            lastClaimTimestamp = block.timestamp;
        }
        _;
    }

    /**
     * chooses a random Looter thief when a newly minted token is stolen
     * @param seed a random value to choose a Looter from
     * @return the owner of the randomly selected Looter thief
    */
    function randomLooterOwner(uint256 seed) external view returns (address) {
        if (totalLevelStaked == 0) return address(0x0);
        uint256 bucket = (seed & 0xFFFFFFFF) % totalLevelStaked; // choose a value from 0 to total level staked
        uint256 cumulative = 0;
        seed >>= 32;
        // loop through each bucket of Looters with the same level score
        for (uint i = 1; i <= 5; i++) {
            cumulative += pack[i].length * i;
            // if the value is not inside of that bucket, keep going
            if (bucket >= cumulative) continue;
            // get the address of a random Looter with that level score
            return pack[i][seed % pack[i].length].owner;
        }   
        return address(0x0);
    }

    /**
     * generates a pseudorandom number
     * @param seed a value ensure different outcomes for different sources in the same block
     * @return a pseudorandom value
    */
    function random(uint256 seed) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            tx.origin,
            blockhash(block.number - 1),
            block.timestamp,
            seed
        )));
    }

    /**
     * @param tokenId the ID of the token to check
     * @return nftType_
    */
    function nftType(uint256 tokenId) public view returns (uint8) {
        IMiner.MinerLooter memory nft = miner.getTokenTraits(tokenId);
        return nft.nftType;
    }

    /**
     * @param tokenId the ID of the token to check
     * @return level_
    */
    function nftLevel(uint256 tokenId) public view returns (uint8) {
        IMiner.MinerLooter memory nft = miner.getTokenTraits(tokenId);
        return nft.level;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        IMiner.MinerLooter memory nft = miner.getTokenTraits(tokenId);
        if (nft.nftType == 0) { // Miner
            Stake memory stake = barn[tokenId];
            return stake.owner;
        } else { // Looter
            Stake memory stake = pack[nft.level][packIndices[tokenId]];
            return stake.owner;
        }
    }

    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        if (from != address(this)) {
            require(from == address(0x0), "Cannot send tokens to Barn directly");
        }   
        return IERC721Receiver.onERC721Received.selector;
    }
}