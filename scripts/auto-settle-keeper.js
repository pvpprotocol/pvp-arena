// Automated Oracle & Settlement Keeper for PvP Arena (Robinhood Chain)
// Automatically evaluates market resolutions (e.g. Coinbase Daily BTC Candle)
// and executes on-chain settlement on QuestionRegistry and PvP duels.

const { ethers } = require("ethers");

const RPC_URL = process.env.ROBINHOOD_RPC || "https://rpc.mainnet.chain.robinhood.com";
const REGISTRY_ADDRESS = process.env.QUESTION_REGISTRY_ADDRESS || "0x5544caed6f15e8bb9b795a59ed0d7da4f7a9a806";
const PRIVATE_KEY = process.env.ORACLE_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
const NTFY_TOPIC = process.env.NTFY_TOPIC || "pvp-arena-rh-duels-v3";

const REGISTRY_ABI = [
  "function questionCount() view returns (uint256)",
  "function getQuestion(uint256 id) view returns (tuple(uint256 id, string title, string category, string resolutionSource, uint256 entryDeadline, uint256 settlementTime, bool isDynamicSettlement, uint256[] allowedTiers, bool isClosed, bool isSettled, uint8 winningOutcome, uint256 settledAt))",
  "function settleQuestion(uint256 qId, uint8 winningOutcome) external"
];

async function fetchCoinbaseBtcDailyCandle(settlementTimestamp) {
  const url = "https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=86400";
  const res = await fetch(url, { headers: { "User-Agent": "PvP-Oracle-Keeper" } });
  if (!res.ok) throw new Error("Coinbase API HTTP " + res.status);
  const candles = await res.json();
  if (!Array.isArray(candles) || candles.length === 0) throw new Error("Invalid candles format");

  // Coinbase candles: [ timestamp, low, high, open, close, volume ]
  // Match candle closest to the settlement date
  let matched = candles[0];
  for (const c of candles) {
    if (c[0] <= settlementTimestamp) {
      matched = c;
      break;
    }
  }

  const open = matched[3];
  const close = matched[4];
  const candleTime = new Date(matched[0] * 1000).toISOString();
  console.log("Matched Candle:", candleTime, "Open:", open, "Close:", close);

  // 1: GREEN / YES (close >= open), 2: RED / NO (close < open)
  return close >= open ? 1 : 2;
}

async function runOracleSettlement() {
  console.log("=== Starting Automated Settlement Keeper ===");
  console.log("Current UTC Time:", new Date().toISOString());

  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const block = await provider.getBlock("latest");
  const currentBlockTime = block.timestamp;
  console.log("Latest Robinhood Block:", block.number, "Timestamp:", currentBlockTime);

  let signer;
  if (PRIVATE_KEY) {
    signer = new ethers.Wallet(PRIVATE_KEY, provider);
    console.log("Signer Address:", signer.address);
  } else {
    console.log("No private key configured (read-only simulation mode)");
  }

  const contract = new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, signer || provider);
  const total = (await contract.questionCount()).toNumber();
  console.log("Total Registered Questions:", total);

  for (let id = 1; id <= total; id++) {
    const q = await contract.getQuestion(id);
    console.log("\n--- Checking Question #" + id + " --- " + q.title);
    console.log("Settlement Time:", new Date(q.settlementTime.toNumber() * 1000).toISOString());
    console.log("Status:", q.isSettled ? "Already Settled (Outcome: " + q.winningOutcome + ")" : "Pending Settlement");

    if (q.isSettled) continue;

    if (currentBlockTime >= q.settlementTime.toNumber()) {
      console.log(">> Settlement time reached for Question #" + id + ". Evaluating outcome...");
      let outcome = 0;

      if (q.resolutionSource.toLowerCase().includes("coinbase")) {
        outcome = await fetchCoinbaseBtcDailyCandle(q.settlementTime.toNumber());
      } else {
        console.warn("Unknown resolution source:", q.resolutionSource);
        continue;
      }

      const outcomeName = outcome === 1 ? "YES / GREEN" : "NO / RED";
      console.log(">> Determined Winning Outcome: " + outcome + " (" + outcomeName + ")");

      if (signer) {
        console.log("Sending on-chain settleQuestion(" + id + ", " + outcome + ") transaction...");
        const tx = await contract.settleQuestion(id, outcome);
        console.log("Tx Submitted! Hash:", tx.hash);
        const receipt = await tx.wait();
        console.log("Tx Confirmed in Block:", receipt.blockNumber);

        // Notify relay
        await fetch("https://ntfy.sh/" + NTFY_TOPIC, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            event: "question_settled",
            questionId: id,
            winningOutcome: outcome,
            outcomeName,
            settledAt: Date.now(),
            txHash: tx.hash
          })
        });
        console.log("Broadcasted settlement notification to relay.");
      } else {
        console.log("[DRY-RUN] Question #" + id + " would be settled with outcome: " + outcomeName);
      }
    } else {
      const remainingSec = q.settlementTime.toNumber() - currentBlockTime;
      console.log("Settlement not yet due. Remaining: " + Math.floor(remainingSec / 3600) + "h " + Math.floor((remainingSec % 3600) / 60) + "m " + (remainingSec % 60) + "s");
    }
  }

  console.log("\n=== Oracle Keeper Finished ===");
}

if (require.main === module) {
  runOracleSettlement().catch(err => {
    console.error("Keeper Error:", err);
    process.exit(1);
  });
}

module.exports = { runOracleSettlement, fetchCoinbaseBtcDailyCandle };
