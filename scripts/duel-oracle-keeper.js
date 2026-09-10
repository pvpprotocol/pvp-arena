// PvP Duel Automated Oracle Keeper & Settlement Engine
// Primary Oracle Source: Coinbase Exchange Official API
// Resolves 12h / 24h / 4h / 1h candle closes for on-chain user claims and settlements.

const https = require("https");
const NTFY_TOPIC = "pvp-arena-sol-duels-v1";
const NTFY_URL = "https://ntfy.sh/" + NTFY_TOPIC;
const TREASURY_WALLET = "4GwLwqjdqWXdNYKWYqqkniWX8vXPdTpa72QWxymtsaeV";

function fetchCoinbaseJson(url) {
  return new Promise((resolve, reject) => {
    https.get(url, {
      headers: {
        "User-Agent": "pvphub-Coinbase-Oracle/1.0",
        "Accept": "application/json"
      }
    }, res => {
      let data = "";
      res.on("data", chunk => data += chunk);
      res.on("end", () => {
        try {
          resolve(JSON.parse(data));
        } catch(e) {
          reject(new Error("Invalid JSON response from Coinbase: " + e.message));
        }
      });
    }).on("error", reject);
  });
}

// Fetch official candle from Coinbase Exchange API
// Returns [time, low, high, open, close, volume]
async function getCoinbaseCandleOutcome(pair = "BTC-USD", granularity = 86400) {
  const url = "https://api.exchange.coinbase.com/products/" + pair + "/candles?granularity=" + granularity;
  const candles = await fetchCoinbaseJson(url);
  if (!Array.isArray(candles) || candles.length === 0) {
    throw new Error("Failed to fetch candles for " + pair + " from Coinbase");
  }
  const latestCandle = candles[0];
  const openPrice = parseFloat(latestCandle[3]);
  const closePrice = parseFloat(latestCandle[4]);
  const isGreen = closePrice >= openPrice;
  return {
    pair,
    open: openPrice,
    close: closePrice,
    isGreen,
    outcome: isGreen ? "YES" : "NO",
    timestamp: latestCandle[0]
  };
}

const QUESTION_RESOLVERS = {
  1: async () => {
    const res = await getCoinbaseCandleOutcome("BTC-USD", 86400);
    console.log("[Coinbase Oracle] BTC-USD 24h Candle -> Open: $" + res.open + ", Close: $" + res.close + " => Outcome: " + res.outcome);
    return res.outcome;
  },
  2: async () => {
    const res = await getCoinbaseCandleOutcome("SOL-USD", 86400);
    console.log("[Coinbase Oracle] SOL-USD 24h Candle -> Open: $" + res.open + ", Close: $" + res.close + " => Outcome: " + res.outcome);
    return res.outcome;
  },
  3: async () => {
    const res = await getCoinbaseCandleOutcome("ETH-USD", 86400);
    console.log("[Coinbase Oracle] ETH-USD 24h Candle -> Open: $" + res.open + ", Close: $" + res.close + " => Outcome: " + res.outcome);
    return res.outcome;
  }
};

function broadcastToNtfy(duel) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(duel);
    const req = https.request({
      hostname: "ntfy.sh",
      path: "/" + NTFY_TOPIC,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload)
      }
    }, res => {
      let b = "";
      res.on("data", c => b += c);
      res.on("end", () => resolve(b));
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

async function main() {
  console.log("=== pvphub Automated Coinbase Oracle Started ===");
  console.log("Timestamp:", new Date().toISOString());
  console.log("Protocol Treasury Recipient:", TREASURY_WALLET);

  let rawMessages = "";
  try {
    rawMessages = await new Promise((resolve, reject) => {
      https.get(NTFY_URL + "/json?poll=1", res => {
        let b = "";
        res.on("data", c => b += c);
        res.on("end", () => resolve(b));
      }).on("error", reject);
    });
  } catch(e) {
    console.error("Relay connection error:", e.message);
    return;
  }

  const lines = rawMessages.trim().split("\n");
  const duelsMap = {};

  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const parsed = JSON.parse(line);
      if (parsed.event === "message" && parsed.message) {
        const d = JSON.parse(parsed.message);
        if (d && d.id) duelsMap[d.id] = d;
      }
    } catch(e) {}
  }

  const allDuels = Object.values(duelsMap);
  console.log("Found " + allDuels.length + " total duels in relay.");

  const now = Date.now();
  let resolvedCount = 0;

  for (const duel of allDuels) {
    if (duel.status !== "in_progress") continue;

    if (now >= duel.deadline) {
      console.log(">> Settlement time reached for Duel " + duel.id + " (Question " + duel.questionId + ")");
      const resolver = QUESTION_RESOLVERS[duel.questionId] || (async () => {
        return (await getCoinbaseCandleOutcome("BTC-USD", 86400)).outcome;
      });

      const winningOption = await resolver();
      console.log(">> Coinbase Outcome verified: " + winningOption);

      let winner = "";
      let loser = "";
      if (duel.creatorOption === winningOption) {
        winner = duel.creator;
        loser = duel.opponent;
      } else {
        winner = duel.opponent;
        loser = duel.creator;
      }

      duel.status = "completed";
      duel.winner = winner;
      duel.loser = loser;
      duel.winningOption = winningOption;
      duel.resolvedAt = Date.now();
      duel.canClaimPrize = true;
      duel.canClaimCashback = true;

      console.log(">> Winner: " + winner + " (Eligible for 90% prize)");
      console.log(">> Loser: " + loser + " (Eligible for 3% cashback)");
      console.log(">> Settle claim will disburse 5% referral & 2% protocol fee to " + TREASURY_WALLET);

      await broadcastToNtfy(duel);
      resolvedCount++;
    }
  }
  console.log("=== Coinbase Keeper Completed. Resolved " + resolvedCount + " duels ready for user claim. ===");
}

main().catch(err => {
  console.error("Fatal error:", err);
  process.exit(1);
});
