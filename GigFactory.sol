// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {GigRegistry} from "./GigRegistry.sol";
import {Escrow} from "./Escrow.sol";
import {ReputationSystem} from "./ReputationSystem.sol";
import {SkillCredentials} from "./SkillCredentials.sol";
import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";

/**
 * @title GigFactory
 * @notice Creates gig listings and deploys upgradeable escrow proxies in one flow.
 * @dev The factory is authorized by the registry to link escrow instances.
 */
contract GigFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    error ZeroAddress();
    error InvalidAmount();
    error RegistryNotSet();
    error EscrowImplementationNotSet();
    error NotAuthorized();

    GigRegistry public registry;
    address public escrowImplementation;
    ReputationSystem public reputationSystem;
    SkillCredentials public skillCredentials;

    event GigWithEscrowCreated(uint256 indexed gigId, address indexed client, address indexed worker, address escrow);
    event EscrowImplementationUpdated(address indexed implementation);
    event RegistryUpdated(address indexed registry);
    event ReputationUpdated(address indexed user, uint32 completedGigs, uint256 totalVolume);
    event CredentialIssued(uint256 indexed tokenId, address indexed holder);

    function initialize(address owner_, address registry_, address escrowImplementation_) external initializer {
        if (owner_ == address(0) || registry_ == address(0) || escrowImplementation_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Pausable_init();
        registry = GigRegistry(registry_);
        escrowImplementation = escrowImplementation_;
    }

    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = GigRegistry(registry_);
        emit RegistryUpdated(registry_);
    }

    function setEscrowImplementation(address escrowImplementation_) external onlyOwner {
        if (escrowImplementation_ == address(0)) revert ZeroAddress();
        escrowImplementation = escrowImplementation_;
        emit EscrowImplementationUpdated(escrowImplementation_);
    }

    function setReputationSystem(address reputationSystem_) external onlyOwner {
        if (reputationSystem_ == address(0)) revert ZeroAddress();
        reputationSystem = ReputationSystem(reputationSystem_);
    }

    function setSkillCredentials(address skillCredentials_) external onlyOwner {
        if (skillCredentials_ == address(0)) revert ZeroAddress();
        skillCredentials = SkillCredentials(skillCredentials_);
    }

    function createGigWithEscrow(
        address worker,
        address stablecoin,
        string calldata metadataCID,
        Escrow.EscrowParams calldata escrowParams,
        IDecentralizedGig.MilestoneTerms[] calldata milestones
    ) external returns (uint256 gigId, address escrowProxy) {
        if (registry == GigRegistry(address(0))) revert RegistryNotSet();
        if (escrowImplementation == address(0)) revert EscrowImplementationNotSet();
        if (stablecoin == address(0) || escrowParams.client == address(0) || escrowParams.worker == address(0)) revert ZeroAddress();
        if (escrowParams.client != msg.sender) revert NotAuthorized();
        if (escrowParams.worker != worker) revert NotAuthorized();
        if (milestones.length == 0) revert InvalidAmount();

        gigId = registry.createGigFor(msg.sender, worker, stablecoin, metadataCID);
        if (gigId == 0) revert InvalidAmount();

        Escrow.EscrowParams memory params = escrowParams;
        params.gigId = gigId;

        bytes memory initializeData = abi.encodeWithSelector(
            Escrow.initialize.selector,
            owner(),
            params,
            milestones
        );

        ERC1967Proxy proxy = new ERC1967Proxy(escrowImplementation, initializeData);
        escrowProxy = address(proxy);

        registry.linkEscrow(gigId, escrowProxy);

        emit GigWithEscrowCreated(gigId, msg.sender, worker, escrowProxy);
    }

    /**
     * @notice Update reputation when a gig is completed.
     * @param worker The worker address
     * @param totalAmount Total amount paid for the gig
     */
    function updateReputation(address worker, uint256 totalAmount) external {
        if (msg.sender != address(registry)) revert NotAuthorized();
        if (reputationSystem == ReputationSystem(address(0))) return;

        reputationSystem.updateReputationOnGigCompletion(worker, totalAmount, false);
        
        // Check if worker qualifies for reputation credential
        _issueReputationCredentialIfQualified(worker);
    }

    /**
     * @notice Record dispute outcome.
     * @param user The user involved in dispute
     * @param won Whether the user won the dispute
     */
    function recordDisputeOutcome(address user, bool won) external {
        if (msg.sender != address(registry)) revert NotAuthorized();
        if (reputationSystem == ReputationSystem(address(0))) return;

        reputationSystem.recordDisputeOutcome(user, won);
    }

    /**
     * @notice Get user reputation profile.
     * @param user The user address
     * @return profile Reputation profile data
     */
    function getUserReputation(address user) external view returns (IDecentralizedGig.ReputationSnapshot memory) {
        if (reputationSystem == ReputationSystem(address(0))) {
            return IDecentralizedGig.ReputationSnapshot({
                subject: user,
                completedGigs: 0,
                disputeWins: 0,
                disputeLosses: 0,
                totalVolume: 0,
                lastActivityAt: 0
            });
        }

        ReputationSystem.ReputationProfile memory profile = reputationSystem.getProfile(user);
        
        return IDecentralizedGig.ReputationSnapshot({
            subject: user,
            completedGigs: profile.completedGigs,
            disputeWins: profile.disputeWins,
            disputeLosses: profile.disputeLosses,
            totalVolume: profile.totalVolume,
            lastActivityAt: profile.lastActivityAt
        });
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    function _issueReputationCredentialIfQualified(address worker) internal {
        if (skillCredentials == SkillCredentials(address(0))) return;
        
        ReputationSystem.ReputationProfile memory profile = reputationSystem.getProfile(worker);
        
        // Issue credential if user has completed 5+ gigs
        if (profile.completedGigs >= 5 && profile.completedGigs % 5 == 0) {
            uint256 averageRating = reputationSystem.getAverageRating(worker);
            
            skillCredentials.issueReputationCredential(
                worker,
                profile.completedGigs,
                profile.totalVolume,
                averageRating
            );

            emit CredentialIssued(0, worker); // Token ID would be returned in full implementation
            emit ReputationUpdated(worker, profile.completedGigs, profile.totalVolume);
        }
    }
}
