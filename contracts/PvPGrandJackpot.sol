// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PvPGrandJackpot
 * @notice Verifiable Onchain Grand Jackpot with explicit Question ID, Target Predictions,
 *         strict 2-ticket wallet cap, 90% winner distribution, 10% protocol fee, and 100% rollover.
 */
contract PvPGrandJackpot is Ownable, EIP712, ReentrancyGuard {
    using ECDSA for bytes32;

    IERC20 public immutable usdgToken;
    address public treasury;
    address public oracleSigner;

    uint256 public constant MAX_TICKETS_PER_WALLET = 2;
    uint256 public constant WINNER_PERCENT = 90;
    uint256 public constant PROTOCOL_FEE_PERCENT = 10;

    struct RoundTier {
        uint256 ticketPrice;       // e.g. 1 USDG, 5 USDG, 10 USDG, 100 USDG, 1000 USDG
        uint256 totalVault;         // Accumulated jackpot prize pool (including rollovers)
        uint256 totalTickets;       // Total tickets sold this round
        bool isSettled;
    }

    // questionId => tier => RoundTier
    mapping(uint256 => mapping(uint256 => RoundTier)) public questionTiers;
    // questionId => tier => userAddress => ticketCount (Strict max 2)
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public userTickets;

    // Ticket structure storing exact Question ID, player, and numeric prediction
    struct Ticket {
        address player;
        uint256 questionId;
        uint256 targetPrediction; // e.g. 77564 or 7756400 (scaled to 2 decimals)
        uint256 timestamp;
    }
    // questionId => tier => Ticket[]
    mapping(uint256 => mapping(uint256 => Ticket[])) internal questionTickets;

    uint256 public currentQuestionId = 1;

    event TicketsPurchased(
        uint256 indexed questionId,
        uint256 indexed tier,
        address indexed player,
        uint256 ticketCount,
        uint256 totalCostWei,
        uint256[] predictions
    );

    event TicketPurchased(
        uint256 indexed questionId,
        uint256 indexed tier,
        address indexed player,
        uint256 ticketNumber,
        uint256 targetPrediction
    );

    event RoundSettled(
        uint256 indexed questionId,
        uint256 indexed tier,
        uint256 actualOutcome,
        uint256 winnerCount,
        uint256 totalPayout,
        uint256 protocolFee,
        uint256 rolloverAmount
    );

    constructor(
        address _usdgToken,
        address _treasury,
        address _oracleSigner
    ) Ownable() EIP712("PvPGrandJackpot", "1.0.0") {
        require(_usdgToken != address(0), "Invalid token");
        require(_treasury != address(0), "Invalid treasury");
        require(_oracleSigner != address(0), "Invalid oracle");
        usdgToken = IERC20(_usdgToken);
        treasury = _treasury;
        oracleSigner = _oracleSigner;
        currentQuestionId = 1;
    }

    /**
     * @notice Purchase jackpot tickets for a specific Question ID, Tier, and explicit Predictions
     * @param questionId Unique identifier of the question (e.g. 1 for BTC Daily Candle)
     * @param tier Dollar tier of the ticket (1, 5, 10, 100, 1000)
     * @param targetPredictions Array of target predictions (e.g. [77564]) - strictly 1 or 2 tickets
     */
    function buyTickets(
        uint256 questionId,
        uint256 tier,
        uint256[] calldata targetPredictions
    ) external nonReentrant {
        uint256 qty = targetPredictions.length;
        require(qty > 0 && qty <= MAX_TICKETS_PER_WALLET, "Must buy 1 or 2 tickets");
        require(tier > 0, "Invalid tier");
        require(questionId > 0, "Invalid questionId");
        require(
            userTickets[questionId][tier][msg.sender] + qty <= MAX_TICKETS_PER_WALLET,
            "Max 2 tickets per wallet reached for this question and tier"
        );

        uint256 totalCostWei = (tier * qty) * 1e6; // USDG is 6 decimals
        require(usdgToken.transferFrom(msg.sender, address(this), totalCostWei), "USDG transfer failed");

        userTickets[questionId][tier][msg.sender] += qty;

        RoundTier storage rTier = questionTiers[questionId][tier];
        rTier.ticketPrice = tier * 1e6;
        rTier.totalVault += totalCostWei;

        for (uint256 i = 0; i < qty; i++) {
            rTier.totalTickets += 1;
            questionTickets[questionId][tier].push(Ticket({
                player: msg.sender,
                questionId: questionId,
                targetPrediction: targetPredictions[i],
                timestamp: block.timestamp
            }));

            emit TicketPurchased(
                questionId,
                tier,
                msg.sender,
                rTier.totalTickets,
                targetPredictions[i]
            );
        }

        emit TicketsPurchased(
            questionId,
            tier,
            msg.sender,
            qty,
            totalCostWei,
            targetPredictions
        );
    }

    /**
     * @notice Single ticket helper
     */
    function buyTicket(
        uint256 questionId,
        uint256 tier,
        uint256 targetPrediction
    ) external nonReentrant {
        uint256[] memory preds = new uint256[](1);
        preds[0] = targetPrediction;
        
        require(tier > 0, "Invalid tier");
        require(questionId > 0, "Invalid questionId");
        require(
            userTickets[questionId][tier][msg.sender] + 1 <= MAX_TICKETS_PER_WALLET,
            "Max 2 tickets per wallet reached"
        );

        uint256 totalCostWei = tier * 1e6;
        require(usdgToken.transferFrom(msg.sender, address(this), totalCostWei), "USDG transfer failed");

        userTickets[questionId][tier][msg.sender] += 1;

        RoundTier storage rTier = questionTiers[questionId][tier];
        rTier.ticketPrice = tier * 1e6;
        rTier.totalVault += totalCostWei;
        rTier.totalTickets += 1;

        questionTickets[questionId][tier].push(Ticket({
            player: msg.sender,
            questionId: questionId,
            targetPrediction: targetPrediction,
            timestamp: block.timestamp
        }));

        emit TicketPurchased(
            questionId,
            tier,
            msg.sender,
            rTier.totalTickets,
            targetPrediction
        );

        emit TicketsPurchased(
            questionId,
            tier,
            msg.sender,
            1,
            totalCostWei,
            preds
        );
    }

    /**
     * @notice Settle jackpot for a question and tier
     *         90% to exact winners. If no exact winner, 100% rolls over to next questionId.
     */
    function settleJackpot(
        uint256 questionId,
        uint256 tier,
        uint256 actualOutcome,
        address[] calldata winners,
        bytes calldata signature
    ) external nonReentrant {
        RoundTier storage rTier = questionTiers[questionId][tier];
        require(!rTier.isSettled, "Already settled");

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SettleJackpot(uint256 questionId,uint256 tier,uint256 actualOutcome,address[] winners)"),
                questionId,
                tier,
                actualOutcome,
                keccak256(abi.encodePacked(winners))
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == oracleSigner, "Invalid oracle signature");

        rTier.isSettled = true;
        uint256 vault = rTier.totalVault;

        if (winners.length > 0 && vault > 0) {
            uint256 netPayout = (vault * WINNER_PERCENT) / 100;
            uint256 protocolFee = vault - netPayout;

            if (protocolFee > 0 && treasury != address(0)) {
                require(usdgToken.transfer(treasury, protocolFee), "Treasury transfer failed");
            }

            uint256 perWinnerPayout = netPayout / winners.length;
            for (uint256 i = 0; i < winners.length; i++) {
                require(usdgToken.transfer(winners[i], perWinnerPayout), "Winner transfer failed");
            }

            emit RoundSettled(questionId, tier, actualOutcome, winners.length, netPayout, protocolFee, 0);
        } else {
            // 100% Rollover to next questionId
            uint256 nextQId = questionId + 1;
            questionTiers[nextQId][tier].totalVault += vault;
            emit RoundSettled(questionId, tier, actualOutcome, 0, 0, 0, vault);
        }
    }

    function setCurrentQuestionId(uint256 _newId) external onlyOwner {
        require(_newId > 0, "Invalid id");
        currentQuestionId = _newId;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    function setOracleSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "Invalid address");
        oracleSigner = _signer;
    }

    function getTickets(uint256 questionId, uint256 tier) external view returns (Ticket[] memory) {
        return questionTickets[questionId][tier];
    }
}
