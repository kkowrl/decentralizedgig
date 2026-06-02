// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title GigRegistry
 * @notice Registry for gigs and indexing-friendly events. Escrow logic lives in `Escrow`.
 * @dev Skeleton contract: stores minimal gig headers and emits events for off-chain indexing.
 */
contract GigRegistry is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    error ZeroAddress();
    error InvalidGig();
    error NotAuthorized();
    error AlreadyLinked();

    /**
     * @notice Minimal gig header stored on-chain.
     * @dev Keep storage tight; heavy metadata is in IPFS and referenced by events.
     */
    struct GigHeader {
        address client;
        address worker;
        address stablecoin;
        address escrow;
        IDecentralizedGig.GigStatus status;
        uint64 createdAt;
        string metadataCID;
    }

    uint256 public nextGigId;
    address public factory;
    mapping(uint256 gigId => GigHeader) public gigs;

    /**
     * @notice Initializes the registry.
     * @param owner_ Owner/admin for upgrades and emergency controls.
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();
        nextGigId = 1;
        factory = address(0);
    }

    /**
     * @notice Creates a new gig listing header and emits `GigCreated`.
     * @dev Skeleton: no pricing logic; escrow creation is separate.
     * @param worker Intended worker (may be zero for open gigs).
     * @param stablecoin ERC-20 stablecoin address (mock HKD on Amoy for MVP).
     * @param metadataCID IPFS CID for gig listing metadata.
     * @return gigId Newly created gig id.
     */
    function createGig(address worker, address stablecoin, string calldata metadataCID)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 gigId)
    {
        return _createGig(msg.sender, worker, stablecoin, metadataCID);
    }

    /**
     * @notice Creates a gig on behalf of a client (factory-only).
     * @param client The paying client address.
     * @param worker Intended worker (may be zero for open gigs).
     * @param stablecoin ERC-20 stablecoin address.
     * @param metadataCID IPFS CID for gig listing metadata.
     * @return gigId Newly created gig id.
     */
    function createGigFor(address client, address worker, address stablecoin, string calldata metadataCID)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 gigId)
    {
        if (msg.sender != factory && msg.sender != owner()) revert NotAuthorized();
        if (client == address(0)) revert ZeroAddress();
        return _createGig(client, worker, stablecoin, metadataCID);
    }

    function _createGig(address client, address worker, address stablecoin, string calldata metadataCID)
        internal
        returns (uint256 gigId)
    {
        if (stablecoin == address(0)) revert ZeroAddress();

        gigId = nextGigId++;
        gigs[gigId] = GigHeader({
            client: client,
            worker: worker,
            stablecoin: stablecoin,
            escrow: address(0),
            status: IDecentralizedGig.GigStatus.Open,
            createdAt: uint64(block.timestamp),
            metadataCID: metadataCID
        });

        emit IDecentralizedGig.GigCreated(gigId, client, worker, stablecoin, address(0), metadataCID);
    }

    /**
     * @notice Links an escrow contract to a gig.
     * @dev Skeleton: access control is minimal; final version should only allow protocol factory/escrow creator.
     * @param gigId Gig id.
     * @param escrow Escrow contract address.
     */
    function linkEscrow(uint256 gigId, address escrow) external whenNotPaused {
        if (escrow == address(0)) revert ZeroAddress();
        GigHeader storage g = gigs[gigId];
        if (g.client == address(0)) revert InvalidGig();
        if (msg.sender != g.client && msg.sender != owner() && msg.sender != factory) revert NotAuthorized();
        if (g.escrow != address(0)) revert AlreadyLinked();

        g.escrow = escrow;
        g.status = IDecentralizedGig.GigStatus.InProgress;

        emit IDecentralizedGig.EscrowLinked(gigId, escrow);
    }

    /**
     * @notice Sets the authorized factory address.
     * @param factory_ Factory contract permitted to link escrows.
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice Pause registry actions.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause registry actions.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice UUPS authorization hook.
     * @param newImplementation New implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}

