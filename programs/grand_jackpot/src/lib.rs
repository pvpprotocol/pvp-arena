use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

declare_id!("GrndJckPt111111111111111111111111111111111");

pub const JACKPOT_WINNER_SHARE_BPS: u64 = 9000; // 90% to winner
pub const JACKPOT_FEE_BPS: u64 = 1000;          // 10% platform fee
pub const BPS_DENOMINATOR: u64 = 10000;

// 5 Standard Tiers in SPL-USDC (6 decimals)
pub const TIER_1_COST: u64 = 1_000_000;         // 1 USDC
pub const TIER_2_COST: u64 = 5_000_000;         // 5 USDC
pub const TIER_3_COST: u64 = 10_000_000;        // 10 USDC
pub const TIER_4_COST: u64 = 100_000_000;       // 100 USDC
pub const TIER_5_COST: u64 = 1_000_000_000;     // 1000 USDC

#[program]
pub mod grand_jackpot {
    use super::*;

    pub fn initialize_jackpot(
        ctx: Context<InitializeJackpot>,
        fee_recipient: Pubkey,
    ) -> Result<()> {
        let jackpot = &mut ctx.accounts.jackpot_config;
        jackpot.admin = ctx.accounts.admin.key();
        jackpot.fee_recipient = fee_recipient;
        jackpot.paused = false;
        jackpot.bump = ctx.bumps.jackpot_config;
        Ok(())
    }

    /// Admin opens a new Jackpot round for a specific tier
    pub fn open_round(
        ctx: Context<OpenRound>,
        question_id: u64,
        tier: u8,
        round_id: u64,
        entry_end_time: i64,
        settlement_time: i64,
    ) -> Result<()> {
        let config = &ctx.accounts.jackpot_config;
        require!(!config.paused, ErrorCode::JackpotPaused);
        require!(tier >= 1 && tier <= 5, ErrorCode::InvalidTier);
        require!(entry_end_time <= settlement_time, ErrorCode::InvalidTiming);

        let round = &mut ctx.accounts.round_account;
        round.question_id = question_id;
        round.tier = tier;
        round.round_id = round_id;
        round.entry_end_time = entry_end_time;
        round.settlement_time = settlement_time;
        round.tier_ticket_cost = get_tier_cost(tier)?;
        round.total_tickets = 0;
        round.total_pool_usdc = 0;
        round.is_settled = false;
        round.winning_prediction_hash = [0u8; 32];
        round.winners_count = 0;
        round.bump = ctx.bumps.round_account;
        round.vault_bump = ctx.bumps.vault_token_account;

        emit!(RoundOpenedEvent {
            question_id,
            tier,
            round_id,
            entry_end_time,
            settlement_time,
            ticket_cost: round.tier_ticket_cost,
        });

        Ok(())
    }

    /// User buys tickets predicting the exact outcome hash
    pub fn buy_tickets(
        ctx: Context<BuyTickets>,
        prediction_hash: [u8; 32],
        ticket_count: u32,
    ) -> Result<()> {
        let config = &ctx.accounts.jackpot_config;
        require!(!config.paused, ErrorCode::JackpotPaused);
        require!(ticket_count > 0, ErrorCode::InvalidTicketCount);

        let round = &mut ctx.accounts.round_account;
        require!(!round.is_settled, ErrorCode::RoundAlreadySettled);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp < round.entry_end_time, ErrorCode::EntryWindowLocked);

        let total_cost = round.tier_ticket_cost.checked_mul(ticket_count as u64).unwrap();

        // Transfer USDC into round vault PDA
        let cpi_accounts = Transfer {
            from: ctx.accounts.buyer_token_account.to_account_info(),
            to: ctx.accounts.vault_token_account.to_account_info(),
            authority: ctx.accounts.buyer.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(CpiContext::new(cpi_program, cpi_accounts), total_cost)?;

        round.total_tickets = round.total_tickets.checked_add(ticket_count as u64).unwrap();
        round.total_pool_usdc = round.total_pool_usdc.checked_add(total_cost).unwrap();

        let ticket = &mut ctx.accounts.ticket_account;
        ticket.round = round.key();
        ticket.buyer = ctx.accounts.buyer.key();
        ticket.prediction_hash = prediction_hash;
        ticket.ticket_count = ticket_count;
        ticket.claimed = false;
        ticket.bump = ctx.bumps.ticket_account;

        emit!(TicketPurchasedEvent {
            round: round.key(),
            buyer: ticket.buyer,
            ticket_count,
            total_cost,
            prediction_hash,
        });

        Ok(())
    }

    /// Admin / Oracle registers official outcome after event ends
    pub fn settle_round(
        ctx: Context<SettleRound>,
        winning_prediction_hash: [u8; 32],
        winners_count: u32,
    ) -> Result<()> {
        let round = &mut ctx.accounts.round_account;
        require!(!round.is_settled, ErrorCode::RoundAlreadySettled);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp >= round.settlement_time, ErrorCode::SettlementTimeNotReached);

        round.is_settled = true;
        round.winning_prediction_hash = winning_prediction_hash;
        round.winners_count = winners_count;

        let total_pool = round.total_pool_usdc;

        if winners_count > 0 {
            // 90% prize to winners, 10% fee to platform
            let fee_amount = total_pool.checked_mul(JACKPOT_FEE_BPS).unwrap().checked_div(BPS_DENOMINATOR).unwrap();
            let prize_pool = total_pool.checked_sub(fee_amount).unwrap();

            let tier_bytes = round.tier.to_le_bytes();
            let round_bytes = round.round_id.to_le_bytes();
            let signer_seeds: &[&[&[u8]]] = &[&[
                b"jackpot_vault",
                tier_bytes.as_ref(),
                round_bytes.as_ref(),
                &[round.vault_bump],
            ]];

            if fee_amount > 0 {
                let fee_cpi = Transfer {
                    from: ctx.accounts.vault_token_account.to_account_info(),
                    to: ctx.accounts.fee_recipient_token_account.to_account_info(),
                    authority: ctx.accounts.vault_token_account.to_account_info(),
                };
                token::transfer(
                    CpiContext::new_with_signer(
                        ctx.accounts.token_program.to_account_info(),
                        fee_cpi,
                        signer_seeds,
                    ),
                    fee_amount,
                )?;
            }

            emit!(RoundSettledEvent {
                round: round.key(),
                winning_prediction_hash,
                winners_count,
                prize_pool_usdc: prize_pool,
                rollover: false,
            });
        } else {
            // Rollover: 100% remains in the vault to be transferred to next round
            emit!(RoundSettledEvent {
                round: round.key(),
                winning_prediction_hash,
                winners_count: 0,
                prize_pool_usdc: 0,
                rollover: true,
            });
        }

        Ok(())
    }

    /// Winner claims their proportional share of the 90% prize pool
    pub fn claim_prize(ctx: Context<ClaimPrize>) -> Result<()> {
        let round = &ctx.accounts.round_account;
        require!(round.is_settled, ErrorCode::RoundNotSettled);
        require!(round.winners_count > 0, ErrorCode::NoWinnersInRound);

        let ticket = &mut ctx.accounts.ticket_account;
        require!(!ticket.claimed, ErrorCode::AlreadyClaimed);
        require!(ticket.prediction_hash == round.winning_prediction_hash, ErrorCode::NotWinningTicket);

        let fee_amount = round.total_pool_usdc.checked_mul(JACKPOT_FEE_BPS).unwrap().checked_div(BPS_DENOMINATOR).unwrap();
        let total_prize_pool = round.total_pool_usdc.checked_sub(fee_amount).unwrap();

        // Share = total_prize_pool * (ticket_count / total_winning_tickets)
        let winner_share = total_prize_pool.checked_div(round.winners_count as u64).unwrap();

        let tier_bytes = round.tier.to_le_bytes();
        let round_bytes = round.round_id.to_le_bytes();
        let signer_seeds: &[&[&[u8]]] = &[&[
            b"jackpot_vault",
            tier_bytes.as_ref(),
            round_bytes.as_ref(),
            &[round.vault_bump],
        ]];

        let claim_cpi = Transfer {
            from: ctx.accounts.vault_token_account.to_account_info(),
            to: ctx.accounts.winner_token_account.to_account_info(),
            authority: ctx.accounts.vault_token_account.to_account_info(),
        };
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                claim_cpi,
                signer_seeds,
            ),
            winner_share,
        )?;

        ticket.claimed = true;

        emit!(PrizeClaimedEvent {
            round: round.key(),
            winner: ticket.buyer,
            claimed_amount_usdc: winner_share,
        });

        Ok(())
    }
}

pub fn get_tier_cost(tier: u8) -> Result<u64> {
    match tier {
        1 => Ok(TIER_1_COST),
        2 => Ok(TIER_2_COST),
        3 => Ok(TIER_3_COST),
        4 => Ok(TIER_4_COST),
        5 => Ok(TIER_5_COST),
        _ => Err(ErrorCode::InvalidTier.into()),
    }
}

// ----------------- ACCOUNTS -----------------

#[derive(Accounts)]
pub struct InitializeJackpot<'info> {
    #[account(
        init,
        payer = admin,
        space = 8 + JackpotConfig::INIT_SPACE,
        seeds = [b"jackpot_config"],
        bump
    )]
    pub jackpot_config: Account<'info, JackpotConfig>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(question_id: u64, tier: u8, round_id: u64)]
pub struct OpenRound<'info> {
    #[account(
        seeds = [b"jackpot_config"],
        bump = jackpot_config.bump,
        has_one = admin
    )]
    pub jackpot_config: Account<'info, JackpotConfig>,

    #[account(
        init,
        payer = admin,
        space = 8 + RoundAccount::INIT_SPACE,
        seeds = [b"round", tier.to_le_bytes().as_ref(), round_id.to_le_bytes().as_ref()],
        bump
    )]
    pub round_account: Account<'info, RoundAccount>,

    #[account(
        init,
        payer = admin,
        seeds = [b"jackpot_vault", tier.to_le_bytes().as_ref(), round_id.to_le_bytes().as_ref()],
        bump,
        token::mint = usdc_mint,
        token::authority = vault_token_account
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    pub usdc_mint: Account<'info, Mint>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(prediction_hash: [u8; 32])]
pub struct BuyTickets<'info> {
    #[account(
        seeds = [b"jackpot_config"],
        bump = jackpot_config.bump
    )]
    pub jackpot_config: Account<'info, JackpotConfig>,

    #[account(
        mut,
        seeds = [b"round", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.bump
    )]
    pub round_account: Account<'info, RoundAccount>,

    #[account(
        mut,
        seeds = [b"jackpot_vault", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.vault_bump
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    #[account(
        init,
        payer = buyer,
        space = 8 + TicketAccount::INIT_SPACE,
        seeds = [b"ticket", round_account.key().as_ref(), buyer.key().as_ref(), prediction_hash.as_ref()],
        bump
    )]
    pub ticket_account: Account<'info, TicketAccount>,

    #[account(
        mut,
        constraint = buyer_token_account.owner == buyer.key()
    )]
    pub buyer_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub buyer: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SettleRound<'info> {
    #[account(
        seeds = [b"jackpot_config"],
        bump = jackpot_config.bump,
        has_one = admin
    )]
    pub jackpot_config: Account<'info, JackpotConfig>,

    #[account(
        mut,
        seeds = [b"round", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.bump
    )]
    pub round_account: Account<'info, RoundAccount>,

    #[account(
        mut,
        seeds = [b"jackpot_vault", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.vault_bump
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = fee_recipient_token_account.owner == jackpot_config.fee_recipient
    )]
    pub fee_recipient_token_account: Account<'info, TokenAccount>,

    pub admin: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct ClaimPrize<'info> {
    #[account(
        seeds = [b"round", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.bump
    )]
    pub round_account: Account<'info, RoundAccount>,

    #[account(
        mut,
        seeds = [b"jackpot_vault", round_account.tier.to_le_bytes().as_ref(), round_account.round_id.to_le_bytes().as_ref()],
        bump = round_account.vault_bump
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        seeds = [b"ticket", round_account.key().as_ref(), ticket_account.buyer.as_ref(), ticket_account.prediction_hash.as_ref()],
        bump = ticket_account.bump,
        has_one = buyer
    )]
    pub ticket_account: Account<'info, TicketAccount>,

    #[account(
        mut,
        constraint = winner_token_account.owner == buyer.key()
    )]
    pub winner_token_account: Account<'info, TokenAccount>,

    pub buyer: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

// ----------------- STATE -----------------

#[account]
#[derive(InitSpace)]
pub struct JackpotConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct RoundAccount {
    pub question_id: u64,
    pub tier: u8,
    pub round_id: u64,
    pub entry_end_time: i64,
    pub settlement_time: i64,
    pub tier_ticket_cost: u64,
    pub total_tickets: u64,
    pub total_pool_usdc: u64,
    pub is_settled: bool,
    pub winning_prediction_hash: [u8; 32],
    pub winners_count: u32,
    pub bump: u8,
    pub vault_bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct TicketAccount {
    pub round: Pubkey,
    pub buyer: Pubkey,
    pub prediction_hash: [u8; 32],
    pub ticket_count: u32,
    pub claimed: bool,
    pub bump: u8,
}

// ----------------- EVENTS -----------------

#[event]
pub struct RoundOpenedEvent {
    pub question_id: u64,
    pub tier: u8,
    pub round_id: u64,
    pub entry_end_time: i64,
    pub settlement_time: i64,
    pub ticket_cost: u64,
}

#[event]
pub struct TicketPurchasedEvent {
    pub round: Pubkey,
    pub buyer: Pubkey,
    pub ticket_count: u32,
    pub total_cost: u64,
    pub prediction_hash: [u8; 32],
}

#[event]
pub struct RoundSettledEvent {
    pub round: Pubkey,
    pub winning_prediction_hash: [u8; 32],
    pub winners_count: u32,
    pub prize_pool_usdc: u64,
    pub rollover: bool,
}

#[event]
pub struct PrizeClaimedEvent {
    pub round: Pubkey,
    pub winner: Pubkey,
    pub claimed_amount_usdc: u64,
}

// ----------------- ERRORS -----------------

#[error_code]
pub enum ErrorCode {
    #[msg("Grand Jackpot is currently paused.")]
    JackpotPaused,
    #[msg("Invalid tier specified (must be 1-5).")]
    InvalidTier,
    #[msg("Settlement time must be equal to or after entry deadline.")]
    InvalidTiming,
    #[msg("Ticket count must be greater than zero.")]
    InvalidTicketCount,
    #[msg("Round has already been settled.")]
    RoundAlreadySettled,
    #[msg("Entry window is locked. Submissions are closed.")]
    EntryWindowLocked,
    #[msg("Settlement time has not been reached yet.")]
    SettlementTimeNotReached,
    #[msg("Round has not been settled yet.")]
    RoundNotSettled,
    #[msg("No winners in this round.")]
    NoWinnersInRound,
    #[msg("Prize already claimed.")]
    AlreadyClaimed,
    #[msg("This ticket does not match the winning outcome.")]
    NotWinningTicket,
}
