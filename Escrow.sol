// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IDecentralizedGig} from "./interfaces/IDecentralizedGig.sol";
import {ReentrancyGuardUpgradeable} from "./utils/ReentrancyGuardUpgradeable.sol";

interface IJuryPool {
    function createDispute(
        address escrow,
        uint32 milestoneIndex,
        address opener,
        string calldata evidenceCID,
        IERC20 bondToken,
        uint256 bondAmount,
        uint8 jurorCount
    ) external returns (uint256);
}

/**
 * @title Escrow
 * @notice Multi-milestone escrow for HKD stablecoin gigs.
 * @dev UUPS upgradeable implementation with milestone acceptance and a basic dispute flow.
 */
contract Escrow is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidGig();
    error InvalidMilestone();
    error InvalidState();
    error NotClient();
    error NotWorker();
    error NotParty();
    error NotAuthorized();
    error AmountMismatch();
    error AlreadyFunded();
    error NotFunded();

    enum EscrowState {
        Uninitialized,
        Created,
        Funded,
        InProgress,
        Completed,
        Cancelled,
        Disputed
    }

    enum DisputeState {
        None,
        Open,
        Resolved
    }

    struct EscrowParams {
        uint256 gigId;
        address client;
        address worker;
        address stablecoin;
        address arbitrator;
        uint16 platformFeeBps;
    }

    struct Milestone {
        IDecentralizedGig.MilestoneTerms terms;
        IDecentralizedGig.MilestoneSubmission submission;
        bool accepted;
        uint64 acceptedAt;
    }

    struct Dispute {
        DisputeState state;
        uint32 milestoneIndex;
        string evidenceCID;
        IDecentralizedGig.DisputeOutcome outcome;
        uint256 disputeId;
        uint64 openedAt;
        uint64 resolvedAt;
    }

    EscrowState public escrowState;
    EscrowParams public params;
    uint256 public totalAmount;
    uint256 public fundedAmount;
    uint32 public currentMilestone;

    Milestone[] private _milestones;
    mapping(uint32 => Dispute) private _disputes;
    uint32 private _activeDisputeMilestone;

    event EscrowCreated(
        uint256 indexed gigId,
        address indexed client,
        address indexed worker,
        address stablecoin,
        address arbitrator
    );

    event Deposited(uint256 indexed gigId, address indexed from, uint256 amount);

    event MilestoneSubmitted(
        uint256 indexed gigId,
        uint32 indexed milestoneIndex,
        address indexed worker,
        string deliverableCID,
        bytes32 deliveredHash
    );

    event MilestoneAccepted(uint256 indexed gigId, uint32 indexed milestoneIndex, address indexed client);

    event DisputeOpened(
        uint256 indexed gigId,
        uint32 indexed milestoneIndex,
        address indexed openedBy,
        string evidenceCID
    );

    event DisputeResolved(
        uint256 indexed gigId,
        uint32 indexed milestoneIndex,
        IDecentralizedGig.DisputeOutcome outcome,
        uint256 workerAmount,
        uint256 clientAmount
    );

    event JuryPoolSet(address indexed juryPool);
    event DisputeRegistered(uint256 indexed disputeId, uint256 indexed gigId, address indexed opener, uint256 bondAmount);

    address public juryPool;
    uint16 public disputeBondBps;

    function initialize(address owner_, EscrowParams calldata p, IDecentralizedGig.MilestoneTerms[] calldata milestones)
        external
        initializer
    {
        if (owner_ == address(0)) revert ZeroAddress();
        if (p.client == address(0) || p.worker == address(0) || p.stablecoin == address(0) || p.arbitrator == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();

        if (milestones.length == 0) revert InvalidMilestone();

        escrowState = EscrowState.Created;
        params = p;

        uint256 sum = 0;
        for (uint256 i = 0; i < milestones.length; i++) {
            if (milestones[i].amount == 0) revert AmountMismatch();
            _milestones.push(
                Milestone({
                    terms: milestones[i],
                    submission: IDecentralizedGig.MilestoneSubmission({deliverableCID: "", deliveredHash: bytes32(0), submittedAt: 0}),
                    accepted: false,
                    acceptedAt: 0
                })
            );
            sum += milestones[i].amount;
        }

        totalAmount = sum;
        currentMilestone = 0;
        disputeBondBps = 500; // 5% dispute bond by default

        emit EscrowCreated(p.gigId, p.client, p.worker, p.stablecoin, p.arbitrator);
    }

    function milestoneCount() external view returns (uint256) {
        return _milestones.length;
    }

    function milestone(uint256 index) external view returns (Milestone memory) {
        if (index >= _milestones.length) revert InvalidMilestone();
        return _milestones[index];
    }

    function currentMilestoneIndex() external view returns (uint256) {
        return currentMilestone;
    }

    function getDispute(uint32 milestoneIndex) external view returns (Dispute memory) {
        return _disputes[milestoneIndex];
    }

    function activeDisputeMilestone() external view returns (uint32) {
        return _activeDisputeMilestone;
    }

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (msg.sender != params.client) revert NotClient();
        if (escrowState != EscrowState.Created) revert InvalidState();
        if (amount == 0 || amount != totalAmount) revert AmountMismatch();
        if (fundedAmount != 0) revert AlreadyFunded();

        IERC20(params.stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        fundedAmount = amount;
        escrowState = EscrowState.Funded;

        emit Deposited(params.gigId, msg.sender, amount);
    }

    function submitMilestone(string calldata deliverableCID, bytes32 deliveredHash)
        external
        whenNotPaused
        nonReentrant
    {
        if (msg.sender != params.worker) revert NotWorker();
        if (escrowState != EscrowState.Funded && escrowState != EscrowState.InProgress) revert InvalidState();
        if (currentMilestone >= _milestones.length) revert InvalidMilestone();

        Milestone storage m = _milestones[currentMilestone];
        if (bytes(m.submission.deliverableCID).length != 0) revert InvalidState();

        m.submission = IDecentralizedGig.MilestoneSubmission({
            deliverableCID: deliverableCID,
            deliveredHash: deliveredHash,
            submittedAt: uint64(block.timestamp)
        });

        if (escrowState == EscrowState.Funded) {
            escrowState = EscrowState.InProgress;
        }

        emit MilestoneSubmitted(params.gigId, currentMilestone, msg.sender, deliverableCID, deliveredHash);
    }

    function acceptMilestone() external whenNotPaused nonReentrant {
        if (msg.sender != params.client) revert NotClient();
        if (escrowState != EscrowState.InProgress) revert InvalidState();
        if (currentMilestone >= _milestones.length) revert InvalidMilestone();

        Milestone storage m = _milestones[currentMilestone];
        if (bytes(m.submission.deliverableCID).length == 0) revert InvalidState();
        if (m.accepted) revert InvalidState();
        if (m.terms.verificationMode != IDecentralizedGig.VerificationMode.MutualAcceptance) revert InvalidState();

        m.accepted = true;
        m.acceptedAt = uint64(block.timestamp);

        emit MilestoneAccepted(params.gigId, currentMilestone, msg.sender);
        _finalizeMilestone(currentMilestone);
    }

    function verifyMilestone() external whenNotPaused nonReentrant {
        if (escrowState != EscrowState.InProgress) revert InvalidState();
        if (currentMilestone >= _milestones.length) revert InvalidMilestone();

        Milestone storage m = _milestones[currentMilestone];
        if (m.terms.verificationMode != IDecentralizedGig.VerificationMode.OracleHash) revert InvalidState();
        if (msg.sender != m.terms.verifier) revert NotAuthorized();
        if (bytes(m.submission.deliverableCID).length == 0) revert InvalidState();
        if (m.accepted) revert InvalidState();
        if (m.terms.expectedHash != bytes32(0) && m.submission.deliveredHash != m.terms.expectedHash) revert InvalidState();

        m.accepted = true;
        m.acceptedAt = uint64(block.timestamp);

        emit MilestoneAccepted(params.gigId, currentMilestone, msg.sender);
        _finalizeMilestone(currentMilestone);
    }

    function setJuryPool(address juryPool_) external onlyOwner {
        if (juryPool_ == address(0)) revert ZeroAddress();
        juryPool = juryPool_;
        emit JuryPoolSet(juryPool_);
    }

    function openDispute(string calldata evidenceCID) external whenNotPaused nonReentrant {
        if (msg.sender != params.client && msg.sender != params.worker) revert NotParty();
        if (escrowState != EscrowState.InProgress) revert InvalidState();
        if (currentMilestone >= _milestones.length) revert InvalidMilestone();
        if (_disputes[currentMilestone].state != DisputeState.None) revert InvalidState();

        uint32 milestoneIndex = currentMilestone;
        uint256 milestoneAmount = _milestones[milestoneIndex].terms.amount;
        uint256 disputeId;
        uint256 bondAmount;

        if (juryPool != address(0)) {
            bondAmount = (milestoneAmount * disputeBondBps) / 10000;
            if (bondAmount == 0) bondAmount = 1;
            if (bondAmount > milestoneAmount) revert AmountMismatch();

            IERC20(params.stablecoin).safeTransferFrom(msg.sender, juryPool, bondAmount);
            disputeId = IJuryPool(juryPool).createDispute(
                address(this),
                milestoneIndex,
                msg.sender,
                evidenceCID,
                IERC20(params.stablecoin),
                bondAmount,
                3
            );
            emit DisputeRegistered(disputeId, params.gigId, msg.sender, bondAmount);
        } else {
            bondAmount = 0;
            disputeId = uint256(keccak256(abi.encodePacked(address(this), milestoneIndex, block.timestamp, msg.sender)));
        }

        _disputes[milestoneIndex] = Dispute({
            state: DisputeState.Open,
            milestoneIndex: milestoneIndex,
            evidenceCID: evidenceCID,
            outcome: IDecentralizedGig.DisputeOutcome.None,
            disputeId: disputeId,
            openedAt: uint64(block.timestamp),
            resolvedAt: 0
        });
        _activeDisputeMilestone = milestoneIndex;

        escrowState = EscrowState.Disputed;
        emit DisputeOpened(params.gigId, milestoneIndex, msg.sender, evidenceCID);
    }

    function executeRuling(uint256 disputeId, IDecentralizedGig.DisputeOutcome outcome) external whenNotPaused nonReentrant {
        if (msg.sender != juryPool) revert NotAuthorized();
        _resolveActiveDispute(disputeId, outcome, true);
    }

    function resolveDispute(
        IDecentralizedGig.DisputeOutcome outcome,
        uint256 workerAmount,
        uint256 clientAmount
    ) external whenNotPaused nonReentrant {
        if (msg.sender != params.arbitrator && msg.sender != owner()) revert NotAuthorized();
        if (escrowState != EscrowState.Disputed) revert InvalidState();

        uint32 milestoneIndex = _activeDisputeMilestone;
        Dispute storage d = _disputes[milestoneIndex];
        if (d.state != DisputeState.Open) revert InvalidState();

        uint256 milestoneAmount = _milestones[milestoneIndex].terms.amount;

        if (outcome == IDecentralizedGig.DisputeOutcome.None) revert InvalidState();
        if (outcome == IDecentralizedGig.DisputeOutcome.ReleaseToWorker) {
            workerAmount = milestoneAmount;
            clientAmount = 0;
        } else if (outcome == IDecentralizedGig.DisputeOutcome.RefundToClient) {
            workerAmount = 0;
            clientAmount = milestoneAmount;
        } else if (outcome == IDecentralizedGig.DisputeOutcome.Split) {
            if (workerAmount + clientAmount != milestoneAmount) revert AmountMismatch();
        }

        _applyDisputeResolution(milestoneIndex, outcome, workerAmount, clientAmount, milestoneAmount);
    }

    function _resolveActiveDispute(uint256 disputeId, IDecentralizedGig.DisputeOutcome outcome, bool requireJuryMatch)
        internal
    {
        if (escrowState != EscrowState.Disputed) revert InvalidState();

        uint32 milestoneIndex = _activeDisputeMilestone;
        Dispute storage d = _disputes[milestoneIndex];
        if (d.state != DisputeState.Open) revert InvalidState();
        if (requireJuryMatch && d.disputeId != disputeId) revert InvalidState();
        if (outcome == IDecentralizedGig.DisputeOutcome.None) revert InvalidState();

        uint256 milestoneAmount = _milestones[milestoneIndex].terms.amount;
        uint256 workerAmount;
        uint256 clientAmount;

        if (outcome == IDecentralizedGig.DisputeOutcome.ReleaseToWorker) {
            workerAmount = milestoneAmount;
            clientAmount = 0;
        } else if (outcome == IDecentralizedGig.DisputeOutcome.RefundToClient) {
            workerAmount = 0;
            clientAmount = milestoneAmount;
        } else {
            workerAmount = milestoneAmount / 2;
            clientAmount = milestoneAmount - workerAmount;
        }

        _applyDisputeResolution(milestoneIndex, outcome, workerAmount, clientAmount, milestoneAmount);
    }

    function _applyDisputeResolution(
        uint32 milestoneIndex,
        IDecentralizedGig.DisputeOutcome outcome,
        uint256 workerAmount,
        uint256 clientAmount,
        uint256 milestoneAmount
    ) internal {
        _payout(workerAmount, clientAmount, milestoneAmount);

        Dispute storage d = _disputes[milestoneIndex];
        d.state = DisputeState.Resolved;
        d.outcome = outcome;
        d.resolvedAt = uint64(block.timestamp);

        emit DisputeResolved(params.gigId, milestoneIndex, outcome, workerAmount, clientAmount);

        if (outcome == IDecentralizedGig.DisputeOutcome.RefundToClient) {
            escrowState = EscrowState.Cancelled;
            return;
        }

        if (milestoneIndex + 1 >= _milestones.length) {
            escrowState = EscrowState.Completed;
            currentMilestone = uint32(_milestones.length);
        } else {
            currentMilestone = milestoneIndex + 1;
            escrowState = EscrowState.InProgress;
        }
    }

    function _finalizeMilestone(uint32 milestoneIndex) internal {
        Milestone storage m = _milestones[milestoneIndex];
        uint256 amount = m.terms.amount;
        _payout(amount, 0, amount);

        if (milestoneIndex + 1 >= _milestones.length) {
            escrowState = EscrowState.Completed;
            currentMilestone = uint32(_milestones.length);
        } else {
            currentMilestone = milestoneIndex + 1;
            escrowState = EscrowState.InProgress;
        }
    }

    function _payout(uint256 workerAmount, uint256 clientAmount, uint256 grossAmount) internal {
        if (workerAmount > 0) {
            uint256 fee = (workerAmount * params.platformFeeBps) / 10000;
            uint256 workerNet = workerAmount - fee;
            if (fee > 0) {
                IERC20(params.stablecoin).safeTransfer(owner(), fee);
            }
            IERC20(params.stablecoin).safeTransfer(params.worker, workerNet);
        }

        if (clientAmount > 0) {
            IERC20(params.stablecoin).safeTransfer(params.client, clientAmount);
        }

        if (grossAmount > 0) {
            fundedAmount -= grossAmount;
        }
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
}
