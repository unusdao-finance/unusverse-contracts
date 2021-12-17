// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "./interfaces/IMiner.sol";
import "./interfaces/IBarn.sol";
import "./interfaces/ITraits.sol";
import "./library/SafeERC20.sol";
import "./library/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

interface IRandomPicker {
  function getRandom(uint256 seed) external view returns (uint256);
  function addNonce() external;
}

interface ISpace {
  function burn(address from, uint256 amount) external;
}

interface IsUDOFairLaunch {
  function depositBUSD(uint256 _amount) external;
}

interface ILiquidityDepositor {
  function depositBUSD(uint256 _amount) external;
}

contract Miner is IMiner, ERC721EnumerableUpgradeable, OwnableUpgradeable, PausableUpgradeable {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  IRandomPicker public random;

  // mint price
  uint256 public MINT_PRICE;  //100 BUSD

  // max number of tokens that can be minted - 15000 in production
  uint256 public MAX_TOKENS;

  // number of tokens that can be claimed for free - 1/3 of MAX_TOKENS
  uint256 public PAID_TOKENS;

  // number of tokens have been minted so far
  uint16 public minted;

  // mapping from tokenId to a struct containing the token's traits
  mapping(uint256 => MinerLooter) public tokenTraits;

  // reference to the Barn for choosing random looter thieves
  IBarn public barn;
  // reference to $Spice for burning on mint
  ISpace public spice;
  // reference to Traits
  ITraits public traits;

  address public paidToken;
  address public sUDO;

  uint16[4][3] public remainder;
  uint16[4][3] public base;

  uint16[4][3] public minerMaxAmount;
  uint16[4][3] public looterMaxAmount;

  uint16[4][3] public minerMintAmount;
  uint16[4][3] public looterMintAmount;

  uint8 public maxPerAmount;
  bool public start;

  IsUDOFairLaunch public sUDOFairLaunch;

  function initialize(
      address _spice, 
      address _traits, 
      uint256 _maxTokens,
      address _paidToken,
      address _sUDO
  ) external initializer {
    __ERC721_init("Spice Game", "SGAME");
    __ERC721Enumerable_init();
    __Ownable_init();
    __Pausable_init();

    MINT_PRICE = 100 ether;
    spice = ISpace(_spice);
    traits = ITraits(_traits);
    MAX_TOKENS = _maxTokens;
    PAID_TOKENS = _maxTokens / 3;
    paidToken = _paidToken;
    sUDO = _sUDO;

    remainder = [[249, 26, 15, 8], [99, 21, 12, 7], [62, 15, 6, 3]];
    base = [[0, 21, 41, 93], [19, 35, 43, 1], [11, 23, 65, 156]];
    minerMaxAmount = [[18, 171, 288, 513], [45, 207, 360, 648], [72, 297, 702, 1269]];
    looterMaxAmount = [[2, 19, 32, 57], [5, 23, 40, 72], [8, 33, 78, 141]];

    maxPerAmount = 20;
    start = false;
  }

  /** EXTERNAL */

  /** 
   * mint a token - 90% Miner, 10% Looter
   * The first 20% are free to claim, the remaining cost $Spice
   */
  function mint(uint256 amount, bool stake, address referrer) external payable whenNotPaused {
    require(tx.origin == _msgSender(), "Only EOA");
    require(minted + amount <= MAX_TOKENS, "All tokens minted");
    require(amount > 0 && amount <= 10, "Invalid mint amount");
    require(referrer != msg.sender, "referrer == msg.sender");
    
    if (minted < PAID_TOKENS) {
      require(minted + amount <= PAID_TOKENS, "All tokens on-sale already sold");
      uint256 paymentAmount = amount * MINT_PRICE;
      uint256 balanceOfSUDO = IERC20(sUDO).balanceOf(msg.sender);
      if (balanceOfSUDO >= 20000000000) {
          paymentAmount = paymentAmount.mul(8).div(10);
      } else if (balanceOfSUDO >= 10000000000) {
          paymentAmount = paymentAmount.mul(9).div(10);
      }
      require(IERC20(paidToken).balanceOf(msg.sender) >= paymentAmount, "Invalid payment amount");

      IERC20(paidToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
      if (referrer != address(0)) {
        uint256 referrerAmount = paymentAmount.div(10);
        safeTransfer(paidToken, referrer, referrerAmount);
        paymentAmount = paymentAmount.sub(referrerAmount);
      }

      uint256 bondAmt = paymentAmount.mul(8).div(10);
      sUDOFairLaunch.depositBUSD(bondAmt);
      if (start == false) {
        stake = false;
      }
    } else {
      require(start == true, "not start");
    }

    uint256 totalSpiceCost = 0;
    uint16[] memory tokenIds = stake ? new uint16[](amount) : new uint16[](0);
    uint256 seed;
    for (uint i = 0; i < amount; i++) {
      minted++;
      random.addNonce();
      seed = random.getRandom(minted);
      address recipient = selectRecipient(seed);
      if (!stake || recipient != _msgSender()) {
        _safeMint(recipient, minted);
      } else {
        _safeMint(address(barn), minted);
        tokenIds[i] = minted;
      }
      generate(minted, seed);
      totalSpiceCost += mintCost(minted);
    }
    
    if (totalSpiceCost > 0) spice.burn(_msgSender(), totalSpiceCost);
    if (stake) barn.addManyToBarnAndPack(_msgSender(), tokenIds);
  }

  /** 
   * the first 1/3 are paid in BUSD
   * the next 1/3 are 2000 $Spice
   * the final 1/3 are 4000 $Spice
   * @param tokenId the ID to check the cost of to mint
   * @return the cost of the given token ID
   */
  function mintCost(uint256 tokenId) public view returns (uint256) {
    if (tokenId <= PAID_TOKENS) return 0;
    if (tokenId <= MAX_TOKENS * 2 / 3) return 2000 ether;
    return 4000 ether;
  }

  function generation(uint256 tokenId) public view returns (uint8) {
    if (tokenId <= PAID_TOKENS) return 0;
    if (tokenId <= MAX_TOKENS * 2 / 3) return 1;
    return 2;
  }

  function currentGeneration() public view returns (uint8) {
    if (minted <= PAID_TOKENS) return 0;
    if (minted <= MAX_TOKENS * 2 / 3) return 1;
    return 2;
  }

  function transferFrom(
    address from,
    address to,
    uint256 tokenId
  ) public virtual override {
    // Hardcode the Barn's approval so that users don't have to waste gas approving
    if (_msgSender() != address(barn))
      require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");
    _transfer(from, to, tokenId);
  }

  /** INTERNAL */

  /**
   * generates traits for a specific token, checking to make sure it's unique
   * @param tokenId the id of the token to generate traits for
   * @param seed a pseudorandom 256 bit number to derive traits from
   * @return t - a struct of traits for the given token ID
   */
  function generate(uint256 tokenId, uint256 seed) internal returns (MinerLooter memory t) {
    t = selectTraits(seed, generation(tokenId));
    tokenTraits[tokenId] = t;
    return t;
  }

  function setMAXTOKENS(uint256 _MAX_TOKENS) public onlyOwner {
     MAX_TOKENS = _MAX_TOKENS;
  }

  /**
   * selects the species and all of its traits based on the seed value
   * @param seed a pseudorandom 256 bit number to derive traits from
   * @return t -  a struct of randomly selected traits
   */
  function selectTraits(uint256 seed, uint8 gen) internal returns (MinerLooter memory t) {
    t.generation = gen;
    if ((seed & 0xFFFF) % 10 != 0) {
        t.nftType = 0; //Minter
    } else {
        t.nftType = 1; //Looter
    }

    seed >>= 16;
    uint16 seed16 = uint16(seed & 0xFFFF) % 1000;
    uint16[4][3] memory tempRemainder = remainder;
    uint16[4][3] memory tempBase = base;

    for (uint8 i = 0; i < 4; ++i) {
        if (seed16 >= tempBase[gen][i]) {
            if (t.nftType == 0) {
                if (minerMintAmount[gen][i] >= minerMaxAmount[gen][i]) {
                    continue;
                }
            } else {
                if (looterMintAmount[gen][i] >= looterMaxAmount[gen][i]) {
                    continue;
                }
            }
            uint16 tempSeed = seed16 - tempBase[gen][i];
            if (tempSeed % tempRemainder[gen][i] == 0) {
                t.level = 5 - i;
                if (t.nftType == 0) {
                    minerMintAmount[gen][i] += 1;
                } else {
                    looterMintAmount[gen][i] += 1;
                }
                break;
            }
        }
    }

    if (t.level == 0) {
        t.level = 1;
    }

    if (t.level >= 4 && t.nftType == 0) {
        seed >>= 16;
        if ((seed & 0xFFFF) % 5 != 0) {
            t.gender = 0; //Male
        } else {
            t.gender = 1; //Female
        }
    } else {
        t.gender = 0; //Male
    }
  }

  /**
   * the first 20% (ETH purchases) go to the minter
   * the remaining 80% have a 10% chance to be given to a random staked looter
   * @param seed a random value to select a recipient from
   * @return the address of the recipient (either the minter or the looter thief's owner)
   */
  function selectRecipient(uint256 seed) internal view returns (address) {
    if (minted <= PAID_TOKENS || ((seed >> 245) % 10) != 0) return _msgSender(); // top 10 bits haven't been used
    address thief = barn.randomLooterOwner(seed >> 144); // 144 bits reserved for trait selection
    if (thief == address(0x0)) return _msgSender();
    return thief;
  }

  function safeTransfer(address _token, address _to, uint256 _amount) internal {
    if (_amount == 0) return;
    IERC20(_token).safeTransfer(_to, _amount);
  }

  /** READ */

  function getTokenTraits(uint256 _tokenId) external view override returns (MinerLooter memory) {
    return tokenTraits[_tokenId];
  }

  function getPaidTokens() external view override returns (uint256) {
    return PAID_TOKENS;
  }

  /** ADMIN */

  /**
   * called after deployment so that the contract can get random looter thieves
   * @param _barn the address of the Barn
   */
  function setBarn(address _barn) external onlyOwner {
    barn = IBarn(_barn);
  }
  
  function setRandomAddress(address _address) external onlyOwner {
    random = IRandomPicker(_address);
  }

  function setsUDOFairLaunch(address _sUDOFairLaunch) external onlyOwner {
    require(_sUDOFairLaunch != address(0), "invalid address");
    sUDOFairLaunch = IsUDOFairLaunch(_sUDOFairLaunch);
    IERC20(paidToken).safeApprove(_sUDOFairLaunch, type(uint256).max);
  }

  /**
   * updates the number of tokens for sale
   */
  function setPaidTokens(uint256 _paidTokens) external onlyOwner {
    PAID_TOKENS = _paidTokens;
  }

  function pause() external onlyOwner whenNotPaused {
    _pause();
  }

  function unpause() external onlyOwner whenPaused {
    _unpause();
  }

  function setMintPrice(uint256 _price) external onlyOwner {
    MINT_PRICE = _price;
  }

  function setMaxPerAmount(uint8 _maxPerAmount) external onlyOwner {
    require(_maxPerAmount != 0 && _maxPerAmount <= 100, "invalid amount");
    maxPerAmount = _maxPerAmount;
  }

  function startGame(address _liquidityDepositor) external onlyOwner {
    require(_liquidityDepositor != address(0), "invalid address");
    require(start == false, "already start");
    start = true;
    uint256 tokenBal = IERC20(paidToken).balanceOf(address(this));
    IERC20(paidToken).safeApprove(_liquidityDepositor, type(uint256).max);
    ILiquidityDepositor(_liquidityDepositor).depositBUSD(tokenBal);
  }

  function withdrawBNB() public onlyOwner {
    payable(owner()).transfer(address(this).balance);
  }

  function withdrawBEP20(address _tokenAddress) public onlyOwner {
    require(_tokenAddress != paidToken, "!safe");
    uint256 tokenBal = IERC20(_tokenAddress).balanceOf(address(this));
    IERC20(_tokenAddress).transfer(msg.sender, tokenBal);
  }

  /** RENDER */

  struct NFT {
    uint256 tokenId;
    uint8 generation;
    uint8 nftType;
    uint8 gender;
    uint8 level;
  }

  function getUserNFT(address _user, uint256 _index, uint8 _len) public view returns(NFT[] memory nfts, uint8 len) {
    require(_len <= maxPerAmount && _len != 0, "invalid length");
    nfts = new NFT[](_len);
    len = 0;

    uint256 bal = balanceOf(_user);
    if (bal == 0 || _index >= bal) {
      return (nfts, len);
    }

    for (uint8 i = 0; i < _len; ++i) {
      uint256 tokenId = tokenOfOwnerByIndex(_user, _index);
      nfts[i].tokenId = tokenId;
      MinerLooter memory miner = tokenTraits[tokenId];
      nfts[i].generation = miner.generation;
      nfts[i].nftType = miner.nftType;
      nfts[i].gender = miner.gender;
      nfts[i].level = miner.level;

      ++_index;
      ++len;
      if (_index >= bal) {
        return (nfts, len);
      }
    }
  }

  function tokenURI(uint256 _tokenId) public view override returns (string memory) {
    require(_exists(_tokenId), "ERC721Metadata: URI query for nonexistent token");
    return traits.tokenURI(_tokenId);
  }
}
