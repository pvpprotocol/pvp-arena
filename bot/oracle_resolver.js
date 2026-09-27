/**
 * GIWA PvP Arena Oracle Resolver Bot
 * Periodically monitors and resolves settled 1v1 duels on GIWA Sepolia L2.
 */

const { ethers } = require("ethers");

// Configuration
const GIWA_RPC = process.env.GIWA_RPC || "https://sepolia-rpc.giwa.io";
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS || "0xB464f766028C1d4Face359592a2127272C2C7750";
const RESOLVER_PRIVATE_KEY = process.env.RESOLVER_PRIVATE_KEY;

if (!RESOLVER_PRIVATE_KEY) {
  console.error("ERROR: Set RESOLVER_PRIVATE_KEY in environment variables");
  process.exit(1);
}

const ABI = [
  "function nextDuelId() view returns (uint256)",
  "function duels(uint256) view returns (uint256 id, address creator, address joiner, address token, uint256 stakeAmount, uint8 creatorChoice, uint8 joinerChoice, uint256 entryDeadline, uint256 settlementTime, uint8 status, address winner)",
  "function resolveDuel(uint256 duelId, address winner) external"
];

const provider = new ethers.JsonRpcProvider(GIWA_RPC);
const wallet = new ethers.Wallet(RESOLVER_PRIVATE_KEY, provider);
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

async function checkAndResolve() {
  console.log();
  try {
    const nextId = await contract.nextDuelId();
    const now = Math.floor(Date.now() / 1000);

    for (let i = 1; i < Number(nextId); i++) {
      const d = await contract.duels(i);
      // Status 1 = Active (both matched), Status 0 = WaitingCreator
      if (d.status === 1) {
        if (Number(d.settlementTime) <= now) {
          console.log();
          // Query price or outcome source here
          // e.g., if creatorChoice was Bullish and price went up, creator is winner
          // For demo, resolving with creator or joiner based on oracle event:
          const targetWinner = d.creator; // replace with dynamic price feed resolution logic
          console.log();
          const tx = await contract.resolveDuel(i, targetWinner);
          console.log();
          await tx.wait();
          console.log();
        }
      }
    }
  } catch (err) {
    console.error("Error during resolve loop:", err.message);
  }
}

// Run loop every 15 seconds
setInterval(checkAndResolve, 15000);
checkAndResolve();
