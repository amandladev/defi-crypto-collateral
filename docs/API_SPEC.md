# API Specification — CryptoLend MVP

Base URL: `https://api.cryptolend.bank/v1`

## Authentication
All endpoints require `Authorization: Bearer <JWT>` header.
Admin endpoints require additional `X-Admin-Token` header.

---

## Endpoints

### Health
```
GET /health
Response: 200 { "status": "ok", "circuit_breaker": "active" }
```

### Users
```
POST   /users                    — Register new user
GET    /users/me                 — Get current user profile
```

### Collateral
```
POST   /collateral/deposit       — Deposit BTC as collateral
POST   /collateral/withdraw      — Withdraw collateral (if LTV-safe)
GET    /collateral/positions      — List all collateral positions
GET    /collateral/positions/:id  — Get specific position details
```

### Loans
```
POST   /loans                    — Request a new loan
POST   /loans/:id/repay          — Repay loan (partial or full)
GET    /loans                    — List all user loans
GET    /loans/:id                — Get loan details
GET    /loans/:id/ltv            — Get current LTV for loan
```

### Risk / LTV
```
GET    /risk/positions            — All positions with LTV status
GET    /risk/positions/:id        — Single position risk details
```

### Liquidation
```
GET    /liquidations              — List liquidation events (user)
GET    /liquidations/:id          — Liquidation event detail
```

### Price Oracle
```
GET    /oracle/prices             — Current prices for supported assets
GET    /oracle/prices/:asset      — Current price for specific asset
```

### Admin
```
POST   /admin/circuit-breaker     — Toggle circuit breaker
POST   /admin/pause-liquidations  — Pause/resume liquidation engine
POST   /admin/force-liquidate     — Manually trigger liquidation
GET    /admin/positions/at-risk   — All positions near liquidation
```

---

## Request/Response Examples

### POST /collateral/deposit
```json
Request:
{
  "asset": "BTC",
  "amount": "1.5",
  "source_address": "bc1q..."
}

Response: 201
{
  "id": "pos_abc123",
  "user_id": "usr_xyz",
  "asset": "BTC",
  "amount": "1.5",
  "value_usd": "63750.00",
  "status": "CONFIRMED",
  "created_at": "2026-03-17T10:00:00Z"
}
```

### POST /loans
```json
Request:
{
  "collateral_position_id": "pos_abc123",
  "requested_amount_usd": "25000.00",
  "currency": "USDC"
}

Response: 201
{
  "id": "loan_def456",
  "user_id": "usr_xyz",
  "collateral_position_id": "pos_abc123",
  "principal_usd": "25000.00",
  "interest_rate_annual": "0.05",
  "current_ltv": "0.3922",
  "ltv_status": "SAFE",
  "status": "ACTIVE",
  "disbursement_currency": "USDC",
  "created_at": "2026-03-17T10:05:00Z"
}
```

### POST /loans/:id/repay
```json
Request:
{
  "amount_usd": "10000.00"
}

Response: 200
{
  "loan_id": "loan_def456",
  "amount_repaid": "10000.00",
  "remaining_principal": "15000.00",
  "current_ltv": "0.2353",
  "ltv_status": "SAFE"
}
```

### GET /loans/:id/ltv
```json
Response: 200
{
  "loan_id": "loan_def456",
  "collateral_asset": "BTC",
  "collateral_amount": "1.5",
  "collateral_value_usd": "63750.00",
  "loan_outstanding_usd": "15000.00",
  "current_ltv": "0.2353",
  "max_ltv": "0.50",
  "liquidation_threshold": "0.70",
  "ltv_status": "SAFE",
  "price_updated_at": "2026-03-17T10:10:00Z"
}
```

### GET /liquidations/:id
```json
Response: 200
{
  "id": "liq_ghi789",
  "loan_id": "loan_def456",
  "trigger_ltv": "0.7150",
  "collateral_sold_btc": "1.5",
  "sale_price_usd": "35000.00",
  "sale_proceeds_usd": "52500.00",
  "debt_repaid_usd": "25000.00",
  "penalty_usd": "2500.00",
  "returned_to_user_usd": "25000.00",
  "status": "COMPLETED",
  "executed_at": "2026-03-17T11:00:00Z"
}
```
