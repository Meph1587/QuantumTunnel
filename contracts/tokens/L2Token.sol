//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract L2Token is ERC721Enumerable, Ownable {
    constructor() ERC721("L2Token", "L2") Ownable() {}

    function mint(address receiver, uint256 tokenId) public {
        _mint(receiver, tokenId);
    }

    function burn(uint256 tokenId) public {
        _burn(tokenId);
    }
}
