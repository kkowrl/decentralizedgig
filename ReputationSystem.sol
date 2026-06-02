// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title ReputationSystem
 * @notice On-chain reputation and review system for DecentralizedGig HK.
 * @dev UUPS upgradeable implementation with review verification and anti-abuse mechanisms.
 */
contract ReputationSystem is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    error ZeroAddress();
    error InvalidRating();
    error NotAuthorized();
    error AlreadyReviewed();
    error ReviewNotFound();
    error InvalidGig();
    error NotParticipant();
    error SelfReview();
    error DuplicateReview();

    struct ReviewRecord {
        uint256 gigId;
        address reviewer;
        address reviewee;
        uint8 rating; // 1-5
        string reviewCID; // IPFS CID of review text/evidence
        bool verified;
        uint64 submittedAt;
        uint64 verifiedAt;
    }

    struct ReputationProfile {
        uint32 totalReviews;
        uint32 completedGigs;
        uint32 disputeWins;
        uint32 disputeLosses;
        uint256 totalVolume; // in smallest token unit
        uint64 lastActivityAt;
        uint256 ratingSum; // Sum of all ratings for average calculation
        uint256 weightedRating; // Weighted by volume
    }

    address public registry;
    address public factory;
    
    mapping(uint256 gigId => mapping(address reviewer => bool)) public hasReviewed;
    mapping(address => ReputationProfile) public profiles;
    mapping(uint256 => ReviewRecord) public reviews;
    uint256 public nextReviewId;

    event ReviewSubmitted(
        uint256 indexed reviewId,
        uint256 indexed gigId,
        address indexed reviewer,
        address reviewee,
        uint8 rating,
        string reviewCID
    );

    event ReviewVerified(
        uint256 indexed reviewId,
        address indexed verifier,
        uint64 verifiedAt
    );

    event ReputationUpdated(
        address indexed user,
        uint32 totalReviews,
        uint256 averageRating,
        uint256 weightedRating
    );

    function initialize(address owner_, address registry_) external initializer {
        if (owner_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();
        
        registry = registry_;
        nextReviewId = 1;
    }

    /**
     * @notice Submit a review for a completed gig.
     * @param gigId The completed gig ID
     * @param reviewee The address being reviewed
     * @param rating Rating from 1-5
     * @param reviewCID IPFS CID containing review details and evidence
     */
    function submitReview(
        uint256 gigId,
        address reviewee,
        uint8 rating,
        string calldata reviewCID
    ) external whenNotPaused nonReentrant {
        if (rating < 1 || rating > 5) revert InvalidRating();
        if (reviewee == address(0)) revert ZeroAddress();
        if (reviewee == msg.sender) revert SelfReview();
        if (hasReviewed[gigId][msg.sender]) revert DuplicateReview();

        // Verify the reviewer was a participant in the gig
        // This would require integration with GigRegistry to validate
        // For MVP, we'll implement basic validation
        
        uint256 reviewId = nextReviewId++;
        reviews[reviewId] = ReviewRecord({
            gigId: gigId,
            reviewer: msg.sender,
            reviewee: reviewee,
            rating: rating,
            reviewCID: reviewCID,
            verified: false,
            submittedAt: uint64(block.timestamp),
            verifiedAt: 0
        });

        hasReviewed[gigId][msg.sender] = true;

        emit ReviewSubmitted(reviewId, gigId, msg.sender, reviewee, rating, reviewCID);
        
        // Auto-verify for MVP (in production, this would require manual verification)
        _verifyReview(reviewId);
    }

    /**
     * @notice Verify a review (admin/authorized verifier only).
     * @param reviewId The review ID to verify
     */
    function verifyReview(uint256 reviewId) external whenNotPaused {
        if (msg.sender != owner() && msg.sender != factory) revert NotAuthorized();
        _verifyReview(reviewId);
    }

    /**
     * @notice Update reputation metrics when a gig is completed.
     * @param user The user whose reputation to update
     * @param gigValue The value of the completed gig
     * @param wasDisputeWon Whether the user won a dispute
     */
    function updateReputationOnGigCompletion(
        address user,
        uint256 gigValue,
        bool wasDisputeWon
    ) external whenNotPaused {
        if (msg.sender != registry && msg.sender != factory) revert NotAuthorized();
        if (user == address(0)) revert ZeroAddress();

        ReputationProfile storage profile = profiles[user];
        
        profile.completedGigs++;
        profile.totalVolume += gigValue;
        profile.lastActivityAt = uint64(block.timestamp);
        
        if (wasDisputeWon) {
            profile.disputeWins++;
        }

        _updateWeightedRating(user);
    }

    /**
     * @notice Record dispute outcome.
     * @param user The user involved in dispute
     * @param won Whether the user won the dispute
     */
    function recordDisputeOutcome(address user, bool won) external whenNotPaused {
        if (msg.sender != registry && msg.sender != factory) revert NotAuthorized();
        if (user == address(0)) revert ZeroAddress();

        ReputationProfile storage profile = profiles[user];
        if (won) {
            profile.disputeWins++;
        } else {
            profile.disputeLosses++;
        }
        
        profile.lastActivityAt = uint64(block.timestamp);
    }

    /**
     * @notice Get a user's reputation profile.
     * @param user The user address
     * @return profile The reputation profile
     */
    function getProfile(address user) external view returns (ReputationProfile memory) {
        return profiles[user];
    }

    /**
     * @notice Get a specific review.
     * @param reviewId The review ID
     * @return review The review record
     */
    function getReview(uint256 reviewId) external view returns (ReviewRecord memory) {
        if (reviewId >= nextReviewId) revert ReviewNotFound();
        return reviews[reviewId];
    }

    /**
     * @notice Get average rating for a user.
     * @param user The user address
     * @return averageRating The average rating (scaled by 100 for precision)
     */
    function getAverageRating(address user) external view returns (uint256) {
        ReputationProfile memory profile = profiles[user];
        if (profile.totalReviews == 0) return 0;
        return (profile.ratingSum * 100) / profile.totalReviews;
    }

    /**
     * @notice Get all reviews for a user.
     * @param user The user address
     * @param offset Starting offset
     * @param limit Maximum number of reviews to return
     * @return reviewIds Array of review IDs
     */
    function getUserReviews(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory reviewIds) {
        uint256 count = 0;
        uint256 found = 0;
        
        // First pass: count reviews for this user
        for (uint256 i = 1; i < nextReviewId; i++) {
            if (reviews[i].reviewee == user) {
                count++;
            }
        }
        
        // Allocate array
        uint256 returnCount = count > offset ? (count - offset > limit ? limit : count - offset) : 0;
        reviewIds = new uint256[](returnCount);
        
        // Second pass: collect review IDs
        for (uint256 i = 1; i < nextReviewId && found < returnCount; i++) {
            if (reviews[i].reviewee == user) {
                if (offset > 0) {
                    offset--;
                } else {
                    reviewIds[found] = i;
                    found++;
                }
            }
        }
    }

    /**
     * @notice Set the authorized factory address.
     * @param factory_ Factory contract address
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice Set the registry address.
     * @param registry_ Registry contract address
     */
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
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

    function _verifyReview(uint256 reviewId) internal {
        ReviewRecord storage review = reviews[reviewId];
        if (review.verified) return;

        review.verified = true;
        review.verifiedAt = uint64(block.timestamp);

        // Update reviewee's reputation
        ReputationProfile storage profile = profiles[review.reviewee];
        profile.totalReviews++;
        profile.ratingSum += review.rating;
        profile.lastActivityAt = uint64(block.timestamp);

        _updateWeightedRating(review.reviewee);

        emit ReviewVerified(reviewId, msg.sender, review.verifiedAt);
        emit ReputationUpdated(
            review.reviewee,
            profile.totalReviews,
            (profile.ratingSum * 100) / profile.totalReviews,
            profile.weightedRating
        );
    }

    function _updateWeightedRating(address user) internal {
        ReputationProfile storage profile = profiles[user];
        if (profile.totalReviews == 0) {
            profile.weightedRating = 0;
            return;
        }

        // Weighted rating considers both rating and volume
        uint256 baseRating = (profile.ratingSum * 100) / profile.totalReviews;
        uint256 volumeBonus = profile.totalVolume > 0 ? 
            (profile.totalVolume / 1e18) * 10 : 0; // 10 points per HKD in volume
        
        profile.weightedRating = baseRating + volumeBonus;
    }
}
