use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

declare_id!("PvPDueLs11111111111111111111111111111111111");

pub const PLATFORM_FEE_BPS: u64 = 500; // 5% platform fee
pub const BPS_DENOMINATOR: u64 = 10000;

#[program]
pub mod pvp_duels {
    use super::*;

    pub fn initialize_platform(
        ctx: Context<InitializePlatform>,
        fee_recipient: Pubkey,
    ) -> Result<()> {
        let platform = &mut ctx.accounts.platform_config;
        platform.admin = ctx.accounts.admin.key();
        platform.fee_recipient = fee_recipient;
        platform.total_duels_count = 0;
        platform.total_volume_usdc = 0;
        platform.paused = false;
        platform.bump = ctx.bumps.platform_config;
        Ok(())
    }

    /// Maker creates a 1v1 PvP Duel escrow with USDC stake
    pub fn create_duel(
        ctx: Context<CreateDuel>,
        question_id: u64,
        maker_option: u8,
        stake_amount: u64,
        entry_deadline: i64,
        settlement_time: i64,
    ) -> Result<()> {
        let platform = &mut ctx.accounts.platform_config;
        require!(!platform.paused, ErrorCode::PlatformPaused);
        require!(stake_amount > 0, ErrorCode::InvalidStakeAmount);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp < entry_deadline, ErrorCode::DeadlinePassed);
        require!(entry_deadline <= settlement_time, ErrorCode::InvalidSettlementTime);

        // Transfer maker stake USDC into the escrow token account
        let cpi_accounts = Transfer {
            from: ctx.accounts.maker_token_account.to_account_info(),
            to: ctx.accounts.escrow_token_account.to_account_info(),
            authority: ctx.accounts.maker.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(CpiContext::new(cpi_program, cpi_accounts), stake_amount)?;

        let duel = &mut ctx.accounts.duel_account;
        duel.question_id = question_id;
        duel.duel_index = platform.total_duels_count;
        duel.maker = ctx.accounts.maker.key();
        duel.taker = Pubkey::default();
        duel.stake_amount = stake_amount;
        duel.maker_option = maker_option;
        duel.taker_option = 0;
        duel.entry_deadline = entry_deadline;
        duel.settlement_time = settlement_time;
        duel.status = DuelStatus::Open;
        duel.winner = Pubkey::default();
        duel.bump = ctx.bumps.duel_account;
        duel.escrow_bump = ctx.bumps.escrow_token_account;

        platform.total_duels_count = platform.total_duels_count.checked_add(1).unwrap();
        platform.total_volume_usdc = platform.total_volume_usdc.checked_add(stake_amount).unwrap();

        emit!(DuelCreatedEvent {
            question_id,
            duel_index: duel.duel_index,
            maker: duel.maker,
            stake_amount,
            maker_option,
            entry_deadline,
            settlement_time,
        });

        Ok(())
    }

    /// Taker accepts the open duel and matches the exact stake amount
    pub fn accept_duel(
        ctx: Context<AcceptDuel>,
        taker_option: u8,
    ) -> Result<()> {
        let platform = &mut ctx.accounts.platform_config;
        require!(!platform.paused, ErrorCode::PlatformPaused);

        let duel = &mut ctx.accounts.duel_account;
        require!(duel.status == DuelStatus::Open, ErrorCode::DuelNotOpen);
        require!(duel.maker != ctx.accounts.taker.key(), ErrorCode::CannotDuelSelf);
        require!(taker_option != duel.maker_option, ErrorCode::MustChooseOppositeOption);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp < duel.entry_deadline, ErrorCode::EntryWindowClosed);

        // Transfer taker stake USDC into the escrow token account
        let cpi_accounts = Transfer {
            from: ctx.accounts.taker_token_account.to_account_info(),
            to: ctx.accounts.escrow_token_account.to_account_info(),
            authority: ctx.accounts.taker.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(CpiContext::new(cpi_program, cpi_accounts), duel.stake_amount)?;

        duel.taker = ctx.accounts.taker.key();
        duel.taker_option = taker_option;
        duel.status = DuelStatus::Matched;

        platform.total_volume_usdc = platform.total_volume_usdc.checked_add(duel.stake_amount).unwrap();

        emit!(DuelMatchedEvent {
            question_id: duel.question_id,
            duel_index: duel.duel_index,
            maker: duel.maker,
            taker: duel.taker,
            stake_amount: duel.stake_amount,
        });

        Ok(())
    }

    /// Settle duel by authorized admin/oracle: 95% to winner, 5% to platform fee
    pub fn settle_duel(
        ctx: Context<SettleDuel>,
        winning_option: u8,
    ) -> Result<()> {
        let duel = &mut ctx.accounts.duel_account;
        require!(duel.status == DuelStatus::Matched, ErrorCode::DuelNotMatched);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp >= duel.settlement_time, ErrorCode::SettlementTimeNotReached);

        let winner_pubkey = if duel.maker_option == winning_option {
            duel.maker
        } else if duel.taker_option == winning_option {
            duel.taker
        } else {
            return Err(ErrorCode::InvalidWinningOption.into());
        };

        let total_pot = duel.stake_amount.checked_mul(2).unwrap();
        let fee_amount = total_pot.checked_mul(PLATFORM_FEE_BPS).unwrap().checked_div(BPS_DENOMINATOR).unwrap();
        let winner_prize = total_pot.checked_sub(fee_amount).unwrap(); // 95%

        let question_bytes = duel.question_id.to_le_bytes();
        let index_bytes = duel.duel_index.to_le_bytes();
        let signer_seeds: &[&[&[u8]]] = &[&[
            b"duel_escrow",
            question_bytes.as_ref(),
            index_bytes.as_ref(),
            &[duel.escrow_bump],
        ]];

        // 1. Transfer 5% platform fee
        if fee_amount > 0 {
            let fee_cpi = Transfer {
                from: ctx.accounts.escrow_token_account.to_account_info(),
                to: ctx.accounts.fee_recipient_token_account.to_account_info(),
                authority: ctx.accounts.escrow_token_account.to_account_info(),
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

        // 2. Transfer 95% prize to winner
        let winner_cpi = Transfer {
            from: ctx.accounts.escrow_token_account.to_account_info(),
            to: ctx.accounts.winner_token_account.to_account_info(),
            authority: ctx.accounts.escrow_token_account.to_account_info(),
        };
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                winner_cpi,
                signer_seeds,
            ),
            winner_prize,
        )?;

        duel.winner = winner_pubkey;
        duel.status = DuelStatus::Settled;

        emit!(DuelSettledEvent {
            question_id: duel.question_id,
            duel_index: duel.duel_index,
            winner: winner_pubkey,
            prize_usdc: winner_prize,
            fee_usdc: fee_amount,
        });

        Ok(())
    }

    /// Cancel unfilled duel after entry deadline: 100% refund to maker
    pub fn cancel_unfilled_duel(ctx: Context<CancelUnfilledDuel>) -> Result<()> {
        let duel = &mut ctx.accounts.duel_account;
        require!(duel.status == DuelStatus::Open, ErrorCode::DuelNotOpen);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp >= duel.entry_deadline, ErrorCode::EntryDeadlineNotPassed);

        let question_bytes = duel.question_id.to_le_bytes();
        let index_bytes = duel.duel_index.to_le_bytes();
        let signer_seeds: &[&[&[u8]]] = &[&[
            b"duel_escrow",
            question_bytes.as_ref(),
            index_bytes.as_ref(),
            &[duel.escrow_bump],
        ]];

        let refund_cpi = Transfer {
            from: ctx.accounts.escrow_token_account.to_account_info(),
            to: ctx.accounts.maker_token_account.to_account_info(),
            authority: ctx.accounts.escrow_token_account.to_account_info(),
        };
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                refund_cpi,
                signer_seeds,
            ),
            duel.stake_amount,
        )?;

        duel.status = DuelStatus::Cancelled;

        emit!(DuelCancelledEvent {
            question_id: duel.question_id,
            duel_index: duel.duel_index,
            refund_amount: duel.stake_amount,
        });

        Ok(())
    }
}

// ----------------- ACCOUNTS -----------------

#[derive(Accounts)]
pub struct InitializePlatform<'info> {
    #[account(
        init,
        payer = admin,
        space = 8 + PlatformConfig::INIT_SPACE,
        seeds = [b"platform_config"],
        bump
    )]
    pub platform_config: Account<'info, PlatformConfig>,
    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(question_id: u64)]
pub struct CreateDuel<'info> {
    #[account(
        mut,
        seeds = [b"platform_config"],
        bump = platform_config.bump
    )]
    pub platform_config: Account<'info, PlatformConfig>,

    #[account(
        init,
        payer = maker,
        space = 8 + DuelAccount::INIT_SPACE,
        seeds = [b"duel", question_id.to_le_bytes().as_ref(), platform_config.total_duels_count.to_le_bytes().as_ref()],
        bump
    )]
    pub duel_account: Account<'info, DuelAccount>,

    #[account(
        init,
        payer = maker,
        seeds = [b"duel_escrow", question_id.to_le_bytes().as_ref(), platform_config.total_duels_count.to_le_bytes().as_ref()],
        bump,
        token::mint = usdc_mint,
        token::authority = escrow_token_account
    )]
    pub escrow_token_account: Account<'info, TokenAccount>,

    pub usdc_mint: Account<'info, Mint>,

    #[account(
        mut,
        constraint = maker_token_account.owner == maker.key(),
        constraint = maker_token_account.mint == usdc_mint.key()
    )]
    pub maker_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub maker: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct AcceptDuel<'info> {
    #[account(
        mut,
        seeds = [b"platform_config"],
        bump = platform_config.bump
    )]
    pub platform_config: Account<'info, PlatformConfig>,

    #[account(
        mut,
        seeds = [b"duel", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.bump
    )]
    pub duel_account: Account<'info, DuelAccount>,

    #[account(
        mut,
        seeds = [b"duel_escrow", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.escrow_bump
    )]
    pub escrow_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = taker_token_account.owner == taker.key()
    )]
    pub taker_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub taker: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct SettleDuel<'info> {
    #[account(
        seeds = [b"platform_config"],
        bump = platform_config.bump,
        has_one = admin
    )]
    pub platform_config: Account<'info, PlatformConfig>,

    #[account(
        mut,
        seeds = [b"duel", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.bump
    )]
    pub duel_account: Account<'info, DuelAccount>,

    #[account(
        mut,
        seeds = [b"duel_escrow", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.escrow_bump
    )]
    pub escrow_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = winner_token_account.owner == duel_account.winner || winner_token_account.owner == duel_account.maker || winner_token_account.owner == duel_account.taker
    )]
    pub winner_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = fee_recipient_token_account.owner == platform_config.fee_recipient
    )]
    pub fee_recipient_token_account: Account<'info, TokenAccount>,

    pub admin: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct CancelUnfilledDuel<'info> {
    #[account(
        mut,
        seeds = [b"duel", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.bump,
        has_one = maker
    )]
    pub duel_account: Account<'info, DuelAccount>,

    #[account(
        mut,
        seeds = [b"duel_escrow", duel_account.question_id.to_le_bytes().as_ref(), duel_account.duel_index.to_le_bytes().as_ref()],
        bump = duel_account.escrow_bump
    )]
    pub escrow_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = maker_token_account.owner == maker.key()
    )]
    pub maker_token_account: Account<'info, TokenAccount>,

    pub maker: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

// ----------------- STATE -----------------

#[account]
#[derive(InitSpace)]
pub struct PlatformConfig {
    pub admin: Pubkey,
    pub fee_recipient: Pubkey,
    pub total_duels_count: u64,
    pub total_volume_usdc: u64,
    pub paused: bool,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct DuelAccount {
    pub question_id: u64,
    pub duel_index: u64,
    pub maker: Pubkey,
    pub taker: Pubkey,
    pub stake_amount: u64,
    pub maker_option: u8,
    pub taker_option: u8,
    pub entry_deadline: i64,
    pub settlement_time: i64,
    pub status: DuelStatus,
    pub winner: Pubkey,
    pub bump: u8,
    pub escrow_bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum DuelStatus {
    Open,
    Matched,
    Settled,
    Cancelled,
}

// ----------------- EVENTS -----------------

#[event]
pub struct DuelCreatedEvent {
    pub question_id: u64,
    pub duel_index: u64,
    pub maker: Pubkey,
    pub stake_amount: u64,
    pub maker_option: u8,
    pub entry_deadline: i64,
    pub settlement_time: i64,
}

#[event]
pub struct DuelMatchedEvent {
    pub question_id: u64,
    pub duel_index: u64,
    pub maker: Pubkey,
    pub taker: Pubkey,
    pub stake_amount: u64,
}

#[event]
pub struct DuelSettledEvent {
    pub question_id: u64,
    pub duel_index: u64,
    pub winner: Pubkey,
    pub prize_usdc: u64,
    pub fee_usdc: u64,
}

#[event]
pub struct DuelCancelledEvent {
    pub question_id: u64,
    pub duel_index: u64,
    pub refund_amount: u64,
}

// ----------------- ERRORS -----------------

#[error_code]
pub enum ErrorCode {
    #[msg("Platform is currently paused.")]
    PlatformPaused,
    #[msg("Invalid stake amount.")]
    InvalidStakeAmount,
    #[msg("Entry deadline has already passed.")]
    DeadlinePassed,
    #[msg("Settlement time must be equal to or after entry deadline.")]
    InvalidSettlementTime,
    #[msg("Duel is not in open status.")]
    DuelNotOpen,
    #[msg("Cannot duel against yourself.")]
    CannotDuelSelf,
    #[msg("Taker must choose the opposing outcome.")]
    MustChooseOppositeOption,
    #[msg("Entry window for this duel has closed.")]
    EntryWindowClosed,
    #[msg("Duel is not in matched status.")]
    DuelNotMatched,
    #[msg("Settlement time has not been reached yet.")]
    SettlementTimeNotReached,
    #[msg("Winning option does not match either participant.")]
    InvalidWinningOption,
    #[msg("Entry deadline has not passed yet.")]
    EntryDeadlineNotPassed,
}
