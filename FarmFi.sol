// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FarmFi
 * @notice Decentralized micro-lending and savings protocol for smallholder farmers on Botchain
 * @dev Farmers stake crops as collateral; lenders earn yield; protocol manages repayment
 */
contract FarmFi {

    // ─── Enums ────────────────────────────────────────────────────────────────
    enum LoanStatus  { Active, Repaid, Defaulted, Liquidated }
    enum SeasonPhase { Planting, Growing, Harvest, PostHarvest }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct FarmerProfile {
        address wallet;
        string  name;
        string  region;
        uint256 creditScore;      // 0 – 1000
        uint256 totalBorrowed;
        uint256 totalRepaid;
        uint256 loansCount;
        uint256 activeLoans;
        bool    registered;
    }

    struct Loan {
        uint256 id;
        address farmer;
        uint256 principal;        // in wei
        uint256 interestBps;      // annualised basis points
        uint256 collateralValue;  // crop/asset collateral value in wei
        string  collateralDesc;
        uint256 startTime;
        uint256 dueDate;
        uint256 amountRepaid;
        LoanStatus status;
        SeasonPhase season;
    }

    struct LenderPosition {
        uint256 deposited;
        uint256 rewardDebt;
        uint256 depositTime;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public loanCounter;
    uint256 public totalPoolDeposits;
    uint256 public totalActiveLoans;
    uint256 public accRewardPerShare;     // accumulated reward per share (scaled 1e12)
    uint256 public constant BASE_INTEREST_BPS = 800;  // 8% annual base rate
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% collateral ratio
    uint256 public constant COLLATERAL_RATIO      = 150; // 150% min collateral

    mapping(address => FarmerProfile)   public farmers;
    mapping(uint256 => Loan)            public loans;
    mapping(address => LenderPosition)  public lenders;
    mapping(address => uint256[])       public farmerLoanIds;

    // ─── Events ───────────────────────────────────────────────────────────────
    event FarmerRegistered(address indexed farmer, string name);
    event Deposited(address indexed lender, uint256 amount);
    event Withdrawn(address indexed lender, uint256 amount, uint256 rewards);
    event LoanRequested(uint256 indexed loanId, address indexed farmer, uint256 amount, uint256 dueDate);
    event LoanRepaid(uint256 indexed loanId, address indexed farmer, uint256 amount);
    event LoanDefaulted(uint256 indexed loanId, address indexed farmer);
    event CreditScoreUpdated(address indexed farmer, uint256 newScore);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner()             { require(msg.sender == owner, "Not owner"); _; }
    modifier isFarmer(address _f)    { require(farmers[_f].registered, "Not registered"); _; }
    modifier loanExists(uint256 _id) { require(_id > 0 && _id <= loanCounter, "Loan not found"); _; }

    constructor() { owner = msg.sender; }

    // ─── Farmer Management ───────────────────────────────────────────────────
    function registerFarmer(string calldata _name, string calldata _region) external {
        require(!farmers[msg.sender].registered, "Already registered");
        farmers[msg.sender] = FarmerProfile({
            wallet:       msg.sender,
            name:         _name,
            region:       _region,
            creditScore:  500, // start at median
            totalBorrowed: 0,
            totalRepaid:  0,
            loansCount:   0,
            activeLoans:  0,
            registered:   true
        });
        emit FarmerRegistered(msg.sender, _name);
    }

    // ─── Lender Pool ─────────────────────────────────────────────────────────
    function deposit() external payable {
        require(msg.value > 0, "Zero deposit");
        LenderPosition storage pos = lenders[msg.sender];

        // Harvest pending rewards before updating
        _harvestRewards(msg.sender);

        pos.deposited   += msg.value;
        pos.depositTime  = block.timestamp;
        pos.rewardDebt   = (pos.deposited * accRewardPerShare) / 1e12;
        totalPoolDeposits += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external {
        LenderPosition storage pos = lenders[msg.sender];
        require(pos.deposited >= _amount, "Insufficient deposit");

        uint256 rewards = _pendingRewards(msg.sender);
        pos.deposited   -= _amount;
        pos.rewardDebt   = (pos.deposited * accRewardPerShare) / 1e12;
        totalPoolDeposits -= _amount;

        uint256 payout = _amount + rewards;
        require(address(this).balance >= payout, "Pool illiquid");

        (bool sent,) = payable(msg.sender).call{value: payout}("");
        require(sent, "Transfer failed");
        emit Withdrawn(msg.sender, _amount, rewards);
    }

    function pendingRewards(address _lender) external view returns (uint256) {
        return _pendingRewards(_lender);
    }

    // ─── Lending ─────────────────────────────────────────────────────────────
    function requestLoan(
        uint256 _amount,
        uint256 _durationDays,
        string calldata _collateralDesc,
        uint256 _collateralValueWei,
        SeasonPhase _season
    ) external isFarmer(msg.sender) returns (uint256) {
        require(_amount > 0, "Zero amount");
        require(_durationDays >= 30 && _durationDays <= 365, "Duration 30-365 days");
        require(farmers[msg.sender].activeLoans < 2, "Max 2 active loans");

        // 150% collateral ratio
        require(_collateralValueWei >= (_amount * COLLATERAL_RATIO) / 100, "Insufficient collateral");
        require(totalPoolDeposits >= totalActiveLoans + _amount, "Pool insufficient");

        uint256 adjustedInterest = _adjustedInterestBps(msg.sender);

        loanCounter++;
        loans[loanCounter] = Loan({
            id:               loanCounter,
            farmer:           msg.sender,
            principal:        _amount,
            interestBps:      adjustedInterest,
            collateralValue:  _collateralValueWei,
            collateralDesc:   _collateralDesc,
            startTime:        block.timestamp,
            dueDate:          block.timestamp + (_durationDays * 1 days),
            amountRepaid:     0,
            status:           LoanStatus.Active,
            season:           _season
        });

        farmers[msg.sender].loansCount++;
        farmers[msg.sender].activeLoans++;
        farmers[msg.sender].totalBorrowed += _amount;
        farmerLoanIds[msg.sender].push(loanCounter);
        totalActiveLoans += _amount;

        (bool sent,) = payable(msg.sender).call{value: _amount}("");
        require(sent, "Disbursement failed");

        emit LoanRequested(loanCounter, msg.sender, _amount, block.timestamp + (_durationDays * 1 days));
        return loanCounter;
    }

    function repayLoan(uint256 _loanId) external payable loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.farmer == msg.sender, "Not your loan");
        require(loan.status == LoanStatus.Active, "Loan not active");

        uint256 totalOwed = _loanOwed(_loanId);
        require(msg.value >= totalOwed, "Underpayment");

        loan.amountRepaid = totalOwed;
        loan.status       = LoanStatus.Repaid;

        farmers[msg.sender].totalRepaid  += totalOwed;
        farmers[msg.sender].activeLoans  -= 1;
        totalActiveLoans                 -= loan.principal;

        // Update credit score positively (max 1000)
        uint256 cs = farmers[msg.sender].creditScore;
        farmers[msg.sender].creditScore = cs + 20 > 1000 ? 1000 : cs + 20;

        // Distribute interest to pool (approximate accRewardPerShare update)
        uint256 interest = totalOwed - loan.principal;
        if (totalPoolDeposits > 0) {
            accRewardPerShare += (interest * 1e12) / totalPoolDeposits;
        }

        // Refund excess
        if (msg.value > totalOwed) {
            (bool refund,) = payable(msg.sender).call{value: msg.value - totalOwed}("");
            require(refund, "Refund failed");
        }

        emit LoanRepaid(_loanId, msg.sender, totalOwed);
        emit CreditScoreUpdated(msg.sender, farmers[msg.sender].creditScore);
    }

    function markDefault(uint256 _loanId) external onlyOwner loanExists(_loanId) {
        Loan storage loan = loans[_loanId];
        require(loan.status == LoanStatus.Active, "Not active");
        require(block.timestamp > loan.dueDate, "Not overdue");

        loan.status = LoanStatus.Defaulted;
        farmers[loan.farmer].activeLoans -= 1;
        totalActiveLoans -= loan.principal;

        // Penalise credit score
        uint256 cs = farmers[loan.farmer].creditScore;
        farmers[loan.farmer].creditScore = cs > 100 ? cs - 100 : 0;

        emit LoanDefaulted(_loanId, loan.farmer);
        emit CreditScoreUpdated(loan.farmer, farmers[loan.farmer].creditScore);
    }

    // ─── Views ───────────────────────────────────────────────────────────────
    function loanOwed(uint256 _loanId) external view loanExists(_loanId) returns (uint256) {
        return _loanOwed(_loanId);
    }

    function getFarmerLoans(address _farmer) external view returns (uint256[] memory) {
        return farmerLoanIds[_farmer];
    }

    // ─── Internals ───────────────────────────────────────────────────────────
    function _loanOwed(uint256 _id) internal view returns (uint256) {
        Loan storage l = loans[_id];
        uint256 elapsed = block.timestamp - l.startTime;
        uint256 interest = (l.principal * l.interestBps * elapsed) / (10000 * 365 days);
        return l.principal + interest;
    }

    function _adjustedInterestBps(address _farmer) internal view returns (uint256) {
        uint256 score = farmers[_farmer].creditScore;
        if (score >= 800) return BASE_INTEREST_BPS - 200; // 6%
        if (score >= 600) return BASE_INTEREST_BPS;       // 8%
        if (score >= 400) return BASE_INTEREST_BPS + 200; // 10%
        return BASE_INTEREST_BPS + 400;                   // 12%
    }

    function _pendingRewards(address _lender) internal view returns (uint256) {
        LenderPosition storage pos = lenders[_lender];
        return (pos.deposited * accRewardPerShare) / 1e12 - pos.rewardDebt;
    }

    function _harvestRewards(address _lender) internal {
        uint256 pending = _pendingRewards(_lender);
        if (pending > 0 && address(this).balance >= pending) {
            lenders[_lender].rewardDebt = (lenders[_lender].deposited * accRewardPerShare) / 1e12;
        }
    }

    receive() external payable {}
}
