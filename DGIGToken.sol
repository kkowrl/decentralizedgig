// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title DGIGToken
 * @notice Minimal ERC-20 token skeleton for DGIG with staking support for juror eligibility.
 * @dev Upgradeable (UUPS) to allow evolving staking / governance integrations.
 */
contract DGIGToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    error ZeroAddress();
    error ZeroAmount();

    /**
     * @notice Initializes DGIG token.
     * @param owner_ Admin/owner address for upgrades and privileged actions.
     * @param name_ ERC-20 name.
     * @param symbol_ ERC-20 symbol.
     */
    function initialize(address owner_, string calldata name_, string calldata symbol_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
    }

    /**
     * @notice Mints tokens (MVP/dev only).
     * @dev In production, minting must be governed/immutable; left as owner-only stub for Amoy.
     * @param to Recipient address.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }
    /**
     * @notice DGIGToken is a minimal ERC-20 implementation for the protocol.
     * Staking is provided by the separate `DGIGStaking` contract; this contract
     * intentionally exposes only basic ERC20 behavior and minting for tests.
     */

    /**
     * @notice UUPS authorization hook.
     * @param newImplementation New implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}

