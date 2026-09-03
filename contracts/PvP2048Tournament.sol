// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PvP2048Tournament
 * @notice On-chain Anti-Cheat Tournament Engine for 2048 Skill Games
 * @dev Validates high scores using cryptographic EIP-712 signatures derived from verified move logs.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PvP2048Tournament {
    address public owner;
    address public protocolVerifier;
    address public treasury;

    uint256 public constant CYCLE_DURATION = 36000; // 10 Hours in seconds
    uint256 public tournamentStartTime;

    struct LeaderRecord {
        address winner;
        uint256 score;
        uint256 movesCount;
        bytes32 boardHash;
        uint256 timestamp;
        bool claimed;
    }

    // cycleId => tier (1, 5, 10, 100, 1000) => LeaderRecord
    mapping(uint256 => mapping(uint16 => LeaderRecord)) public leaders;

    // cycleId => tier => pool balance (in native wei)
    mapping(uint256 => mapping(uint16 => uint256)) public nativePools;

    // cycleId => tier => token => pool balance
    mapping(uint256 => mapping(uint16 => mapping(address => uint256))) public tokenPools;

    // player => tier => all-time personal best
    mapping(address => mapping(uint16 => uint256)) public personalBests;

    // Nonces to prevent signature replay attacks
    mapping(bytes32 => bool) public usedProofHashes;

    // EIP-712 Domain Separator components
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant SCORE_PROOF_TYPEHASH = keccak256(
        "ScoreProof(address player,uint16 tier,uint256 cycleId,uint256 score,uint256 movesCount,bytes32 boardHash,uint256 deadline,bytes32 nonce)"
    );

    event TicketBought(address indexed player, uint16 indexed tier, uint256 quantity, uint256 amount);
    event ScoreSubmitted(
        address indexed player,
        uint16 indexed tier,
        uint256 indexed cycleId,
        uint256 score,
        uint256 movesCount,
        bool isNewLeader
    );
    event PrizeClaimed(
        address indexed winner,
        uint16 indexed tier,
        uint256 indexed cycleId,
        uint256 prizeAmount,
        uint256 treasuryFee
    );
    event VerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _protocolVerifier, address _treasury, uint256 _startTime) {
        owner = msg.sender;
        protocolVerifier = _protocolVerifier;
        treasury = _treasury;
        tournamentStartTime = _startTime > 0 ? _startTime : block.timestamp;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PvP2048Tournament")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function getCurrentCycleId() public view returns (uint256) {
        if (block.timestamp < tournamentStartTime) return 0;
        return (block.timestamp - tournamentStartTime) / CYCLE_DURATION;
    }

    function getCycleEndTimestamp(uint256 cycleId) public view returns (uint256) {
        return tournamentStartTime + ((cycleId + 1) * CYCLE_DURATION);
    }

    /**
     * @notice Purchase tickets on-chain using native ETH
     */
    function buyTicketNative(uint16 tier, uint256 quantity) external payable {
        require(tier == 1 || tier == 5 || tier == 10 || tier == 100 || tier == 1000, "Invalid tier");
        require(quantity > 0, "Zero quantity");
        require(msg.value > 0, "Zero payment");

        uint256 cycleId = getCurrentCycleId();
        nativePools[cycleId][tier] += msg.value;

        emit TicketBought(msg.sender, tier, quantity, msg.value);
    }

    /**
     * @notice Purchase tickets on-chain using ERC20 tokens (USDG or PVP)
     */
    function buyTicketToken(address token, uint16 tier, uint256 quantity, uint256 amount) external {
        require(tier == 1 || tier == 5 || tier == 10 || tier == 100 || tier == 1000, "Invalid tier");
        require(quantity > 0, "Zero quantity");
        require(amount > 0, "Zero amount");
        require(token != address(0), "Zero token address");

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(success, "Token transfer failed");

        uint256 cycleId = getCurrentCycleId();
        tokenPools[cycleId][tier][token] += amount;

        emit TicketBought(msg.sender, tier, quantity, amount);
    }

    /**
     * @notice Submits an anti-cheat verified 2048 high score backed by EIP-712 proof
     */
    function submitVerifiedScore(
        uint16 tier,
        uint256 cycleId,
        uint256 score,
        uint256 movesCount,
        bytes32 boardHash,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "Proof expired");
        require(block.timestamp <= getCycleEndTimestamp(cycleId), "Cycle already ended");
        require(!usedProofHashes[nonce], "Proof already used");
        require(score > 0, "Invalid score");

        // Verify EIP-712 cryptographic signature
        bytes32 structHash = keccak256(
            abi.encode(
                SCORE_PROOF_TYPEHASH,
                msg.sender,
                tier,
                cycleId,
                score,
                movesCount,
                boardHash,
                deadline,
                nonce
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recoveredSigner = recoverSigner(digest, signature);
        require(recoveredSigner == protocolVerifier, "Invalid anti-cheat signature");

        usedProofHashes[nonce] = true;

        // Update personal best
        if (score > personalBests[msg.sender][tier]) {
            personalBests[msg.sender][tier] = score;
        }

        // Check if this sets a new tier leader
        bool isNewLeader = false;
        LeaderRecord storage currentLeader = leaders[cycleId][tier];
        if (score > currentLeader.score) {
            currentLeader.winner = msg.sender;
            currentLeader.score = score;
            currentLeader.movesCount = movesCount;
            currentLeader.boardHash = boardHash;
            currentLeader.timestamp = block.timestamp;
            isNewLeader = true;
        }

        emit ScoreSubmitted(msg.sender, tier, cycleId, score, movesCount, isNewLeader);
    }

    /**
     * @notice Claim 80% net prize pool for the verified #1 leader after 10-hour cycle finishes
     */
    function claimPrize(uint256 cycleId, uint16 tier, address token) external {
        require(block.timestamp > getCycleEndTimestamp(cycleId), "Cycle still active");
        LeaderRecord storage record = leaders[cycleId][tier];
        require(msg.sender == record.winner, "Only verified #1 winner can claim");
        require(!record.claimed, "Prize already claimed");

        record.claimed = true;

        if (token == address(0)) {
            // Native ETH pool payout
            uint256 total = nativePools[cycleId][tier];
            require(total > 0, "Empty native pool");
            nativePools[cycleId][tier] = 0;

            uint256 protocolFee = (total * 20) / 100;
            uint256 winnerPrize = total - protocolFee;

            if (protocolFee > 0) {
                (bool feeSent, ) = payable(treasury).call{value: protocolFee}("");
                require(feeSent, "Treasury fee failed");
            }

            (bool prizeSent, ) = payable(msg.sender).call{value: winnerPrize}("");
            require(prizeSent, "Winner prize failed");

            emit PrizeClaimed(msg.sender, tier, cycleId, winnerPrize, protocolFee);
        } else {
            // ERC20 pool payout
            uint256 total = tokenPools[cycleId][tier][token];
            require(total > 0, "Empty token pool");
            tokenPools[cycleId][tier][token] = 0;

            uint256 protocolFee = (total * 20) / 100;
            uint256 winnerPrize = total - protocolFee;

            if (protocolFee > 0) {
                bool feeSuccess = IERC20(token).transfer(treasury, protocolFee);
                require(feeSuccess, "Treasury token fee failed");
            }

            bool prizeSuccess = IERC20(token).transfer(msg.sender, winnerPrize);
            require(prizeSuccess, "Winner token prize failed");

            emit PrizeClaimed(msg.sender, tier, cycleId, winnerPrize, protocolFee);
        }
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

    function setVerifier(address _newVerifier) external onlyOwner {
        require(_newVerifier != address(0), "Zero address");
        emit VerifierUpdated(protocolVerifier, _newVerifier);
        protocolVerifier = _newVerifier;
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Zero address");
        emit TreasuryUpdated(treasury, _newTreasury);
        treasury = _newTreasury;
    }
}
