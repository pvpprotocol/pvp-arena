// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PvPGrandJackpot
 * @notice Verifiable Onchain Grand Jackpot Vaults with strict 2-ticket wallet cap,
 *         90% winner distribution, 10% protocol fee, and 100% rollover on no-winner rounds.
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

    // roundId => tier => RoundTier
    mapping(uint256 => mapping(uint256 => RoundTier)) public roundTiers;
    // roundId => tier => userAddress => ticketCount (Strict max 2)
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public userTickets;
    // roundId => tier => ticketId => TicketData
    struct Ticket {
        address player;
        uint256 targetPrediction; // target outcome scaled to 2 decimals (e.g. 2450.50 -> 245050)
        uint256 timestamp;
    }
    mapping(uint256 => mapping(uint256 => Ticket[])) internal tierTickets;

    uint256 public currentRoundId;

    event TicketPurchased(
        uint256 indexed roundId,
        uint256 indexed tier,
        address indexed player,
        uint256 ticketNumber,
        uint256 targetPrediction
    );

    event RoundSettled(
        uint256 indexed roundId,
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
        currentRoundId = 1;
    }

    /**
     * @notice Purchase jackpot ticket (Max 2 tickets per wallet per tier)
     * @param tier Price tier (1, 5, 10, 100, 1000)
     * @param targetPrediction Predicted outcome value
     */
    function buyTicket(uint256 tier, uint256 targetPrediction) external nonReentrant {
        require(tier > 0, "Invalid tier");
        require(userTickets[currentRoundId][tier][msg.sender] < MAX_TICKETS_PER_WALLET, "Max 2 tickets per wallet reached");

        uint256 ticketPriceWei = tier * 1e6; // USDG is 6 decimals
        require(usdgToken.transferFrom(msg.sender, address(this), ticketPriceWei), "USDG transfer failed");

        userTickets[currentRoundId][tier][msg.sender] += 1;
        
        RoundTier storage rTier = roundTiers[currentRoundId][tier];
        rTier.ticketPrice = ticketPriceWei;
        rTier.totalVault += ticketPriceWei;
        rTier.totalTickets += 1;

        tierTickets[currentRoundId][tier].push(Ticket({
            player: msg.sender,
            targetPrediction: targetPrediction,
            timestamp: block.timestamp
        }));

        emit TicketPurchased(
            currentRoundId,
            tier,
            msg.sender,
            rTier.totalTickets,
            targetPrediction
        );
    }

    /**
     * @notice Settle a jackpot round tier with oracle proof
     *         90% distributed equally among exact winners.
     *         If no exact winner, 100% rolls over to the next round.
     */
    function settleRoundTier(
        uint256 roundId,
        uint256 tier,
        uint256 actualOutcome,
        address[] calldata winners,
        bytes calldata signature
    ) external nonReentrant {
        RoundTier storage rTier = roundTiers[roundId][tier];
        require(!rTier.isSettled, "Round tier already settled");

        // Verify EIP-712 proof
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SettleJackpot(uint256 roundId,uint256 tier,uint256 actualOutcome,address[] winners)"),
                roundId,
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

            // Pay protocol fee
            if (protocolFee > 0 && treasury != address(0)) {
                require(usdgToken.transfer(treasury, protocolFee), "Treasury transfer failed");
            }

            // Split 90% equally among all verified winners
            uint256 perWinnerPayout = netPayout / winners.length;
            for (uint256 i = 0; i < winners.length; i++) {
                require(usdgToken.transfer(winners[i], perWinnerPayout), "Winner transfer failed");
            }

            emit RoundSettled(roundId, tier, actualOutcome, winners.length, netPayout, protocolFee, 0);
        } else {
            // 100% Rollover to next round
            uint256 nextRoundId = roundId + 1;
            roundTiers[nextRoundId][tier].totalVault += vault;
            emit RoundSettled(roundId, tier, actualOutcome, 0, 0, 0, vault);
        }
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    function setOracleSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "Invalid address");
        oracleSigner = _signer;
    }

    function startNextRound() external onlyOwner {
        currentRoundId += 1;
    }
}
