// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MockHKD
 * @notice Mintable ERC-20 stablecoin for Polygon Amoy testing.
 * @dev Upgradeable only for testnet/development scaffolding; production stablecoin should be replaced by a real HKD-pegged asset.
 */
contract MockHKD is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    error ZeroAddress();
    error ZeroAmount();

    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    function initialize(address owner_, string calldata name_, string calldata symbol_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
        emit Burned(from, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}
