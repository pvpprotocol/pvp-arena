// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PvPBinaryDuel
 * @notice P2P Binary Prediction Duels (YES/NO) with Cryptographic Oracle Settlement
 * @dev Settles binary duels via EIP-712 oracle proofs with 90% winner, 3% cashback, 7% treasury.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PvPBinaryDuel {
    address public owner;
    address public oracleVerifier;
    address public treasury;

    uint256 public nextDuelId = 1;

    enum DuelStatus {
        WAITING_FOR_CHALLENGER, // Created, waiting for opponent
        ACTIVE,                 // Opponent matched, locked
        SETTLED,                // Resolved with oracle proof, paid out
        CANCELLED               // Cancelled by creator or refunded
    }

    enum Outcome {
        UNRESOLVED, // 0
        YES,        // 1
        NO          // 2
    }

    struct Duel {
        uint256 duelId;
        address creator;
        address challenger;
        address token;          // address(0) for native ETH, or ERC20 (USDG, PVP)
        uint256 wagerAmount;    // Stake required per player
        uint8 creatorChoice;    // 1 for YES, 2 for NO
        uint8 winningOutcome;   // 1 for YES, 2 for NO
        DuelStatus status;
        uint256 createdAt;
        uint256 expiresAt;
        string topic;
    }

    // duelId => Duel
    mapping(uint256 => Duel) public duels;

    // Nonces to prevent signature replay attacks
    mapping(bytes32 => bool) public usedProofNonces;

    // EIP-712 Domain Separator components
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant SETTLEMENT_TYPEHASH = keccak256(
        "DuelSettlementProof(uint256 duelId,uint8 winningOutcome,uint256 deadline,bytes32 nonce)"
    );

    event DuelCreated(
        uint256 indexed duelId,
        address indexed creator,
        address indexed token,
        uint256 wagerAmount,
        uint8 creatorChoice,
        uint256 expiresAt,
        string topic
    );

    event DuelAccepted(
        uint256 indexed duelId,
        address indexed challenger,
        uint8 challengerChoice
    );

    event DuelSettled(
        uint256 indexed duelId,
        address indexed winner,
        address indexed loser,
        uint8 winningOutcome,
        uint256 winnerPayout,
        uint256 cashbackAmount,
        uint256 treasuryFee
    );

    event DuelCancelled(uint256 indexed duelId, address indexed creator, uint256 refundAmount);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _oracleVerifier, address _treasury) {
        owner = msg.sender;
        oracleVerifier = _oracleVerifier;
        treasury = _treasury;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PvPBinaryDuel")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @notice Create a duel using native ETH (Robinhood Chain ETH)
     * @param creatorChoice 1 for YES, 2 for NO
     * @param durationInSeconds Duration until unaccepted duel expires
     * @param topic Description / Question of the duel
     */
    function createDuelNative(
        uint8 creatorChoice,
        uint256 durationInSeconds,
        string calldata topic
    ) external payable returns (uint256 duelId) {
        require(msg.value > 0, "Zero wager");
        require(creatorChoice == 1 || creatorChoice == 2, "Choice must be 1 (YES) or 2 (NO)");
        require(durationInSeconds >= 60, "Duration too short");

        duelId = nextDuelId++;
        uint256 expiresAt = block.timestamp + durationInSeconds;

        duels[duelId] = Duel({
            duelId: duelId,
            creator: msg.sender,
            challenger: address(0),
            token: address(0),
            wagerAmount: msg.value,
            creatorChoice: creatorChoice,
            winningOutcome: 0,
            status: DuelStatus.WAITING_FOR_CHALLENGER,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            topic: topic
        });

        emit DuelCreated(duelId, msg.sender, address(0), msg.value, creatorChoice, expiresAt, topic);
    }

    /**
     * @notice Create a duel using ERC20 tokens (e.g. USDG or PVP)
     */
    function createDuelToken(
        address token,
        uint256 wagerAmount,
        uint8 creatorChoice,
        uint256 durationInSeconds,
        string calldata topic
    ) external returns (uint256 duelId) {
        require(token != address(0), "Zero token address");
        require(wagerAmount > 0, "Zero wager");
        require(creatorChoice == 1 || creatorChoice == 2, "Choice must be 1 (YES) or 2 (NO)");
        require(durationInSeconds >= 60, "Duration too short");

        bool success = IERC20(token).transferFrom(msg.sender, address(this), wagerAmount);
        require(success, "Token deposit failed");

        duelId = nextDuelId++;
        uint256 expiresAt = block.timestamp + durationInSeconds;

        duels[duelId] = Duel({
            duelId: duelId,
            creator: msg.sender,
            challenger: address(0),
            token: token,
            wagerAmount: wagerAmount,
            creatorChoice: creatorChoice,
            winningOutcome: 0,
            status: DuelStatus.WAITING_FOR_CHALLENGER,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            topic: topic
        });

        emit DuelCreated(duelId, msg.sender, token, wagerAmount, creatorChoice, expiresAt, topic);
    }

    /**
     * @notice Accept an existing waiting duel with native ETH
     * @dev Automatically assigns the opposite choice to the challenger
     */
    function acceptDuelNative(uint256 duelId) external payable {
        Duel storage d = duels[duelId];
        require(d.status == DuelStatus.WAITING_FOR_CHALLENGER, "Duel not waiting");
        require(block.timestamp <= d.expiresAt, "Duel expired");
        require(d.token == address(0), "Token mismatch, requires native ETH");
        require(msg.value == d.wagerAmount, "Incorrect wager amount");
        require(msg.sender != d.creator, "Cannot challenge yourself");

        d.challenger = msg.sender;
        d.status = DuelStatus.ACTIVE;

        uint8 challengerChoice = d.creatorChoice == 1 ? 2 : 1;
        emit DuelAccepted(duelId, msg.sender, challengerChoice);
    }

    /**
     * @notice Accept an existing waiting duel with ERC20 tokens
     */
    function acceptDuelToken(uint256 duelId) external {
        Duel storage d = duels[duelId];
        require(d.status == DuelStatus.WAITING_FOR_CHALLENGER, "Duel not waiting");
        require(block.timestamp <= d.expiresAt, "Duel expired");
        require(d.token != address(0), "Native duel, requires ETH");
        require(msg.sender != d.creator, "Cannot challenge yourself");

        bool success = IERC20(d.token).transferFrom(msg.sender, address(this), d.wagerAmount);
        require(success, "Token deposit failed");

        d.challenger = msg.sender;
        d.status = DuelStatus.ACTIVE;

        uint8 challengerChoice = d.creatorChoice == 1 ? 2 : 1;
        emit DuelAccepted(duelId, msg.sender, challengerChoice);
    }

    /**
     * @notice Settle an active duel using cryptographic EIP-712 proof from the oracle
     * @param duelId ID of the duel
     * @param winningOutcome 1 for YES, 2 for NO
     * @param deadline Proof valid deadline
     * @param nonce Unique random nonce to prevent replay
     * @param signature Cryptographic signature by oracleVerifier
     */
    function settleDuelWithProof(
        uint256 duelId,
        uint8 winningOutcome,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        Duel storage d = duels[duelId];
        require(d.status == DuelStatus.ACTIVE, "Duel not active");
        require(winningOutcome == 1 || winningOutcome == 2, "Outcome must be 1 or 2");
        require(block.timestamp <= deadline, "Proof expired");
        require(!usedProofNonces[nonce], "Proof already used");

        // Verify EIP-712 signature from oracleVerifier
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLEMENT_TYPEHASH,
                duelId,
                winningOutcome,
                deadline,
                nonce
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recoveredSigner = recoverSigner(digest, signature);
        require(recoveredSigner == oracleVerifier, "Invalid oracle signature");

        usedProofNonces[nonce] = true;
        d.status = DuelStatus.SETTLED;
        d.winningOutcome = winningOutcome;

        address winner;
        address loser;

        if (d.creatorChoice == winningOutcome) {
            winner = d.creator;
            loser = d.challenger;
        } else {
            winner = d.challenger;
            loser = d.creator;
        }

        uint256 totalPool = d.wagerAmount * 2;
        // Tokenomics: 90% winner, 3% cashback to loser, 7% treasury
        uint256 winnerPayout = (totalPool * 90) / 100;
        uint256 cashbackAmount = (totalPool * 3) / 100;
        uint256 treasuryFee = totalPool - winnerPayout - cashbackAmount; // 7%

        if (d.token == address(0)) {
            // Payout in native ETH
            if (treasuryFee > 0 && treasury != address(0)) {
                (bool tfSent, ) = payable(treasury).call{value: treasuryFee}("");
                require(tfSent, "Treasury fee failed");
            }
            if (cashbackAmount > 0 && loser != address(0)) {
                (bool cbSent, ) = payable(loser).call{value: cashbackAmount}("");
                require(cbSent, "Cashback failed");
            }
            (bool wSent, ) = payable(winner).call{value: winnerPayout}("");
            require(wSent, "Winner payout failed");
        } else {
            // Payout in ERC20 token (USDG / PVP)
            if (treasuryFee > 0 && treasury != address(0)) {
                bool tfSuccess = IERC20(d.token).transfer(treasury, treasuryFee);
                require(tfSuccess, "Treasury token transfer failed");
            }
            if (cashbackAmount > 0 && loser != address(0)) {
                bool cbSuccess = IERC20(d.token).transfer(loser, cashbackAmount);
                require(cbSuccess, "Cashback token transfer failed");
            }
            bool wSuccess = IERC20(d.token).transfer(winner, winnerPayout);
            require(wSuccess, "Winner token transfer failed");
        }

        emit DuelSettled(duelId, winner, loser, winningOutcome, winnerPayout, cashbackAmount, treasuryFee);
    }

    /**
     * @notice Cancel duel if no challenger accepted and it expired (or creator cancels)
     */
    function cancelDuel(uint256 duelId) external {
        Duel storage d = duels[duelId];
        require(d.status == DuelStatus.WAITING_FOR_CHALLENGER, "Duel cannot be cancelled");
        require(msg.sender == d.creator || block.timestamp > d.expiresAt, "Only creator or after expiry");

        d.status = DuelStatus.CANCELLED;
        uint256 refund = d.wagerAmount;

        if (d.token == address(0)) {
            (bool sent, ) = payable(d.creator).call{value: refund}("");
            require(sent, "ETH refund failed");
        } else {
            bool success = IERC20(d.token).transfer(d.creator, refund);
            require(success, "Token refund failed");
        }

        emit DuelCancelled(duelId, d.creator, refund);
    }

    function recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "Malformed signature");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "Invalid v");
        return ecrecover(digest, v, r, s);
    }

    function setOracleVerifier(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "Zero address");
        emit OracleUpdated(oracleVerifier, _newOracle);
        oracleVerifier = _newOracle;
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Zero address");
        emit TreasuryUpdated(treasury, _newTreasury);
        treasury = _newTreasury;
    }
}
