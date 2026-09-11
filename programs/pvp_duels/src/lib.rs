use anchor_lang::prelude::*;
use anchor_spl::token::{self, CloseAccount, Token, TokenAccount, Transfer};

declare_id!("Fn1G1zpiiZk5ZXL27tcyG5FgVjSVP7ZUL3TainYfWFJK");

#[program]
pub mod pvp_duels {
    use super::*;

    /// 1. Create a non-custodial 1v1 PvP duel and deposit stake into program-controlled escrow PDA
    pub fn create_duel(
        ctx: Context<CreateDuel>,
        duel_id: u64,
        question_id: u64,
        chosen_option: u8,
        stake_amount: u64,
        entry_deadline: i64,
    ) -> Result<()> {
        let clock = Clock::get()?;
        require!(entry_deadline > clock.unix_timestamp, ErrorCode::DeadlinePassed);
        require!(stake_amount > 0, ErrorCode::InvalidStakeAmount);

        let duel = &mut ctx.accounts.duel;
        duel.creator = ctx.accounts.creator.key();
        duel.opponent = None;
        duel.duel_id = duel_id;
        duel.question_id = question_id;
        duel.chosen_option = chosen_option;
        duel.stake_amount = stake_amount;
        duel.entry_deadline = entry_deadline;
        duel.status = DuelStatus::Open;
        duel.bump = ctx.bumps.duel;
        duel.vault_bump = ctx.bumps.vault;

        // Transfer tokens from creator to PDA escrow vault
        let cpi_accounts = Transfer {
            from: ctx.accounts.creator_token_account.to_account_info(),
            to: ctx.accounts.vault.to_account_info(),
            authority: ctx.accounts.creator.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(CpiContext::new(cpi_program, cpi_accounts), stake_amount)?;

        emit!(DuelCreated {
            duel_id,
            question_id,
            creator: ctx.accounts.creator.key(),
            stake_amount,
            entry_deadline,
        });

        Ok(())
    }

    /// 2. Accept challenge: Opponent deposits equal stake into escrow PDA, matching the duel
    pub fn accept_duel(ctx: Context<AcceptDuel>) -> Result<()> {
        let clock = Clock::get()?;
        let duel = &mut ctx.accounts.duel;

        require!(duel.status == DuelStatus::Open, ErrorCode::DuelNotOpen);
        require!(clock.unix_timestamp < duel.entry_deadline, ErrorCode::DeadlinePassed);
        require!(ctx.accounts.opponent.key() != duel.creator, ErrorCode::CannotChallengeSelf);

        duel.opponent = Some(ctx.accounts.opponent.key());
        duel.status = DuelStatus::Matched;

        // Transfer tokens from opponent to PDA escrow vault
        let cpi_accounts = Transfer {
            from: ctx.accounts.opponent_token_account.to_account_info(),
            to: ctx.accounts.vault.to_account_info(),
            authority: ctx.accounts.opponent.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(CpiContext::new(cpi_program, cpi_accounts), duel.stake_amount)?;

        emit!(DuelMatched {
            duel_id: duel.duel_id,
            creator: duel.creator,
            opponent: ctx.accounts.opponent.key(),
            total_pot: duel.stake_amount * 2,
        });

        Ok(())
    }

    /// 3. Cancel unmatched duel: 100% autonomous, non-custodial refund directly back to creator!
    /// No admin, no relayer, and no third party required.
    pub fn cancel_duel(ctx: Context<CancelDuel>) -> Result<()> {
        let duel = &ctx.accounts.duel;

        require!(duel.status == DuelStatus::Open, ErrorCode::DuelNotOpen);
        require!(duel.creator == ctx.accounts.creator.key(), ErrorCode::Unauthorized);

        let creator_key = duel.creator;
        let duel_id_bytes = duel.duel_id.to_le_bytes();
        let bump = duel.bump;

        let signer_seeds: &[&[&[u8]]] = &[&[
            b"duel",
            creator_key.as_ref(),
            &duel_id_bytes,
            &[bump],
        ]];

        // Autonomous transfer: Return 100% of stake from PDA vault back to creator
        let cpi_accounts = Transfer {
            from: ctx.accounts.vault.to_account_info(),
            to: ctx.accounts.creator_token_account.to_account_info(),
            authority: ctx.accounts.duel.to_account_info(),
        };
        let cpi_program = ctx.accounts.token_program.to_account_info();
        token::transfer(
            CpiContext::new_with_signer(cpi_program, cpi_accounts, signer_seeds),
            duel.stake_amount,
        )?;

        // Close PDA vault token account and return rent SOL to creator
        let close_accounts = CloseAccount {
            account: ctx.accounts.vault.to_account_info(),
            destination: ctx.accounts.creator.to_account_info(),
            authority: ctx.accounts.duel.to_account_info(),
        };
        token::close_account(CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            close_accounts,
            signer_seeds,
        ))?;

        emit!(DuelCancelled {
            duel_id: duel.duel_id,
            creator: duel.creator,
            refunded_amount: duel.stake_amount,
        });

        Ok(())
    }
}

#[derive(Accounts)]
#[instruction(duel_id: u64)]
pub struct CreateDuel<'info> {
    #[account(
        init,
        payer = creator,
        space = 8 + DuelAccount::LEN,
        seeds = [b"duel", creator.key().as_ref(), &duel_id.to_le_bytes()],
        bump
    )]
    pub duel: Account<'info, DuelAccount>,

    #[account(
        init,
        payer = creator,
        seeds = [b"vault", duel.key().as_ref()],
        bump,
        token::mint = usdc_mint,
        token::authority = duel,
    )]
    pub vault: Account<'info, TokenAccount>,

    #[account(mut)]
    pub creator: Signer<'info>,

    #[account(
        mut,
        constraint = creator_token_account.owner == creator.key(),
        constraint = creator_token_account.mint == usdc_mint.key()
    )]
    pub creator_token_account: Account<'info, TokenAccount>,

    pub usdc_mint: Account<'info, anchor_spl::token::Mint>,
    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct AcceptDuel<'info> {
    #[account(
        mut,
        seeds = [b"duel", duel.creator.as_ref(), &duel.duel_id.to_le_bytes()],
        bump = duel.bump,
    )]
    pub duel: Account<'info, DuelAccount>,

    #[account(
        mut,
        seeds = [b"vault", duel.key().as_ref()],
        bump = duel.vault_bump,
    )]
    pub vault: Account<'info, TokenAccount>,

    #[account(mut)]
    pub opponent: Signer<'info>,

    #[account(
        mut,
        constraint = opponent_token_account.owner == opponent.key(),
        constraint = opponent_token_account.mint == vault.mint
    )]
    pub opponent_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct CancelDuel<'info> {
    #[account(
        mut,
        close = creator,
        seeds = [b"duel", creator.key().as_ref(), &duel.duel_id.to_le_bytes()],
        bump = duel.bump,
    )]
    pub duel: Account<'info, DuelAccount>,

    #[account(
        mut,
        seeds = [b"vault", duel.key().as_ref()],
        bump = duel.vault_bump,
    )]
    pub vault: Account<'info, TokenAccount>,

    #[account(mut)]
    pub creator: Signer<'info>,

    #[account(
        mut,
        constraint = creator_token_account.owner == creator.key(),
        constraint = creator_token_account.mint == vault.mint
    )]
    pub creator_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
}

#[account]
pub struct DuelAccount {
    pub creator: Pubkey,
    pub opponent: Option<Pubkey>,
    pub duel_id: u64,
    pub question_id: u64,
    pub chosen_option: u8,
    pub stake_amount: u64,
    pub entry_deadline: i64,
    pub status: DuelStatus,
    pub bump: u8,
    pub vault_bump: u8,
}

impl DuelAccount {
    pub const LEN: usize = 32 + 33 + 8 + 8 + 1 + 8 + 8 + 1 + 1 + 1;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub enum DuelStatus {
    Open,
    Matched,
    Cancelled,
    Settled,
}

#[event]
pub struct DuelCreated {
    pub duel_id: u64,
    pub question_id: u64,
    pub creator: Pubkey,
    pub stake_amount: u64,
    pub entry_deadline: i64,
}

#[event]
pub struct DuelMatched {
    pub duel_id: u64,
    pub creator: Pubkey,
    pub opponent: Pubkey,
    pub total_pot: u64,
}

#[event]
pub struct DuelCancelled {
    pub duel_id: u64,
    pub creator: Pubkey,
    pub refunded_amount: u64,
}

#[error_code]
pub enum ErrorCode {
    #[msg("The entry deadline for this question has already passed.")]
    DeadlinePassed,
    #[msg("Invalid stake amount specified.")]
    InvalidStakeAmount,
    #[msg("This duel is not open for matching or cancellation.")]
    DuelNotOpen,
    #[msg("You cannot accept your own duel challenge.")]
    CannotChallengeSelf,
    #[msg("Unauthorized action on this duel.")]
    Unauthorized,
}
