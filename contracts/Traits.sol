// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "./library/Strings.sol";
import "./interfaces/ITraits.sol";
import "./interfaces/IMiner.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Traits is OwnableUpgradeable, ITraits {

  using Strings for uint256;

  // mapping from trait type (index) to its name
  string[] _traitTypes;

  string[] _levels;

  IMiner public miner;

  function initialize() external initializer {
      __Ownable_init();
      _traitTypes.push("Generation");
      _traitTypes.push("Type");
      _traitTypes.push("Gender");
      _traitTypes.push("Level");
      _levels.push("1");
      _levels.push("2");
      _levels.push("3");
      _levels.push("4");
      _levels.push("5");
      _levels.push("6");
      _levels.push("7");
      _levels.push("8");
  }

  /** ADMIN */
  function setMiner(address _miner) external onlyOwner {
    miner = IMiner(_miner);
  }

  /**
   * generates an attribute for the attributes array in the ERC721 metadata standard
   * @param traitType the trait type to reference as the metadata key
   * @param value the token's trait associated with the key
   * @return a JSON dictionary for the single attribute
   */
  function attributeForTypeAndValue(string memory traitType, string memory value) internal pure returns (string memory) {
    return string(abi.encodePacked(
      '{"trait_type":"',
      traitType,
      '","value":"',
      value,
      '"}'
    ));
  }

  /**
   * generates an array composed of all the individual traits and values
   * @param tokenId the ID of the token to compose the metadata for
   * @return a JSON array of all of the attributes for given token ID
   */
  function compileAttributes(uint256 tokenId) public view returns (string memory) {
    IMiner.MinerLooter memory s = miner.getTokenTraits(tokenId);
    string memory traits;

    traits = string(abi.encodePacked(
      attributeForTypeAndValue(_traitTypes[0], generationString(s)),',',
      attributeForTypeAndValue(_traitTypes[1], typeString(s)),',',
      attributeForTypeAndValue(_traitTypes[2], genderString(s)),',',
      attributeForTypeAndValue(_traitTypes[3], _levels[s.level - 1])
    ));
    
    return string(abi.encodePacked(
      '[',
      traits,
      ']'
    ));
  }

  /**
   * generates a base64 encoded metadata response without referencing off-chain content
   * @param tokenId the ID of the token to generate the metadata for
   * @return a base64 encoded JSON dictionary of the token's metadata and SVG
   */
  function tokenURI(uint256 tokenId) public view override returns (string memory) {
    IMiner.MinerLooter memory s = miner.getTokenTraits(tokenId);

    string memory typeStr = typeString(s);
    string memory genderStr = genderString(s);
    string memory levelStr = _levels[s.level - 1];
    string memory imageUrl = nftUrl(0, typeStr, genderStr, levelStr);
    string memory externalUrl = nftUrl(1, typeStr, genderStr, levelStr);
    string memory metadata = string(abi.encodePacked(
      '{"name": "',
      typeStr,
      ' #',
      tokenId.toString(),
      '", "description": "Thousands of Miners & Looters compete on Spice Mine in Unus metaverse to get tempting $SPICE prize, with deadly high stakes. All the metadata are generated and stored 100% on-chain.", ',
      imageUrl,
      ', ',
      externalUrl,
      ', "attributes":',
      compileAttributes(tokenId),
      "}"
    ));

    return string(abi.encodePacked(
      "data:application/json;base64,",
      base64(bytes(metadata))
    ));
  }

  function nftUrl(uint256 urlType, string memory typeStr, string memory genderStr, string memory levelStr) public pure returns(string memory) {
    if (urlType == 0) {
      return string(abi.encodePacked('"image": "https://unusverse.mypinata.cloud/ipfs/QmTRiy6WkS5wecrj8jC9kikwfEyDbx11CSkDizYEBdosHP/', 
        typeStr, 
        genderStr, 
        levelStr, 
        '.png"'));
    } else {
      return string(abi.encodePacked('"external_url": "https://unusdao.finance/static/nft/', 
        typeStr, 
        genderStr, 
        levelStr, 
        '.png"'));
    }
  }

  function typeString(IMiner.MinerLooter memory s) public pure returns (string memory) {
    if (s.nftType == 0) {
      return "Miner";
    } else if (s.nftType == 1) {
      return "Looter";
    } else if (s.nftType == 2) {
      return "Sandworm";
    } else if (s.nftType == 3) {
      return "Bene Gesserit #";
    } else {
      return "Unknown";
    }
  }

  function generationString(IMiner.MinerLooter memory s) public pure returns (string memory) {
    if (s.generation == 0) {
      return "Gen 0";
    } else if (s.generation == 1) {
      return "Gen 1";
    } else {
      return "Gen 2";
    }
  }

  function genderString(IMiner.MinerLooter memory s) public pure returns (string memory) {
    if (s.gender == 0) {
      return "Male";
    } else {
      return "Female";
    }
  }

  /** BASE 64 - Written by Brech Devos */
  string public constant TABLE = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function base64(bytes memory data) internal pure returns (string memory) {
    if (data.length == 0) return '';
    
    // load the table into memory
    string memory table = TABLE;

    // multiply by 4/3 rounded up
    uint256 encodedLen = 4 * ((data.length + 2) / 3);

    // add some extra buffer at the end required for the writing
    string memory result = new string(encodedLen + 32);

    assembly {
      // set the actual output length
      mstore(result, encodedLen)
      
      // prepare the lookup table
      let tablePtr := add(table, 1)
      
      // input ptr
      let dataPtr := data
      let endPtr := add(dataPtr, mload(data))
      
      // result ptr, jump over length
      let resultPtr := add(result, 32)
      
      // run over the input, 3 bytes at a time
      for {} lt(dataPtr, endPtr) {}
      {
          dataPtr := add(dataPtr, 3)
          
          // read 3 bytes
          let input := mload(dataPtr)
          
          // write 4 characters
          mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr(18, input), 0x3F)))))
          resultPtr := add(resultPtr, 1)
          mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr(12, input), 0x3F)))))
          resultPtr := add(resultPtr, 1)
          mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr( 6, input), 0x3F)))))
          resultPtr := add(resultPtr, 1)
          mstore(resultPtr, shl(248, mload(add(tablePtr, and(        input,  0x3F)))))
          resultPtr := add(resultPtr, 1)
      }
      
      // padding with '='
      switch mod(mload(data), 3)
      case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
      case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
    }
    
    return result;
  }
}