package service

import (
	"fmt"

	"github.com/cryptolend/protocol-defi/internal/domain"
	"github.com/cryptolend/protocol-defi/internal/oracle"
	"github.com/cryptolend/protocol-defi/internal/repository"
	"github.com/cryptolend/protocol-defi/internal/risk"
	"github.com/google/uuid"
	"github.com/shopspring/decimal"
)

// CollateralService handles collateral deposits and withdrawals.
type CollateralService struct {
	store  *repository.InMemoryStore
	oracle *oracle.PriceOracle
	risk   *risk.Engine
}

// NewCollateralService creates a new service.
func NewCollateralService(store *repository.InMemoryStore, oracle *oracle.PriceOracle, riskEngine *risk.Engine) *CollateralService {
	return &CollateralService{store: store, oracle: oracle, risk: riskEngine}
}

// DepositRequest is the input for depositing collateral.
type DepositRequest struct {
	UserID uuid.UUID
	Asset  string
	Amount decimal.Decimal
}

// Deposit creates a new collateral position.
func (s *CollateralService) Deposit(req DepositRequest) (*domain.CollateralPosition, error) {
	if !s.store.IsFeatureEnabled("LENDING") {
		return nil, fmt.Errorf("deposits are currently paused")
	}

	if req.Amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("amount must be positive")
	}

	if req.Asset != "BTC" {
		return nil, fmt.Errorf("only BTC collateral is supported")
	}

	position := &domain.CollateralPosition{
		UserID: req.UserID,
		Asset:  req.Asset,
		Amount: req.Amount,
		Status: domain.PositionActive,
	}

	if err := s.store.CreatePosition(position); err != nil {
		return nil, fmt.Errorf("failed to create position: %w", err)
	}

	// Record transaction
	posID := position.ID
	priceFeed, _ := s.oracle.GetPrice(req.Asset)
	_ = s.store.RecordTransaction(&domain.Transaction{
		UserID:         req.UserID,
		PositionID:     &posID,
		Type:           domain.TxCollateralDeposit,
		Asset:          req.Asset,
		Amount:         req.Amount,
		AmountUSD:      req.Amount.Mul(priceFeed.PriceUSD),
		ReferencePrice: priceFeed.PriceUSD,
	})

	return position, nil
}

// Withdraw removes collateral if LTV remains safe.
func (s *CollateralService) Withdraw(positionID uuid.UUID, amount decimal.Decimal) (*domain.CollateralPosition, error) {
	if !s.store.IsFeatureEnabled("WITHDRAWAL") {
		return nil, fmt.Errorf("withdrawals are currently paused")
	}

	if amount.LessThanOrEqual(decimal.Zero) {
		return nil, fmt.Errorf("amount must be positive")
	}

	// Risk check: will withdrawal breach max LTV?
	if err := s.risk.ValidateWithdrawal(positionID, amount); err != nil {
		return nil, fmt.Errorf("withdrawal rejected: %w", err)
	}

	position, err := s.store.GetPosition(positionID)
	if err != nil {
		return nil, err
	}

	position.Amount = position.Amount.Sub(amount)
	if err := s.store.UpdatePosition(position); err != nil {
		return nil, err
	}

	// Record transaction
	posID := position.ID
	priceFeed, _ := s.oracle.GetPrice(position.Asset)
	_ = s.store.RecordTransaction(&domain.Transaction{
		UserID:         position.UserID,
		PositionID:     &posID,
		Type:           domain.TxCollateralWithdrawal,
		Asset:          position.Asset,
		Amount:         amount,
		AmountUSD:      amount.Mul(priceFeed.PriceUSD),
		ReferencePrice: priceFeed.PriceUSD,
	})

	return position, nil
}

// GetPositions returns all positions for a user.
func (s *CollateralService) GetPositions(userID uuid.UUID) ([]*domain.CollateralPosition, error) {
	return s.store.GetPositionsByUser(userID)
}

// GetPosition returns a single position.
func (s *CollateralService) GetPosition(id uuid.UUID) (*domain.CollateralPosition, error) {
	return s.store.GetPosition(id)
}
