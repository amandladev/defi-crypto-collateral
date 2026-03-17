package service

import (
	"fmt"

	"github.com/cryptolend/protocol-defi/internal/config"
	"github.com/cryptolend/protocol-defi/internal/domain"
	"github.com/cryptolend/protocol-defi/internal/oracle"
	"github.com/cryptolend/protocol-defi/internal/repository"
	"github.com/cryptolend/protocol-defi/internal/risk"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

// LoanService handles loan origination and repayment.
type LoanService struct {
	cfg    *config.Config
	store  *repository.InMemoryStore
	oracle *oracle.PriceOracle
	risk   *risk.Engine
}

// NewLoanService creates a new loan service.
func NewLoanService(cfg *config.Config, store *repository.InMemoryStore, oracle *oracle.PriceOracle, riskEngine *risk.Engine) *LoanService {
	return &LoanService{cfg: cfg, store: store, oracle: oracle, risk: riskEngine}
}

// LoanRequest is the input to request a new loan.
type LoanRequest struct {
	UserID               uuid.UUID
	CollateralPositionID uuid.UUID
	RequestedAmountUSD   decimal.Decimal
	Currency             string // "USDC" or "USD"
}

// RequestLoan originates a new loan against collateral.
func (s *LoanService) RequestLoan(req LoanRequest) (*domain.Loan, error) {
	if !s.store.IsFeatureEnabled("LENDING") {
		return nil, fmt.Errorf("lending is currently paused")
	}

	if req.RequestedAmountUSD.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("loan amount must be positive")
	}

	// Verify position belongs to user
	position, err := s.store.GetPosition(req.CollateralPositionID)
	if err != nil {
		return nil, fmt.Errorf("collateral position not found: %w", err)
	}
	if position.UserID != req.UserID {
		return nil, fmt.Errorf("position does not belong to user")
	}
	if position.Status != domain.PositionActive {
		return nil, fmt.Errorf("position is not active")
	}

	// Risk check: would this loan exceed max LTV?
	if err := s.risk.ValidateLoanRequest(req.CollateralPositionID, req.RequestedAmountUSD); err != nil {
		return nil, fmt.Errorf("loan rejected by risk engine: %w", err)
	}

	// Calculate initial LTV for snapshot
	priceFeed, ok := s.oracle.GetPrice(position.Asset)
	if !ok {
		return nil, fmt.Errorf("no price for %s", position.Asset)
	}

	collateralValue := position.Amount.Mul(priceFeed.PriceUSD)
	existingDebt := s.store.TotalOutstandingForPosition(req.CollateralPositionID)
	initialLTV := existingDebt.Add(req.RequestedAmountUSD).Div(collateralValue)

	currency := req.Currency
	if currency == "" {
		currency = "USDC"
	}

	loan := &domain.Loan{
		UserID:               req.UserID,
		CollateralPositionID: req.CollateralPositionID,
		PrincipalUSD:         req.RequestedAmountUSD,
		OutstandingUSD:       req.RequestedAmountUSD,
		InterestRateAnnual:   s.cfg.DefaultInterestRate,
		AccruedInterestUSD:   decimal.Zero,
		DisbursementCurrency: currency,
		Status:               domain.LoanActive,
		LTVSnapshot:          initialLTV.Round(6),
	}

	if err := s.store.CreateLoan(loan); err != nil {
		return nil, fmt.Errorf("failed to create loan: %w", err)
	}

	// Lock collateral
	position.LockedAmount = position.Amount
	_ = s.store.UpdatePosition(position)

	// Record disbursement transaction
	loanID := loan.ID
	_ = s.store.RecordTransaction(&domain.Transaction{
		UserID:         req.UserID,
		LoanID:         &loanID,
		Type:           domain.TxLoanDisbursement,
		Asset:          currency,
		Amount:         req.RequestedAmountUSD,
		AmountUSD:      req.RequestedAmountUSD,
		ReferencePrice: priceFeed.PriceUSD,
	})

	return loan, nil
}

// RepayRequest is the input to repay a loan.
type RepayRequest struct {
	UserID    uuid.UUID
	LoanID    uuid.UUID
	AmountUSD decimal.Decimal
}

// RepayResult is the output of a repayment.
type RepayResult struct {
	LoanID             uuid.UUID        `json:"loan_id"`
	AmountRepaid       decimal.Decimal  `json:"amount_repaid"`
	RemainingPrincipal decimal.Decimal  `json:"remaining_principal"`
	CurrentLTV         decimal.Decimal  `json:"current_ltv"`
	LTVStatus          domain.LTVStatus `json:"ltv_status"`
}

// Repay processes a loan repayment (partial or full).
func (s *LoanService) Repay(req RepayRequest) (*RepayResult, error) {
	if req.AmountUSD.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("repayment amount must be positive")
	}

	loan, err := s.store.GetLoan(req.LoanID)
	if err != nil {
		return nil, fmt.Errorf("loan not found: %w", err)
	}

	if loan.UserID != req.UserID {
		return nil, fmt.Errorf("loan does not belong to user")
	}

	if loan.Status != domain.LoanActive {
		return nil, fmt.Errorf("loan is not active (status: %s)", loan.Status)
	}

	totalOwed := loan.OutstandingUSD.Add(loan.AccruedInterestUSD)
	actualRepay := req.AmountUSD
	if actualRepay.GreaterThan(totalOwed) {
		actualRepay = totalOwed // Don't overpay
	}

	// Apply to interest first, then principal
	interestPayment := decimal.Min(actualRepay, loan.AccruedInterestUSD)
	principalPayment := actualRepay.Sub(interestPayment)

	loan.AccruedInterestUSD = loan.AccruedInterestUSD.Sub(interestPayment)
	loan.OutstandingUSD = loan.OutstandingUSD.Sub(principalPayment)

	if loan.OutstandingUSD.IsZero() && loan.AccruedInterestUSD.IsZero() {
		loan.Status = domain.LoanRepaid
		// Unlock collateral
		position, _ := s.store.GetPosition(loan.CollateralPositionID)
		if position != nil {
			position.LockedAmount = decimal.Zero
			_ = s.store.UpdatePosition(position)
		}
	}

	if err := s.store.UpdateLoan(loan); err != nil {
		return nil, fmt.Errorf("failed to update loan: %w", err)
	}

	// Record transaction
	loanID := loan.ID
	_ = s.store.RecordTransaction(&domain.Transaction{
		UserID:    req.UserID,
		LoanID:    &loanID,
		Type:      domain.TxLoanRepayment,
		Asset:     "USD",
		Amount:    actualRepay,
		AmountUSD: actualRepay,
	})

	// Recalculate LTV
	ltvResult, _ := s.risk.CalculateLTV(loan.ID)
	currentLTV := decimal.Zero
	ltvStatus := domain.LTVStatusSafe
	if ltvResult != nil {
		currentLTV = ltvResult.CurrentLTV
		ltvStatus = ltvResult.Status
	}

	return &RepayResult{
		LoanID:             loan.ID,
		AmountRepaid:       actualRepay.Round(2),
		RemainingPrincipal: loan.OutstandingUSD.Round(2),
		CurrentLTV:         currentLTV,
		LTVStatus:          ltvStatus,
	}, nil
}

// GetLoan returns a single loan.
func (s *LoanService) GetLoan(id uuid.UUID) (*domain.Loan, error) {
	return s.store.GetLoan(id)
}

// GetLoans returns all loans for a user.
func (s *LoanService) GetLoans(userID uuid.UUID) ([]*domain.Loan, error) {
	return s.store.GetLoansByUser(userID)
}
