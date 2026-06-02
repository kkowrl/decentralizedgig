// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title SkillCredentials
 * @notice NFT-based skill credential system for DecentralizedGig HK.
 * @dev UUPS upgradeable ERC-721 with soulbound option and verification.
 */
contract SkillCredentials is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    error ZeroAddress();
    error InvalidTokenId();
    error NotAuthorized();
    error NotOwner();
    error SoulboundTransfer();
    error AlreadyRevoked();
    error InvalidCredentialType();
    error DuplicateCredential();

    enum CredentialType {
        Skill,
        Certification,
        Achievement,
        Reputation
    }

    struct Credential {
        uint256 tokenId;
        address issuer;
        CredentialType credentialType;
        string metadataCID;
        bool soulbound;
        uint64 issuedAt;
        uint64 revokedAt;
        bool revoked;
        uint256 verificationScore; // 0-10000 (0-100% scaled)
    }

    address public factory;
    address public reputationSystem;
    
    uint256 public nextTokenId;
    mapping(uint256 tokenId => Credential) public credentials;
    mapping(address => uint256[]) public userCredentials;
    mapping(bytes32 => bool) public credentialHashExists; // Prevent duplicates

    event CredentialIssued(
        uint256 indexed tokenId,
        address indexed holder,
        address indexed issuer,
        CredentialType credentialType,
        string metadataCID,
        bool soulbound
    );

    event CredentialRevoked(
        uint256 indexed tokenId,
        address indexed revoker,
        uint64 revokedAt
    );

    event CredentialVerified(
        uint256 indexed tokenId,
        address indexed verifier,
        uint256 verificationScore
    );

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        
        __ERC721_init("DecentralizedGig HK Credentials", "DGIG-CRED");
        __ERC721URIStorage_init();
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();
        
        nextTokenId = 1;
    }

    /**
     * @notice Issue a new credential NFT.
     * @param holder The recipient of the credential
     * @param credentialType Type of credential
     * @param metadataCID IPFS CID containing credential metadata
     * @param soulbound Whether the credential is transferable
     * @param verificationScore Initial verification score (0-10000)
     */
    function issueCredential(
        address holder,
        CredentialType credentialType,
        string calldata metadataCID,
        bool soulbound,
        uint256 verificationScore
    ) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        return _issueCredential(holder, credentialType, metadataCID, soulbound, verificationScore, msg.sender);
    }

    function _issueCredential(
        address holder,
        CredentialType credentialType,
        string memory metadataCID,
        bool soulbound,
        uint256 verificationScore,
        address issuer
    ) internal returns (uint256 tokenId) {
        if (holder == address(0)) revert ZeroAddress();
        if (verificationScore > 10000) revert InvalidCredentialType();

        bytes32 credentialHash = keccak256(abi.encode(holder, credentialType, metadataCID));
        if (credentialHashExists[credentialHash]) revert DuplicateCredential();
        credentialHashExists[credentialHash] = true;

        tokenId = nextTokenId++;

        credentials[tokenId] = Credential({
            tokenId: tokenId,
            issuer: issuer,
            credentialType: credentialType,
            metadataCID: metadataCID,
            soulbound: soulbound,
            issuedAt: uint64(block.timestamp),
            revokedAt: 0,
            revoked: false,
            verificationScore: verificationScore
        });

        userCredentials[holder].push(tokenId);
        _safeMint(holder, tokenId);
        _setTokenURI(tokenId, metadataCID);

        emit CredentialIssued(tokenId, holder, issuer, credentialType, metadataCID, soulbound);
    }

    /**
     * @notice Auto-issue reputation credential based on completed gigs.
     * @param holder The user who earned the credential
     * @param completedGigs Number of completed gigs
     * @param totalVolume Total volume handled
     * @param averageRating Average rating (scaled by 100)
     */
    function issueReputationCredential(
        address holder,
        uint32 completedGigs,
        uint256 totalVolume,
        uint256 averageRating
    ) external whenNotPaused nonReentrant {
        if (msg.sender != reputationSystem && msg.sender != factory) revert NotAuthorized();
        if (holder == address(0)) revert ZeroAddress();

        // Create metadata for reputation credential
        string memory metadataCID = _createReputationMetadata(
            completedGigs,
            totalVolume,
            averageRating
        );

        // Calculate verification score based on reputation metrics
        uint256 verificationScore = _calculateReputationScore(
            completedGigs,
            totalVolume,
            averageRating
        );

        _issueCredential(
            holder,
            CredentialType.Reputation,
            metadataCID,
            true,
            verificationScore,
            address(this)
        );
    }

    /**
     * @notice Revoke a credential (issuer or owner only).
     * @param tokenId The credential token ID to revoke
     */
    function revokeCredential(uint256 tokenId) external whenNotPaused {
        if (tokenId >= nextTokenId) revert InvalidTokenId();
        
        Credential storage credential = credentials[tokenId];
        if (credential.revoked) revert AlreadyRevoked();

        if (msg.sender != credential.issuer && msg.sender != owner()) revert NotAuthorized();

        credential.revoked = true;
        credential.revokedAt = uint64(block.timestamp);

        emit CredentialRevoked(tokenId, msg.sender, credential.revokedAt);
    }

    /**
     * @notice Update verification score for a credential.
     * @param tokenId The credential token ID
     * @param verificationScore New verification score (0-10000)
     */
    function updateVerificationScore(
        uint256 tokenId,
        uint256 verificationScore
    ) external whenNotPaused {
        if (verificationScore > 10000) revert InvalidCredentialType();
        if (tokenId >= nextTokenId) revert InvalidTokenId();
        
        Credential storage credential = credentials[tokenId];
        if (credential.revoked) revert AlreadyRevoked();

        if (msg.sender != credential.issuer && msg.sender != owner()) revert NotAuthorized();

        credential.verificationScore = verificationScore;
        emit CredentialVerified(tokenId, msg.sender, verificationScore);
    }

    /**
     * @notice Get credential details.
     * @param tokenId The credential token ID
     * @return credential The credential struct
     */
    function getCredential(uint256 tokenId) external view returns (Credential memory) {
        if (tokenId >= nextTokenId) revert InvalidTokenId();
        return credentials[tokenId];
    }

    /**
     * @notice Get all credentials for a user.
     * @param user The user address
     * @return tokenIds Array of credential token IDs
     */
    function getUserCredentials(address user) external view returns (uint256[] memory) {
        return userCredentials[user];
    }

    /**
     * @notice Get active (non-revoked) credentials for a user.
     * @param user The user address
     * @return activeTokenIds Array of active credential token IDs
     */
    function getActiveCredentials(address user) external view returns (uint256[] memory activeTokenIds) {
        uint256[] memory allCredentials = userCredentials[user];
        uint256 activeCount = 0;
        
        // Count active credentials
        for (uint256 i = 0; i < allCredentials.length; i++) {
            if (!credentials[allCredentials[i]].revoked) {
                activeCount++;
            }
        }
        
        // Create result array
        activeTokenIds = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allCredentials.length; i++) {
            if (!credentials[allCredentials[i]].revoked) {
                activeTokenIds[index] = allCredentials[i];
                index++;
            }
        }
    }

    /**
     * @notice Get credentials by type for a user.
     * @param user The user address
     * @param credentialType The credential type to filter by
     * @return tokenIds Array of matching credential token IDs
     */
    function getCredentialsByType(
        address user,
        CredentialType credentialType
    ) external view returns (uint256[] memory tokenIds) {
        uint256[] memory allCredentials = userCredentials[user];
        uint256 matchingCount = 0;
        
        // Count matching credentials
        for (uint256 i = 0; i < allCredentials.length; i++) {
            if (credentials[allCredentials[i]].credentialType == credentialType && 
                !credentials[allCredentials[i]].revoked) {
                matchingCount++;
            }
        }
        
        // Create result array
        tokenIds = new uint256[](matchingCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allCredentials.length; i++) {
            if (credentials[allCredentials[i]].credentialType == credentialType && 
                !credentials[allCredentials[i]].revoked) {
                tokenIds[index] = allCredentials[i];
                index++;
            }
        }
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function setReputationSystem(address reputationSystem_) external onlyOwner {
        if (reputationSystem_ == address(0)) revert ZeroAddress();
        reputationSystem = reputationSystem_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc ERC721Upgradeable
    function _update(address to, uint256 tokenId, address auth) internal override whenNotPaused returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && tokenId < nextTokenId && credentials[tokenId].soulbound) {
            revert SoulboundTransfer();
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    function _createReputationMetadata(
        uint32 completedGigs,
        uint256 totalVolume,
        uint256 averageRating
    ) internal pure returns (string memory) {
        // In a real implementation, this would create JSON metadata and upload to IPFS
        // For MVP, return a mock CID
        return "QmReputationCredential";
    }

    function _calculateReputationScore(
        uint32 completedGigs,
        uint256 totalVolume,
        uint256 averageRating
    ) internal pure returns (uint256) {
        // Calculate verification score based on reputation metrics
        uint256 gigScore = completedGigs > 50 ? 2500 : (completedGigs * 50); // Max 2500 for gigs
        uint256 volumeScore = totalVolume > 1000 ether ? 2500 : (totalVolume * 2500) / 1000 ether; // Max 2500 for volume
        uint256 ratingScore = averageRating > 500 ? 5000 : averageRating * 10; // Max 5000 for rating
        
        return gigScore + volumeScore + ratingScore;
    }
}
