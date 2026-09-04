// PvP 2048 Tournament Anti-Cheat Verifier & On-chain Keeper
// Validates game session move logs, speed heuristics, and generates EIP-712 score proofs
// for on-chain tournament contract verification on Robinhood Chain.

const https = require("https");
const http = require("http");
const { ethers } = require("ethers");

const RPC_URL = process.env.ROBINHOOD_RPC || "https://rpc.mainnet.chain.robinhood.com";
const TOURNAMENT_CONTRACT_ADDRESS = process.env.TOURNAMENT_2048_CONTRACT || "0xddef71f4e631a73476ebd9efa7770d810d51e8a8";
const VERIFIER_PRIVATE_KEY = process.env.VERIFIER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY || "0x9487920a3a268a7a4a28c4f8ec247d52f7e96b1e000000000000000000000000";

const CHAIN_ID = 4663;

const TOURNAMENT_ABI = [
  "function getCurrentCycleId() view returns (uint256)",
  "function getCycleEndTimestamp(uint256 cycleId) view returns (uint256)",
  "function leaders(uint256 cycleId, uint16 tier) view returns (address winner, uint256 score, uint256 movesCount, bytes32 boardHash, uint256 timestamp, bool claimed)",
  "function submitVerifiedScore(uint16 tier, uint256 cycleId, uint256 score, uint256 movesCount, bytes32 boardHash, uint256 deadline, bytes32 nonce, bytes signature) external",
  "function claimPrize(uint256 cycleId, uint16 tier, address token) external"
];

/**
 * Validates moves log for anti-cheat:
 * 1. Reaction speed check (reject impossible <40ms human reaction spam).
 * 2. Mathematical score-to-move ratio.
 */
function validateMoveLog(score, moves) {
  if (!moves || !Array.isArray(moves) || moves.length === 0) {
    if (score > 100) return { valid: false, reason: "Missing move telemetry" };
    return { valid: true };
  }

  // Speed heuristic
  let superFastCount = 0;
  for (let i = 1; i < moves.length; i++) {
    const delta = moves[i].time - moves[i - 1].time;
    if (delta < 35) {
      superFastCount++;
    }
  }
  if (superFastCount > 5) {
    return { valid: false, reason: "Automated bot reaction detected" };
  }

  // Minimum moves heuristic: in 2048, score of 1000 requires at least ~30 moves
  const minMoves = Math.floor(score / 35);
  if (moves.length < minMoves && score > 500) {
    return { valid: false, reason: "Mathematical score-to-moves ratio mismatch" };
  }

  return { valid: true };
}

/**
 * Signs EIP-712 ScoreProof for on-chain contract submission
 */
async function generateScoreProof(player, tier, cycleId, score, movesCount, boardHash) {
  const signer = new ethers.Wallet(VERIFIER_PRIVATE_KEY);
  const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour validity
  const nonce = ethers.utils.hexlify(ethers.utils.randomBytes(32));

  const domain = {
    name: "PvP2048Tournament",
    version: "1",
    chainId: CHAIN_ID,
    verifyingContract: TOURNAMENT_CONTRACT_ADDRESS
  };

  const types = {
    ScoreProof: [
      { name: "player", type: "address" },
      { name: "tier", type: "uint16" },
      { name: "cycleId", type: "uint256" },
      { name: "score", type: "uint256" },
      { name: "movesCount", type: "uint256" },
      { name: "boardHash", type: "bytes32" },
      { name: "deadline", type: "uint256" },
      { name: "nonce", type: "bytes32" }
    ]
  };

  const value = {
    player: ethers.utils.getAddress(player),
    tier: parseInt(tier),
    cycleId: parseInt(cycleId),
    score: parseInt(score),
    movesCount: parseInt(movesCount),
    boardHash: boardHash || ethers.constants.HashZero,
    deadline: deadline,
    nonce: nonce
  };

  const signature = await signer._signTypedData(domain, types, value);

  return {
    tier: parseInt(tier),
    cycleId: parseInt(cycleId),
    score: parseInt(score),
    movesCount: parseInt(movesCount),
    boardHash: value.boardHash,
    deadline: deadline,
    nonce: nonce,
    signature: signature
  };
}

module.exports = {
  validateMoveLog,
  generateScoreProof,
  TOURNAMENT_CONTRACT_ADDRESS,
  CHAIN_ID
};
