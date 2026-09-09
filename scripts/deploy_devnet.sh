#!/usr/bin/env bash
set -e

echo "=== Deploying Anchor Programs to Solana Devnet ==="

PVP_PROGRAM_ID="HTyMSTjFFVnkDHeqqK87aPvDZ4pTat8pu9CFpor7bf39"
JACKPOT_PROGRAM_ID="BXjFmivvTKHRm7J6Fnv7HmbsghAodCH2oaiRGJtDhohA"

echo "PVP Duels Program ID: $PVP_PROGRAM_ID"
echo "Grand Jackpot Program ID: $JACKPOT_PROGRAM_ID"

# 1. Ensure Solana CLI is set to Devnet
solana config set --url https://api.devnet.solana.com

# 2. Check balance and airdrop if needed
BALANCE=$(solana balance | awk "{print $1}")
echo "Current Deployer Balance: $BALANCE SOL"

# 3. Build programs with Anchor
echo "Building Anchor programs..."
anchor build

# 4. Deploy to Solana Devnet
echo "Deploying pvp_duels..."
solana program deploy target/deploy/pvp_duels.so --program-id $PVP_PROGRAM_ID || solana program deploy target/deploy/pvp_duels.so

echo "Deploying grand_jackpot..."
solana program deploy target/deploy/grand_jackpot.so --program-id $JACKPOT_PROGRAM_ID || solana program deploy target/deploy/grand_jackpot.so

echo "=== Deployment to Solana Devnet Complete! ==="
