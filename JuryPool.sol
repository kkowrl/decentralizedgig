// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";
import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";

interface IEscrow {
    function executeRuling(uint256 disputeId, IDecentralizedGig.DisputeOutcome outcome) external;
}

interface IDGIGStaking {
    function stakedBalanceOf(address account) external view returns (uint256);
    function slashStake(address juror, uint256 amount) external;
    function stake(uint256 amount) external;
}

/**
 * @title JuryPool
 * @notice Stake-weighted juror selection and dispute resolution for DecentralizedGig HK.
 * @dev UUPS upgradeable implementation that rewards majority jurors and slashes incorrect voters.
 */
contract JuryPool is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidState();
    error NotAuthorized();
    error NotJuror();
    error NoEligibleJurors();
    error AlreadyVoted();
    error AlreadySelected();
    error InvalidVote();
    error DisputeNotOpen();
    error InsufficientStake();

    enum DisputeStage {
        None,
        Open,
        Resolved
    }

    struct JurorProfile {
        uint256 totalVotes;
        uint256 correctVotes;
        uint256 incorrectVotes;
        bool active;
    }

    struct Dispute {
        address escrow;
        address opener;
        uint32 milestoneIndex;
        string evidenceCID;
        address bondToken;
        uint256 bondAmount;
        DisputeStage stage;
        IDecentralizedGig.DisputeOutcome outcome;
        address[] jurors;
        uint256 votesForWorker;
        uint256 votesForClient;
        uint256 votesForSplit;
        uint256 totalVotes;
        mapping(address => bool) voted;
        mapping(address => uint8) vote;
    }

    IDGIGStaking public dgigStaking;
    uint256 public minStake;
    uint8 public maxJurors;
    uint16 public penaltyBps;
    uint16 public rewardShareBps;
    uint256 public minDisputeBond;
    uint256 public maxRegisteredConsideration;
    mapping(address => bool) public authorizedEscrows;
    mapping(address => JurorProfile) public jurorProfiles;
    mapping(uint256 => Dispute) private _disputes;
    address[] private _registeredJurors;
    mapping(address => bool) private _registeredJuror;
    uint256 public nextDisputeId;
    
    /// Emitted when a juror's performance stats change
    event JurorPerformanceUpdated(address indexed juror, uint256 totalVotes, uint256 correctVotes, uint256 incorrectVotes);

    event JurorRegistered(address indexed juror);
    event JurorSelected(uint256 indexed disputeId, address indexed juror);
    event JurorStaked(address indexed juror, uint256 amount);
    event JurorSlashed(address indexed juror, uint256 amount);
    event DisputeCreated(uint256 indexed disputeId, address indexed escrow, address indexed opener, uint32 milestoneIndex, uint256 bondAmount);
    event VoteSubmitted(uint256 indexed disputeId, address indexed juror, IDecentralizedGig.DisputeOutcome ruling);
    event DisputeResolved(uint256 indexed disputeId, IDecentralizedGig.DisputeOutcome outcome, uint256 rewardPool, uint256 slashedAmount);
    event EscrowAuthorized(address indexed escrow, bool enabled);

    /// @notice Initialize the JuryPool
    /// @param owner_ Owner address
    /// @param dgigStaking_ DGIG staking contract address
    /// @param minStake_ Minimum stake required to be eligible as juror
    /// @param maxJurors_ Maximum jurors per dispute
    function initialize(address owner_, address dgigStaking_, uint256 minStake_, uint8 maxJurors_) external initializer {
        if (owner_ == address(0) || dgigStaking_ == address(0)) revert ZeroAddress();
        if (minStake_ == 0) revert ZeroAmount();
        if (maxJurors_ == 0) revert InvalidState();

        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();

        dgigStaking = IDGIGStaking(dgigStaking_);
        minStake = minStake_;
        maxJurors = maxJurors_;
        penaltyBps = 1000; // 10% slash for incorrect juror votes
        rewardShareBps = 8000; // 80% of dispute bond goes to jurors
        minDisputeBond = 1;
        maxRegisteredConsideration = 200; // limit considered jurors to avoid gas issues
        nextDisputeId = 1;
    }

    /// @notice Set the minimum stake required to be eligible as juror
    /// @param amount Minimum stake amount in DGIG
    function setMinStake(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        minStake = amount;
    }

    /// @notice Set maximum jurors allowed per dispute
    /// @param count Number of jurors
    function setMaxJurors(uint8 count) external onlyOwner {
        if (count == 0) revert InvalidState();
        maxJurors = count;
    }

    function setAuthorizedEscrow(address escrow, bool enabled) external onlyOwner {
        if (escrow == address(0)) revert ZeroAddress();
        authorizedEscrows[escrow] = enabled;
        emit EscrowAuthorized(escrow, enabled);
    }

    /// @notice Set minimum dispute bond required
    /// @param amount Minimum bond in bond token units
    function setMinDisputeBond(uint256 amount) external onlyOwner {
        minDisputeBond = amount;
    }

    /// @notice Set the maximum number of registered jurors to consider in selection
    /// @param amount Maximum count
    function setMaxRegisteredConsideration(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidState();
        maxRegisteredConsideration = amount;
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

    // Owner registration removed. Jurors are auto-registered during `stake()`.

    /// @notice Stake DGIG tokens to become an active juror
    /// @param amount Amount of DGIG to stake
    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        dgigStaking.stake(amount);
        // Auto-register juror on first stake
        if (!_registeredJuror[msg.sender]) {
            _registeredJurors.push(msg.sender);
            _registeredJuror[msg.sender] = true;
            emit JurorRegistered(msg.sender);
        }
        jurorProfiles[msg.sender].active = true;
        emit JurorStaked(msg.sender, amount);
    }

    function _selectJurors(uint256 disputeId, uint8 count) internal returns (address[] memory) {
        Dispute storage dispute = _disputes[disputeId];
        if (dispute.stage != DisputeStage.Open) revert InvalidState();
        if (dispute.jurors.length != 0) revert AlreadySelected();
        if (count == 0 || count > maxJurors) revert InvalidState();

        uint256 eligibleCount = 0;
        address[] memory candidates = new address[](_registeredJurors.length);
        uint256[] memory weights = new uint256[](_registeredJurors.length);

        for (uint256 i = 0; i < _registeredJurors.length; i++) {
            address juror = _registeredJurors[i];
            uint256 jurorStake = dgigStaking.stakedBalanceOf(juror);
            if (jurorStake < minStake) continue;
            if (juror == dispute.opener) continue;

            uint256 performanceBonus = (jurorStake * (jurorProfiles[juror].correctVotes + 1)) / (jurorProfiles[juror].incorrectVotes + 1);
            uint256 weight = jurorStake + performanceBonus;
            if (weight == 0) continue;

            candidates[eligibleCount] = juror;
            weights[eligibleCount] = weight;
            eligibleCount++;

            // Limit the number of candidates considered to avoid excessive gas
            if (eligibleCount >= maxRegisteredConsideration) break;
        }

        if (eligibleCount < count) revert NoEligibleJurors();

        address[] memory selected = new address[](count);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            totalWeight += weights[i];
        }

        // IMPORTANT: Current randomness is pseudo-random using recent blockhash and other on-chain data.
        // This method is NOT secure against miners/validators and can be manipulated.
        // TODO: Replace this selection mechanism with a verifiable randomness source
        // such as Chainlink VRF (v2) and perform selection in the VRF callback to
        // ensure unbiased and unpredictable juror selection in production.
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), disputeId, address(this), block.timestamp));

        for (uint8 slot = 0; slot < count; slot++) {
            uint256 choice = uint256(seed) % totalWeight;
            uint256 cursor = 0;
            uint256 selectedIndex = type(uint256).max;
            for (uint256 j = 0; j < eligibleCount; j++) {
                if (weights[j] == 0) continue;
                cursor += weights[j];
                if (choice < cursor) {
                    selectedIndex = j;
                    break;
                }
            }
            if (selectedIndex == type(uint256).max) {
                selectedIndex = 0;
            }

            address juror = candidates[selectedIndex];
            selected[slot] = juror;
            dispute.jurors.push(juror);
            emit JurorSelected(disputeId, juror);

            totalWeight -= weights[selectedIndex];
            weights[selectedIndex] = 0;
            seed = keccak256(abi.encodePacked(seed, juror, slot));
        }

        if (dispute.jurors.length != count) revert InvalidState();
        return selected;
    }

    function createDispute(
        address escrow,
        uint32 milestoneIndex,
        address opener,
        string calldata evidenceCID,
        IERC20 bondToken,
        uint256 bondAmount,
        uint8 jurorCount
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (!authorizedEscrows[msg.sender]) revert NotAuthorized();
        if (escrow == address(0) || opener == address(0) || address(bondToken) == address(0)) revert ZeroAddress();
        if (bondAmount == 0) revert ZeroAmount();
        if (jurorCount == 0 || jurorCount > maxJurors) revert InvalidState();

        uint256 disputeId = nextDisputeId++;
        Dispute storage dispute = _disputes[disputeId];
        dispute.escrow = escrow;
        dispute.opener = opener;
        dispute.milestoneIndex = milestoneIndex;
        dispute.evidenceCID = evidenceCID;
        dispute.bondToken = address(bondToken);
        dispute.bondAmount = bondAmount;
        dispute.stage = DisputeStage.Open;
        dispute.outcome = IDecentralizedGig.DisputeOutcome.None;

        // Note: the calling `Escrow` contract should transfer the bond to this contract
        // prior to calling `createDispute`. Avoid double-transfer here.
        if (bondAmount < minDisputeBond) revert InvalidState();
        emit DisputeCreated(disputeId, escrow, opener, milestoneIndex, bondAmount);

        _selectJurors(disputeId, jurorCount);
        return disputeId;
    }

    /// @notice Select jurors for a dispute (owner/external may trigger if needed)
    /// @param disputeId Dispute identifier
    /// @param count Number of jurors to select
    function selectJurors(uint256 disputeId, uint8 count) external whenNotPaused returns (address[] memory) {
        return _selectJurors(disputeId, count);
    }

    /// @notice Submit a vote for a dispute; only selected jurors may call
    /// @param disputeId Dispute identifier
    /// @param ruling Juror's ruling choice
    function submitVote(uint256 disputeId, IDecentralizedGig.DisputeOutcome ruling) external whenNotPaused nonReentrant {
        if (ruling == IDecentralizedGig.DisputeOutcome.None) revert InvalidVote();

        Dispute storage dispute = _disputes[disputeId];
        if (dispute.stage != DisputeStage.Open) revert DisputeNotOpen();
        if (!_isSelectedJuror(dispute, msg.sender)) revert NotJuror();
        if (dispute.voted[msg.sender]) revert AlreadyVoted();

        dispute.voted[msg.sender] = true;
        dispute.vote[msg.sender] = uint8(ruling);
        dispute.totalVotes++;

        if (ruling == IDecentralizedGig.DisputeOutcome.ReleaseToWorker) {
            dispute.votesForWorker++;
        } else if (ruling == IDecentralizedGig.DisputeOutcome.RefundToClient) {
            dispute.votesForClient++;
        } else if (ruling == IDecentralizedGig.DisputeOutcome.Split) {
            dispute.votesForSplit++;
        }

        emit VoteSubmitted(disputeId, msg.sender, ruling);
    }

    /// @notice Resolve a dispute once all jurors have voted. Distributes rewards and applies slashing.
    /// @param disputeId Dispute identifier
    function resolveDispute(uint256 disputeId) external whenNotPaused nonReentrant {
        Dispute storage dispute = _disputes[disputeId];
        if (dispute.stage != DisputeStage.Open) revert DisputeNotOpen();
        if (dispute.totalVotes != dispute.jurors.length) revert InvalidState();

        IDecentralizedGig.DisputeOutcome outcome = _determineOutcome(dispute);
        dispute.outcome = outcome;
        dispute.stage = DisputeStage.Resolved;

        uint256 majorityCount = _majorityCount(dispute, outcome);
        if (majorityCount == 0) {
            majorityCount = dispute.jurors.length;
        }

        uint256 rewardPool = (dispute.bondAmount * rewardShareBps) / 10000;
        uint256 protocolFee = dispute.bondAmount - rewardPool;
        uint256 rewardShare = rewardPool / majorityCount;
        uint256 slashedAmount;

        for (uint256 i = 0; i < dispute.jurors.length; i++) {
            address juror = dispute.jurors[i];
            bool votedMajority = _voteMatchesOutcome(dispute, juror, outcome);
            jurorProfiles[juror].totalVotes++;

            if (votedMajority) {
                if (rewardShare > 0) {
                    IERC20(dispute.bondToken).safeTransfer(juror, rewardShare);
                }
                jurorProfiles[juror].correctVotes++;
            } else {
                uint256 jurorStake = dgigStaking.stakedBalanceOf(juror);
                uint256 slash = (jurorStake * penaltyBps) / 10000;
                if (slash > 0) {
                    dgigStaking.slashStake(juror, slash);
                    slashedAmount += slash;
                    emit JurorSlashed(juror, slash);
                }
                jurorProfiles[juror].incorrectVotes++;
            }

            emit JurorPerformanceUpdated(juror, jurorProfiles[juror].totalVotes, jurorProfiles[juror].correctVotes, jurorProfiles[juror].incorrectVotes);
        }

        if (protocolFee > 0) {
            IERC20(dispute.bondToken).safeTransfer(owner(), protocolFee);
        }

        emit DisputeResolved(disputeId, outcome, rewardPool, slashedAmount);
        IEscrow(dispute.escrow).executeRuling(disputeId, outcome);
    }

    /// @notice Get jurors assigned to a dispute
    /// @param disputeId Dispute identifier
    function getJurors(uint256 disputeId) external view returns (address[] memory) {
        return _disputes[disputeId].jurors;
    }

    /// @notice Get basic dispute metadata
    /// @param disputeId Dispute identifier
    function getDispute(uint256 disputeId)
        external
        view
        returns (
            address escrow,
            address opener,
            uint32 milestoneIndex,
            address bondToken,
            uint256 bondAmount,
            DisputeStage stage,
            IDecentralizedGig.DisputeOutcome outcome,
            uint256 totalVotes
        )
    {
        Dispute storage dispute = _disputes[disputeId];
        return (
            dispute.escrow,
            dispute.opener,
            dispute.milestoneIndex,
            dispute.bondToken,
            dispute.bondAmount,
            dispute.stage,
            dispute.outcome,
            dispute.totalVotes
        );
    }

    function _isSelectedJuror(Dispute storage dispute, address juror) internal view returns (bool) {
        for (uint256 i = 0; i < dispute.jurors.length; i++) {
            if (dispute.jurors[i] == juror) {
                return true;
            }
        }
        return false;
    }

    function _voteMatchesOutcome(Dispute storage dispute, address juror, IDecentralizedGig.DisputeOutcome outcome)
        internal
        view
        returns (bool)
    {
        uint8 voteValue = dispute.vote[juror];
        if (voteValue == 0) return false;
        return voteValue == uint8(outcome);
    }

    function _determineOutcome(Dispute storage dispute) internal view returns (IDecentralizedGig.DisputeOutcome) {
        if (dispute.votesForWorker > dispute.votesForClient && dispute.votesForWorker > dispute.votesForSplit) {
            return IDecentralizedGig.DisputeOutcome.ReleaseToWorker;
        }
        if (dispute.votesForClient > dispute.votesForWorker && dispute.votesForClient > dispute.votesForSplit) {
            return IDecentralizedGig.DisputeOutcome.RefundToClient;
        }
        return IDecentralizedGig.DisputeOutcome.Split;
    }

    function _majorityCount(Dispute storage dispute, IDecentralizedGig.DisputeOutcome outcome) internal view returns (uint256) {
        if (outcome == IDecentralizedGig.DisputeOutcome.ReleaseToWorker) {
            return dispute.votesForWorker;
        }
        if (outcome == IDecentralizedGig.DisputeOutcome.RefundToClient) {
            return dispute.votesForClient;
        }
        return dispute.votesForSplit;
    }
}
