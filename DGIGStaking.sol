// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title DGIGStaking
 * @notice Separate staking contract for DGIG token to support juror eligibility and slashing.
 * @dev UUPS upgradeable. Uses `DGIG` ERC-20 token via `IERC20` for transfers.
 */
contract DGIGStaking is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error NotAuthorized();

    IERC20 public dgig;
    mapping(address => uint256) public stakedBalances;
    mapping(address => bool) public authorizedJuryPools;

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event Slashed(address indexed juror, uint256 amount);
    event JuryPoolAuthorized(address indexed pool, bool enabled);

    function initialize(address owner_, address dgig_) external initializer {
        if (owner_ == address(0) || dgig_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();

        dgig = IERC20(dgig_);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    function authorizeJuryPool(address pool, bool enabled) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        authorizedJuryPools[pool] = enabled;
        emit JuryPoolAuthorized(pool, enabled);
    }

    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        stakedBalances[msg.sender] += amount;
        dgig.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalances[msg.sender];
        if (staked < amount) revert InsufficientStake();
        stakedBalances[msg.sender] = staked - amount;
        dgig.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function slashStake(address juror, uint256 amount) external whenNotPaused nonReentrant {
        if (!authorizedJuryPools[msg.sender]) revert NotAuthorized();
        if (juror == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 staked = stakedBalances[juror];
        if (staked == 0) return;

        uint256 slashAmount = amount > staked ? staked : amount;
        stakedBalances[juror] = staked - slashAmount;
        // Burn or transfer slashed tokens to owner (protocol treasury)
        dgig.safeTransfer(owner(), slashAmount);
        emit Slashed(juror, slashAmount);
    }

    function stakedBalanceOf(address account) external view returns (uint256) {
        return stakedBalances[account];
    }
}
