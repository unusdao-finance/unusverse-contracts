// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "./helpers/ERC20.sol";
import "./helpers/Ownable.sol";

contract Spice is ERC20, Ownable {

  // a mapping from an address to whether or not it can mint / burn
  mapping(address => bool) controllers;
  
  constructor() ERC20("SPICE", "SPICE") { }

  /**
   * mints $WOOL to a recipient
   * @param to the recipient of the $WOOL
   * @param amount the amount of $WOOL to mint
   */
  function mint(address to, uint256 amount) external {
    require(controllers[msg.sender], "Only controllers can mint");
    require(tx.origin != _msgSender(), "Not EOA");
    _mint(to, amount);
  }

  /**
   * burns $WOOL from a holder
   * @param from the holder of the $WOOL
   * @param amount the amount of $WOOL to burn
   */
  function burn(address from, uint256 amount) external {
    require(controllers[msg.sender], "Only controllers can burn");
    require(tx.origin != _msgSender(), "Not EOA");
    _burn(from, amount);
  }

  /**
   * enables an address to mint / burn
   * @param controller the address to enable
   */
  function addController(address controller) external onlyOwner {
    controllers[controller] = true;
  }

  /**
   * disables an address from minting / burning
   * @param controller the address to disbale
   */
  function removeController(address controller) external onlyOwner {
    controllers[controller] = false;
  }
}