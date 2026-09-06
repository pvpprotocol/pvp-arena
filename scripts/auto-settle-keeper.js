// Automated Oracle & Settlement Keeper for PvP Arena (Robinhood Chain)
// Evaluates Coinbase BTC-USD daily candle close and executes on-chain settlement on QuestionRegistry.

const ethers = require("ethers");

const RPC_URL = process.env.ROBINHOOD_RPC || "https://rpc.mainnet.chain.robinhood.com";
const REGISTRY_ADDRESS = process.env.QUESTION_REGISTRY_ADDRESS || "0xfd0266e7c27a96b7cffa00d1c3cae08e03e9c3f5";
const PRIVATE_KEY = process.env.ORACLE_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
const NTFY_TOPIC = process.env.NTFY_TOPIC || "pvp-arena-rh-duels-v3";

const REGISTRY_ABI = [
  "function nextQuestionId() view returns (uint256)",
  "function getQuestion(uint256 id) view returns (tuple(uint256 id, string title, string category, string resolutionSource, uint256 entryDeadline, uint256 settlementTime, bool isDynamicSettlement, uint256[] allowedTiers, bool isClosed, bool isSettled, uint8 winningOutcome, uint256 settledAt))",
  "function settleQuestion(uint256 qId, uint8 winningOutcome) external"
];

function getProvider(url) {
  if (ethers.JsonRpcProvider) {
    return new ethers.JsonRpcProvider(url);
  } else if (ethers.providers && ethers.providers.JsonRpcProvider) {
    return new ethers.providers.JsonRpcProvider(url);
  }
  throw new Error("ethers JsonRpcProvider not found");
}

async function fetchCoinbaseBtcDailyCandle(settlementTimestamp) {
  const url = "https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity=86400";
  const res = await fetch(url, { headers: { "User-Agent": "PvP-Oracle-Keeper" } });
  if (!res.ok) throw new Error("Coinbase API HTTP " + res.status);
  const candles = await res.json();
  if (!Array.isArray(candles) || candles.length === 0) throw new Error("Invalid candles format");

  // Coinbase candles: [ timestamp, low, high, open, close, volume ]
  let matched = candles[0];
  for (const c of candles) {
    if (c[0] <= settlementTimestamp) {
      matched = c;
      break;
    }
  }

  const open = parseFloat(matched[3]);
  const close = parseFloat(matched[4]);
  const candleTime = new Date(matched[0] * 1000).toISOString();
  console.log("Matched Coinbase Candle:", candleTime, "Open:", open, "Close:", close);

  // 1: GREEN / YES (close >= open), 2: RED / NO (close < open)
  return close >= open ? 1 : 2;
}

async function runOracleSettlement() {
  console.log("=== Starting Automated Settlement Keeper ===");
  console.log("Current UTC Time:", new Date().toISOString());

  const provider = getProvider(RPC_URL);
  const block = await provider.getBlock("latest");
  const currentBlockTime = block.timestamp;
  console.log("Latest Robinhood Block:", block.number, "Timestamp:", currentBlockTime);

  let signer;
  if (PRIVATE_KEY) {
    signer = new ethers.Wallet(PRIVATE_KEY, provider);
    console.log("Signer Address:", signer.address);
  } else {
    console.log("No private key configured (read-only monitoring & dry-run mode)");
  }

  const contract = new ethers.Contract(REGISTRY_ADDRESS, REGISTRY_ABI, signer || provider);
  const nextId = await contract.nextQuestionId();
  const total = Number(nextId) - 1;
  console.log("Total Registered Questions:", total);

  for (let id = 1; id <= total; id++) {
    const q = await contract.getQuestion(id);
    const qSettlementTime = Number(q.settlementTime);
    console.log("\n--- Checking Question #" + id + " --- " + q.title);
    console.log("Resolution Source:", q.resolutionSource);
    console.log("Settlement Time:", new Date(qSettlementTime * 1000).toISOString());
    console.log("Status:", q.isSettled ? "Already Settled (Outcome: " + q.winningOutcome + ")" : "Pending Settlement");

    if (q.isSettled) continue;

    if (currentBlockTime >= qSettlementTime) {
      console.log(">> Settlement time reached for Question #" + id + ". Evaluating outcome...");
      let outcome = 0;

      if (q.resolutionSource.toLowerCase().includes("coinbase")) {
        outcome = await fetchCoinbaseBtcDailyCandle(qSettlementTime);
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
        try {
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
        } catch (e) {
          console.warn("Failed to broadcast to relay:", e.message);
        }
      } else {
        console.log("[DRY-RUN] Question #" + id + " would be settled with outcome: " + outcomeName);
      }
    } else {
      const remainingSec = qSettlementTime - currentBlockTime;
      const hours = Math.floor(remainingSec / 3600);
      const mins = Math.floor((remainingSec % 3600) / 60);
      const secs = remainingSec % 60;
      console.log("Settlement not yet due. Remaining: " + hours + "h " + mins + "m " + secs + "s");
    }
  }

  console.log("\n=== Oracle Keeper Finished Successfully ===");
}

if (require.main === module) {
  runOracleSettlement().catch(err => {
    console.error("Keeper Error:", err);
    process.exit(1);
  });
}

module.exports = { runOracleSettlement, fetchCoinbaseBtcDailyCandle };
