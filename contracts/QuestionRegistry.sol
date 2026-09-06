// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title QuestionRegistry
 * @notice Canonical On-Chain Question & Oracle Registry for PvP Arena
 * @dev Multi-admin registry with Gas Tank refund support on Robinhood Chain
 */
contract QuestionRegistry {
    address public owner;
    address public backupAdmin;

    mapping(address => bool) public isAuthorizedCreator;

    struct Question {
        uint256 id;
        string title;
        string category;
        string resolutionSource;
        uint256 entryDeadline;
        uint256 settlementTime;
        bool isDynamicSettlement;
        uint256[] allowedTiers;
        bool isClosed;
        bool isSettled;
        uint8 winningOutcome; // 0: Unresolved, 1: YES / GREEN, 2: NO / RED, 3: REFUND
        uint256 settledAt;
    }

    uint256 public nextQuestionId = 1;
    mapping(uint256 => Question) public questions;

    event QuestionCreated(
        uint256 indexed id,
        string title,
        string category,
        uint256 entryDeadline,
        uint256 settlementTime,
        bool isDynamicSettlement
    );
    event QuestionClosed(uint256 indexed id);
    event QuestionSettled(uint256 indexed id, uint8 winningOutcome, uint256 settledAt);
    event GasRefunded(address indexed creator, uint256 amount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event CreatorAuthUpdated(address indexed creator, bool status);
    event GasTankFunded(address indexed sender, uint256 amount);

    modifier onlyAuthorized() {
        require(
            msg.sender == owner || msg.sender == backupAdmin || isAuthorizedCreator[msg.sender],
            "Not authorized"
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _owner, address _backupAdmin) payable {
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
        backupAdmin = _backupAdmin;
        isAuthorizedCreator[_owner] = true;
        if (_backupAdmin != address(0)) {
            isAuthorizedCreator[_backupAdmin] = true;
        }
    }

    receive() external payable {
        emit GasTankFunded(msg.sender, msg.value);
    }

    function createQuestion(
        string calldata title,
        string calldata category,
        string calldata resolutionSource,
        uint256 entryDeadline,
        uint256 settlementTime,
        bool isDynamicSettlement,
        uint256[] calldata allowedTiers
    ) external onlyAuthorized returns (uint256) {
        uint256 startGas = gasleft();
        uint256 qId = nextQuestionId++;

        questions[qId] = Question({
            id: qId,
            title: title,
            category: category,
            resolutionSource: resolutionSource,
            entryDeadline: entryDeadline,
            settlementTime: settlementTime,
            isDynamicSettlement: isDynamicSettlement,
            allowedTiers: allowedTiers,
            isClosed: false,
            isSettled: false,
            winningOutcome: 0,
            settledAt: 0
        });

        emit QuestionCreated(qId, title, category, entryDeadline, settlementTime, isDynamicSettlement);

        _autoRefundGas(startGas);
        return qId;
    }

    function closeQuestion(uint256 qId) external onlyAuthorized {
        uint256 startGas = gasleft();
        require(questions[qId].id != 0, "Question not found");
        require(!questions[qId].isClosed, "Already closed");

        questions[qId].isClosed = true;
        emit QuestionClosed(qId);

        _autoRefundGas(startGas);
    }

    function settleQuestion(uint256 qId, uint8 winningOutcome) external onlyAuthorized {
        uint256 startGas = gasleft();
        require(questions[qId].id != 0, "Question not found");
        require(!questions[qId].isSettled, "Already settled");
        require(winningOutcome >= 1 && winningOutcome <= 3, "Invalid outcome");

        questions[qId].isClosed = true;
        questions[qId].isSettled = true;
        questions[qId].winningOutcome = winningOutcome;
        questions[qId].settledAt = block.timestamp;

        emit QuestionSettled(qId, winningOutcome, block.timestamp);

        _autoRefundGas(startGas);
    }

    function _autoRefundGas(uint256 startGas) internal {
        uint256 gasUsed = (startGas - gasleft()) + 25000;
        uint256 refundAmount = gasUsed * tx.gasprice;
        if (address(this).balance >= refundAmount && refundAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            if (success) {
                emit GasRefunded(msg.sender, refundAmount);
            }
        }
    }

    function getQuestion(uint256 qId) external view returns (Question memory) {
        require(questions[qId].id != 0, "Question not found");
        return questions[qId];
    }

    function getAllQuestions() external view returns (Question[] memory) {
        uint256 total = nextQuestionId - 1;
        Question[] memory allQ = new Question[](total);
        for (uint256 i = 1; i <= total; i++) {
            allQ[i - 1] = questions[i];
        }
        return allQ;
    }

    function setBackupAdmin(address _newBackupAdmin) external onlyOwner {
        address old = backupAdmin;
        backupAdmin = _newBackupAdmin;
        if (_newBackupAdmin != address(0)) {
            isAuthorizedCreator[_newBackupAdmin] = true;
        }
        emit AdminUpdated(old, _newBackupAdmin);
    }

    function setAuthorizedCreator(address creator, bool status) external onlyOwner {
        isAuthorizedCreator[creator] = status;
        emit CreatorAuthUpdated(creator, status);
    }

    function withdrawGasTank(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient tank balance");
        payable(owner).transfer(amount);
    }
}
