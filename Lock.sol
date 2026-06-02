// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title Lock
 * @notice Minimal Hardhat scaffold contract. Will be removed once core protocol contracts land.
 */
contract Lock {
    uint256 public unlockTime;
    address payable public owner;

    error UnlockTimeNotInFuture();
    error NotOwner();
    error LockNotExpired();

    constructor(uint256 _unlockTime) payable {
        if (_unlockTime <= block.timestamp) revert UnlockTimeNotInFuture();
        unlockTime = _unlockTime;
        owner = payable(msg.sender);
    }

    function withdraw() external {
        if (msg.sender != owner) revert NotOwner();
        if (block.timestamp < unlockTime) revert LockNotExpired();
        owner.transfer(address(this).balance);
    }
}

