-- CryptoLend MVP — Database Schema
-- PostgreSQL 15+

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) NOT NULL UNIQUE,
    full_name       VARCHAR(255) NOT NULL,
    kyc_status      VARCHAR(20)  NOT NULL DEFAULT 'PENDING'
                    CHECK (kyc_status IN ('PENDING','APPROVED','REJECTED')),
    status          VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_email ON users(email);

-- ============================================================
-- WALLETS (custodial addresses per user per asset)
-- ============================================================
CREATE TABLE wallets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         NOT NULL REFERENCES users(id),
    asset           VARCHAR(10)  NOT NULL,  -- 'BTC', 'ETH', etc.
    address         VARCHAR(255) NOT NULL,
    balance         NUMERIC(28,18) NOT NULL DEFAULT 0
                    CHECK (balance >= 0),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE(user_id, asset)
);

-- ============================================================
-- COLLATERAL POSITIONS
-- ============================================================
CREATE TABLE collateral_positions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         NOT NULL REFERENCES users(id),
    asset           VARCHAR(10)  NOT NULL DEFAULT 'BTC',
    amount          NUMERIC(28,18) NOT NULL CHECK (amount >= 0),
    locked_amount   NUMERIC(28,18) NOT NULL DEFAULT 0 CHECK (locked_amount >= 0),
    status          VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','LIQUIDATING','LIQUIDATED','CLOSED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_collateral_user ON collateral_positions(user_id);
CREATE INDEX idx_collateral_status ON collateral_positions(status);

-- ============================================================
-- LOANS
-- ============================================================
CREATE TABLE loans (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID         NOT NULL REFERENCES users(id),
    collateral_position_id  UUID         NOT NULL REFERENCES collateral_positions(id),
    principal_usd           NUMERIC(20,2) NOT NULL CHECK (principal_usd > 0),
    outstanding_usd         NUMERIC(20,2) NOT NULL CHECK (outstanding_usd >= 0),
    interest_rate_annual    NUMERIC(8,6)  NOT NULL DEFAULT 0.050000,
    accrued_interest_usd    NUMERIC(20,2) NOT NULL DEFAULT 0,
    disbursement_currency   VARCHAR(10)  NOT NULL DEFAULT 'USDC',
    status                  VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE','REPAID','LIQUIDATED','DEFAULTED')),
    ltv_snapshot            NUMERIC(8,6),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_loans_user ON loans(user_id);
CREATE INDEX idx_loans_collateral ON loans(collateral_position_id);
CREATE INDEX idx_loans_status ON loans(status);

-- ============================================================
-- TRANSACTIONS (audit trail)
-- ============================================================
CREATE TABLE transactions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         NOT NULL REFERENCES users(id),
    loan_id         UUID         REFERENCES loans(id),
    position_id     UUID         REFERENCES collateral_positions(id),
    type            VARCHAR(30)  NOT NULL
                    CHECK (type IN (
                        'COLLATERAL_DEPOSIT','COLLATERAL_WITHDRAWAL',
                        'LOAN_DISBURSEMENT','LOAN_REPAYMENT',
                        'LIQUIDATION_SALE','LIQUIDATION_PENALTY',
                        'LIQUIDATION_RETURN','INTEREST_ACCRUAL'
                    )),
    asset           VARCHAR(10)  NOT NULL,
    amount          NUMERIC(28,18) NOT NULL,
    amount_usd      NUMERIC(20,2),
    reference_price NUMERIC(20,2),
    metadata        JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_tx_user ON transactions(user_id);
CREATE INDEX idx_tx_loan ON transactions(loan_id);
CREATE INDEX idx_tx_type ON transactions(type);
CREATE INDEX idx_tx_created ON transactions(created_at);

-- ============================================================
-- PRICE FEEDS
-- ============================================================
CREATE TABLE price_feeds (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset           VARCHAR(10)  NOT NULL,
    price_usd       NUMERIC(20,2) NOT NULL CHECK (price_usd > 0),
    source          VARCHAR(50)  NOT NULL DEFAULT 'MOCK_ORACLE',
    timestamp       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX idx_price_asset_ts ON price_feeds(asset, timestamp DESC);

-- ============================================================
-- LIQUIDATION EVENTS
-- ============================================================
CREATE TABLE liquidation_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    loan_id             UUID         NOT NULL REFERENCES loans(id),
    collateral_position_id UUID      NOT NULL REFERENCES collateral_positions(id),
    trigger_ltv         NUMERIC(8,6) NOT NULL,
    collateral_amount   NUMERIC(28,18) NOT NULL,
    sale_price_usd      NUMERIC(20,2) NOT NULL,
    sale_proceeds_usd   NUMERIC(20,2) NOT NULL,
    debt_repaid_usd     NUMERIC(20,2) NOT NULL,
    penalty_usd         NUMERIC(20,2) NOT NULL,
    returned_to_user_usd NUMERIC(20,2) NOT NULL DEFAULT 0,
    status              VARCHAR(20)  NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','EXECUTING','COMPLETED','FAILED')),
    idempotency_key     VARCHAR(255) NOT NULL UNIQUE,
    error_message       TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ
);

CREATE INDEX idx_liq_loan ON liquidation_events(loan_id);
CREATE INDEX idx_liq_status ON liquidation_events(status);

-- ============================================================
-- CIRCUIT BREAKER STATE
-- ============================================================
CREATE TABLE circuit_breaker (
    id              SERIAL PRIMARY KEY,
    feature         VARCHAR(50)  NOT NULL UNIQUE,  -- 'LENDING', 'LIQUIDATION', 'WITHDRAWAL'
    enabled         BOOLEAN      NOT NULL DEFAULT TRUE,
    reason          TEXT,
    toggled_by      UUID         REFERENCES users(id),
    toggled_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

INSERT INTO circuit_breaker (feature, enabled) VALUES
    ('LENDING', TRUE),
    ('LIQUIDATION', TRUE),
    ('WITHDRAWAL', TRUE);
