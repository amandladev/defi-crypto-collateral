package service

import (
	"github.com/cryptolend/protocol-defi/internal/domain"
	"github.com/cryptolend/protocol-defi/internal/repository"
	"github.com/google/uuid"
)

// UserService manages user accounts.
type UserService struct {
	store *repository.InMemoryStore
}

// NewUserService creates a new user service.
func NewUserService(store *repository.InMemoryStore) *UserService {
	return &UserService{store: store}
}

// CreateUser registers a new user.
func (s *UserService) CreateUser(email, fullName string) (*domain.User, error) {
	user := &domain.User{
		Email:     email,
		FullName:  fullName,
		KYCStatus: domain.KYCPending,
		Status:    "ACTIVE",
	}
	if err := s.store.CreateUser(user); err != nil {
		return nil, err
	}
	return user, nil
}

// GetUser retrieves a user by ID.
func (s *UserService) GetUser(id uuid.UUID) (*domain.User, error) {
	return s.store.GetUser(id)
}
