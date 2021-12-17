// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

interface IMiner {
  // struct to store each token's traits
  struct MinerLooter {
    uint8 generation;
    uint8 nftType;
    uint8 gender;
    uint8 level;
  }

  function getPaidTokens() external view returns (uint256);
  function getTokenTraits(uint256 tokenId) external view returns (MinerLooter memory);
}