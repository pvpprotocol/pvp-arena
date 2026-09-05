# PvP Arena Whitepaper

## P2P Prediction
Risk to Reward Analysis: In traditional betting models, participants face an unfavorable risk to reward ratio (for example at 1.3x odds, a player risks 100% of capital for only 30% profit, while the loser forfeits 100%). In PVP Arena, the winner earns 90% net profit directly, and the runner up receives 3% rebate cashback to preserve liquidity and enable immediate re-entry.

Two participants lock equal collateral into the canonical escrow smart contract. Upon verified outcome resolution, funds are automatically distributed as follows:

• 90% allocated directly to the verified winner
• 3% rebate cashback returned to the runner up wallet
• 7% protocol treasury fee for buybacks and rewards

### Core Rules / قوانین رسمی دوئل‌ها
1. Once an opponent joins and the duel is matched, the contest remains active until the official resolution is finalized, and immediately upon outcome confirmation, it transitions to the completed state for prize settlement.

2. Once an opponent enters and the competition officially begins, unilateral cancellation or withdrawal is strictly prohibited, and locked assets remain secured within the smart contract until the official result is recorded.

3. Upon expiration of the designated entry deadline, any request that has not been matched with an opponent automatically expires, and 100% of the deposited stake is refunded to the creator with zero platform fees.

4. Prior to an opponent joining the contest, the creator may voluntarily cancel their request at any time and reclaim their full deposit without fee deduction or penalty.

5. In the event of a tie outcome or if none of the designated criteria are met, the contest concludes with no winner, and the original deposits of both participants are fully refunded without fee deductions.

6. In the event of delay, outage, or unavailability of oracle reference data at the scheduled time, a 6-hour resolution grace period is initiated; if no verified data is obtained upon completion of this 6-hour window, the contest undergoes an emergency cancellation and all funds are refunded to both participants.
