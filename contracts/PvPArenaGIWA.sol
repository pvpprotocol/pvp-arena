// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract PvPArenaGIWA {
    enum DuelStatus { Open, Matched, Resolved, Cancelled, Refunded }

    struct Duel {
        uint256 duelId;
        address creator;
        address challenger;
        address token; // address(0) for native ETH
        uint256 entryStake;
        uint256 targetPrice;
        bool isCreatorLong;
        uint256 entryDeadline;
        uint256 settlementTime;
        DuelStatus status;
        address winner;
        string marketSymbol;
    }

    address public owner;
    address public resolver;
    address public treasury;

    uint256 public constant WINNER_SHARE_BPS = 9000; // 90% (1.8x)
    uint256 public constant CASHBACK_BPS = 300;     // 3%
    uint256 public constant TREASURY_BPS = 700;     // 7%
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant ORACLE_GRACE_PERIOD = 6 hours;

    uint256 public nextDuelId = 1;
    mapping(uint256 => Duel) public duels;

    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyResolver() {
        require(msg.sender == resolver || msg.sender == owner, "NOT_RESOLVER");
        _;
    }

    event DuelCreated(uint256 indexed duelId, address indexed creator, address token, uint256 entryStake, string marketSymbol);
    event DuelJoined(uint256 indexed duelId, address indexed challenger);
    event DuelResolved(uint256 indexed duelId, address indexed winner, uint256 winnerPayout, uint256 loserCashback);
    event DuelCancelled(uint256 indexed duelId, address indexed creator);
    event DuelRefunded(uint256 indexed duelId);

    constructor(address _resolver, address _treasury) {
        owner = msg.sender;
        resolver = _resolver;
        treasury = _treasury;
    }

    function createDuel(
        address token,
        uint256 entryStake,
        uint256 targetPrice,
        bool isCreatorLong,
        uint256 entryDeadline,
        uint256 settlementTime,
        string calldata marketSymbol
    ) external payable nonReentrant returns (uint256) {
        require(entryStake > 0, "INVALID_STAKE");
        require(entryDeadline > block.timestamp, "INVALID_DEADLINE");
        require(settlementTime >= entryDeadline, "INVALID_SETTLEMENT");

        if (token == address(0)) {
            require(msg.value == entryStake, "INVALID_ETH_VALUE");
        } else {
            require(msg.value == 0, "ETH_NOT_ACCEPTED");
            require(IERC20(token).transferFrom(msg.sender, address(this), entryStake), "TRANSFER_FAILED");
        }

        uint256 duelId = nextDuelId++;
        duels[duelId] = Duel({
            duelId: duelId,
            creator: msg.sender,
            challenger: address(0),
            token: token,
            entryStake: entryStake,
            targetPrice: targetPrice,
            isCreatorLong: isCreatorLong,
            entryDeadline: entryDeadline,
            settlementTime: settlementTime,
            status: DuelStatus.Open,
            winner: address(0),
            marketSymbol: marketSymbol
        });

        emit DuelCreated(duelId, msg.sender, token, entryStake, marketSymbol);
        return duelId;
    }

    function joinDuel(uint256 duelId) external payable nonReentrant {
        Duel storage duel = duels[duelId];
        require(duel.status == DuelStatus.Open, "DUEL_NOT_OPEN");
        require(block.timestamp <= duel.entryDeadline, "ENTRY_EXPIRED");
        require(msg.sender != duel.creator, "CANNOT_PLAY_SELF");

        if (duel.token == address(0)) {
            require(msg.value == duel.entryStake, "INVALID_ETH_VALUE");
        } else {
            require(msg.value == 0, "ETH_NOT_ACCEPTED");
            require(IERC20(duel.token).transferFrom(msg.sender, address(this), duel.entryStake), "TRANSFER_FAILED");
        }

        duel.challenger = msg.sender;
        duel.status = DuelStatus.Matched;

        emit DuelJoined(duelId, msg.sender);
    }

    function cancelDuel(uint256 duelId) external nonReentrant {
        Duel storage duel = duels[duelId];
        require(duel.creator == msg.sender, "NOT_CREATOR");
        require(duel.status == DuelStatus.Open, "DUEL_NOT_OPEN");

        duel.status = DuelStatus.Cancelled;
        _safeTransfer(duel.token, duel.creator, duel.entryStake);

        emit DuelCancelled(duelId, msg.sender);
    }

    function resolveDuel(uint256 duelId, address winner) external onlyResolver nonReentrant {
        Duel storage duel = duels[duelId];
        require(duel.status == DuelStatus.Matched, "DUEL_NOT_MATCHED");
        require(block.timestamp >= duel.settlementTime, "TOO_EARLY");
        require(winner == duel.creator || winner == duel.challenger || winner == address(0), "INVALID_WINNER");

        duel.status = DuelStatus.Resolved;
        duel.winner = winner;

        uint256 totalPot = duel.entryStake * 2;

        if (winner == address(0)) {
            _safeTransfer(duel.token, duel.creator, duel.entryStake);
            _safeTransfer(duel.token, duel.challenger, duel.entryStake);
            emit DuelRefunded(duelId);
            return;
        }

        address loser = (winner == duel.creator) ? duel.challenger : duel.creator;
        uint256 winnerPayout = (totalPot * WINNER_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 loserCashback = (totalPot * CASHBACK_BPS) / BPS_DENOMINATOR;
        uint256 treasuryFee = totalPot - winnerPayout - loserCashback;

        _safeTransfer(duel.token, winner, winnerPayout);
        _safeTransfer(duel.token, loser, loserCashback);
        if (treasuryFee > 0 && treasury != address(0)) {
            _safeTransfer(duel.token, treasury, treasuryFee);
        }

        emit DuelResolved(duelId, winner, winnerPayout, loserCashback);
    }

    function emergencyRefund(uint256 duelId) external nonReentrant {
        Duel storage duel = duels[duelId];
        require(duel.status == DuelStatus.Matched, "NOT_MATCHED");
        require(block.timestamp > duel.settlementTime + ORACLE_GRACE_PERIOD, "GRACE_ACTIVE");

        duel.status = DuelStatus.Refunded;
        _safeTransfer(duel.token, duel.creator, duel.entryStake);
        _safeTransfer(duel.token, duel.challenger, duel.entryStake);

        emit DuelRefunded(duelId);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            require(IERC20(token).transfer(to, amount), "TOKEN_TRANSFER_FAILED");
        }
    }

    function setResolver(address _resolver) external onlyOwner {
        resolver = _resolver;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
}
