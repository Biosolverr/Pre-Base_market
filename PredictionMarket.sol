// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ══════════════════════════════════════════════════════════════════
//  Prediction Market Oracle — Solidity Contract
//  Network: Base Mainnet
//  Ставки в ETH, резолюция через owner (оракул-агенты)
//  Flow: create → bet → resolve → claim
// ══════════════════════════════════════════════════════════════════

contract PredictionMarket {

    // ─── Types ────────────────────────────────────────────────────

    enum Status   { Open, Locked, Resolved }
    enum Outcome  { Unresolved, YES, NO, Invalid }

    struct Market {
        uint256 id;
        address creator;
        string  question;
        string  category;
        string  resolutionRule;
        uint256 resolutionDate;  // unix timestamp
        uint256 yesPool;         // total ETH bet YES
        uint256 noPool;          // total ETH bet NO
        Status  status;
        Outcome outcome;
        uint256 createdAt;
        uint256 resolvedAt;
    }

    struct Bet {
        address bettor;
        bool    isYes;           // true = YES, false = NO
        uint256 amount;
        bool    claimed;
    }

    // ─── State ────────────────────────────────────────────────────

    address public owner;
    uint256 public platformFeeBps = 200;   // 2% fee (basis points)
    uint256 public accruedFees;
    uint256 public marketCount;

    mapping(uint256 => Market)              public markets;
    mapping(uint256 => Bet[])               public bets;          // marketId → bets
    mapping(uint256 => mapping(address => uint256[])) public userBetIds; // marketId → bettor → bet indices

    uint256 public constant MIN_BET       = 0.001 ether;
    uint256 public constant MIN_DESC_LEN  = 10;

    // ─── Events ───────────────────────────────────────────────────

    event MarketCreated(uint256 indexed id, address indexed creator, string question, uint256 resolutionDate);
    event BetPlaced(uint256 indexed marketId, address indexed bettor, bool isYes, uint256 amount);
    event MarketResolved(uint256 indexed marketId, Outcome outcome, uint256 yesPool, uint256 noPool);
    event Claimed(uint256 indexed marketId, address indexed bettor, uint256 payout);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ─── Modifiers ────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier marketExists(uint256 marketId) {
        require(marketId < marketCount, "Market not found");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ─── Market Creation ──────────────────────────────────────────

    function createMarket(
        string calldata question,
        string calldata category,
        string calldata resolutionRule,
        uint256 resolutionDate
    ) external returns (uint256 marketId) {
        require(bytes(question).length >= MIN_DESC_LEN, "Question too short");
        require(bytes(resolutionRule).length > 0,       "Resolution rule required");
        require(resolutionDate > block.timestamp,        "Resolution date must be future");

        marketId = marketCount++;

        markets[marketId] = Market({
            id:             marketId,
            creator:        msg.sender,
            question:       question,
            category:       category,
            resolutionRule: resolutionRule,
            resolutionDate: resolutionDate,
            yesPool:        0,
            noPool:         0,
            status:         Status.Open,
            outcome:        Outcome.Unresolved,
            createdAt:      block.timestamp,
            resolvedAt:     0
        });

        emit MarketCreated(marketId, msg.sender, question, resolutionDate);
    }

    // ─── Place Bet ────────────────────────────────────────────────

    function placeBet(uint256 marketId, bool isYes)
        external
        payable
        marketExists(marketId)
    {
        Market storage m = markets[marketId];
        require(m.status == Status.Open,             "Market not open");
        require(block.timestamp < m.resolutionDate,  "Betting period over");
        require(msg.value >= MIN_BET,                "Bet too small (min 0.001 ETH)");

        uint256 betIndex = bets[marketId].length;
        bets[marketId].push(Bet({
            bettor:  msg.sender,
            isYes:   isYes,
            amount:  msg.value,
            claimed: false
        }));

        userBetIds[marketId][msg.sender].push(betIndex);

        if (isYes) {
            m.yesPool += msg.value;
        } else {
            m.noPool  += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    // ─── Resolve (only owner = oracle backend) ────────────────────

    function resolve(uint256 marketId, Outcome outcome)
        external
        onlyOwner
        marketExists(marketId)
    {
        Market storage m = markets[marketId];
        require(m.status != Status.Resolved, "Already resolved");
        require(outcome != Outcome.Unresolved, "Invalid outcome");

        m.status     = Status.Resolved;
        m.outcome    = outcome;
        m.resolvedAt = block.timestamp;

        emit MarketResolved(marketId, outcome, m.yesPool, m.noPool);
    }

    // ─── Claim Payout ─────────────────────────────────────────────

    function claim(uint256 marketId) external marketExists(marketId) {
        Market storage m = markets[marketId];
        require(m.status == Status.Resolved, "Not resolved yet");

        uint256[] storage betIndices = userBetIds[marketId][msg.sender];
        require(betIndices.length > 0, "No bets found");

        uint256 totalPayout = 0;

        for (uint256 i = 0; i < betIndices.length; i++) {
            Bet storage b = bets[marketId][betIndices[i]];
            if (b.claimed) continue;

            // INVALID outcome → everyone gets refund
            if (m.outcome == Outcome.Invalid) {
                b.claimed = true;
                totalPayout += b.amount;
                continue;
            }

            bool won = (m.outcome == Outcome.YES && b.isYes) ||
                       (m.outcome == Outcome.NO  && !b.isYes);

            if (won) {
                uint256 winnerPool = m.outcome == Outcome.YES ? m.yesPool : m.noPool;
                uint256 totalPool  = m.yesPool + m.noPool;

                // Proportional share of total pool
                uint256 gross = (b.amount * totalPool) / winnerPool;
                uint256 fee   = (gross * platformFeeBps) / 10_000;
                uint256 net   = gross - fee;

                accruedFees += fee;
                b.claimed = true;
                totalPayout += net;
            }
        }

        require(totalPayout > 0, "Nothing to claim");

        (bool success, ) = payable(msg.sender).call{value: totalPayout}("");
        require(success, "Transfer failed");

        emit Claimed(marketId, msg.sender, totalPayout);
    }

    // ─── Lock market (stop bets before resolution) ─────────────────

    function lockMarket(uint256 marketId)
        external
        onlyOwner
        marketExists(marketId)
    {
        require(markets[marketId].status == Status.Open, "Not open");
        markets[marketId].status = Status.Locked;
    }

    // ─── Owner: withdraw platform fees ────────────────────────────

    function withdrawFees() external onlyOwner {
        uint256 amount = accruedFees;
        require(amount > 0, "No fees");
        accruedFees = 0;
        (bool success, ) = payable(owner).call{value: amount}("");
        require(success, "Transfer failed");
        emit FeesWithdrawn(owner, amount);
    }

    function setFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Max fee 10%");
        platformFeeBps = newFeeBps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    // ─── Views ────────────────────────────────────────────────────

    function getMarket(uint256 marketId)
        external
        view
        marketExists(marketId)
        returns (Market memory)
    {
        return markets[marketId];
    }

    function getBets(uint256 marketId)
        external
        view
        marketExists(marketId)
        returns (Bet[] memory)
    {
        return bets[marketId];
    }

    function getUserBets(uint256 marketId, address user)
        external
        view
        returns (uint256[] memory indices, Bet[] memory userBets)
    {
        indices = userBetIds[marketId][user];
        userBets = new Bet[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            userBets[i] = bets[marketId][indices[i]];
        }
    }

    function getPayout(uint256 marketId, address user)
        external
        view
        marketExists(marketId)
        returns (uint256 expectedPayout)
    {
        Market storage m = markets[marketId];
        if (m.status != Status.Resolved) return 0;

        uint256[] storage indices = userBetIds[marketId][user];
        for (uint256 i = 0; i < indices.length; i++) {
            Bet storage b = bets[marketId][indices[i]];
            if (b.claimed) continue;

            if (m.outcome == Outcome.Invalid) {
                expectedPayout += b.amount;
                continue;
            }

            bool won = (m.outcome == Outcome.YES && b.isYes) ||
                       (m.outcome == Outcome.NO  && !b.isYes);

            if (won) {
                uint256 winnerPool = m.outcome == Outcome.YES ? m.yesPool : m.noPool;
                uint256 totalPool  = m.yesPool + m.noPool;
                uint256 gross = (b.amount * totalPool) / winnerPool;
                uint256 fee   = (gross * platformFeeBps) / 10_000;
                expectedPayout += gross - fee;
            }
        }
    }

    function totalPool(uint256 marketId)
        external
        view
        marketExists(marketId)
        returns (uint256)
    {
        return markets[marketId].yesPool + markets[marketId].noPool;
    }

    // Safety: reject plain ETH transfers
    receive() external payable { revert("Use placeBet()"); }
}
