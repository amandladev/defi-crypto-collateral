# CryptoLend — Crypto-Collateralized Lending Platform (MVP)

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          CLIENT LAYER                                   │
│   Web App / Mobile App / Admin Dashboard                                │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ HTTPS
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      AWS API GATEWAY                                    │
│   Rate Limiting · Auth (JWT/Cognito) · WAF                              │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER (ECS/Lambda)                       │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │  User &      │  │  Collateral  │  │    Loan      │                  │
│  │  Account     │  │  Management  │  │   Service    │                  │
│  │  Service     │  │  Service     │  │              │                  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                  │
│         │                 │                  │                          │
│  ┌──────┴─────────────────┴──────────────────┴───────┐                 │
│  │              RISK ENGINE (Core)                    │                 │
│  │   LTV Calculator · Liquidation Rules · Buffers     │                 │
│  └──────────────────────┬────────────────────────────┘                 │
│                         │                                               │
│  ┌──────────────┐  ┌───┴──────────┐  ┌──────────────┐                 │
│  │   Price      │  │  Liquidation │  │   Circuit    │                 │
│  │   Oracle     │  │   Engine     │  │   Breaker    │                 │
│  │   Service    │  │   (Worker)   │  │   Service    │                 │
│  └──────────────┘  └──────────────┘  └──────────────┘                 │
└─────────────────────────────┬───────────────────────────────────────────┘
                              │
           ┌──────────────────┼──────────────────┐
           ▼                  ▼                  ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│   PostgreSQL   │  │   SQS/Event    │  │   CloudWatch   │
│   (RDS)        │  │   Bridge       │  │   + Alarms     │
│                │  │                │  │                │
│  Users         │  │  LiquidationQ  │  │  LTV Metrics   │
│  Wallets       │  │  PriceUpdateQ  │  │  Logs          │
│  Collateral    │  │  AuditEvents   │  │  Dashboards    │
│  Loans         │  │                │  │                │
│  Transactions  │  │                │  │                │
│  Price Feeds   │  │                │  │                │
└────────────────┘  └────────────────┘  └────────────────┘
```

## Service Responsibilities

### User & Account Service
- User registration, KYC status tracking
- Account management, API key provisioning

### Collateral Management Service
- Accept BTC deposits (custodial — bank holds keys)
- Track collateral positions per user
- Validate withdrawal requests against LTV safety

### Loan Service
- Issue loans against collateral
- Track loan principal, accrued interest, status
- Process repayments (partial/full)

### Risk Engine (LTV Calculator)
- Core formula: `LTV = Loan Outstanding / (Collateral Amount × Current Price)`
- Classify positions: SAFE → WARNING → CRITICAL → LIQUIDATING
- Emit events when thresholds are crossed

### Price Oracle Service
- Mock Chainlink-style price feed
- Poll external APIs (CoinGecko, Binance) or use mock data
- Publish price updates to event bus
- Support TWAP (Time-Weighted Average Price) for anti-manipulation

### Liquidation Engine
- Subscribe to CRITICAL LTV events
- Execute liquidation: sell collateral → repay loan → apply penalty → return excess
- Idempotent execution with state machine: PENDING → EXECUTING → COMPLETED/FAILED
- Dead-letter queue for failed liquidations

### Circuit Breaker Service
- Global pause for lending/liquidation
- Per-asset pause capability
- Admin manual override
- Automatic trigger on extreme price volatility

## Data Flow — Liquidation Event

```
Price Oracle detects BTC drop
        │
        ▼
Risk Engine recalculates all positions
        │
        ▼
Position LTV > 70% (threshold)
        │
        ▼
Emit LIQUIDATION_REQUIRED event → SQS
        │
        ▼
Liquidation Engine picks up event
        │
        ├─→ Check circuit breaker status
        ├─→ Verify position still needs liquidation (idempotency)
        ├─→ Mark position as LIQUIDATING
        ├─→ Simulate collateral sale at market price - slippage
        ├─→ Calculate: debt + penalty
        ├─→ Return excess to user
        └─→ Mark position as LIQUIDATED
```

## Technology Stack

| Component        | Technology              |
|------------------|------------------------|
| Language         | Go 1.22+               |
| API Framework    | Chi router             |
| Database         | PostgreSQL 15          |
| Migrations       | golang-migrate         |
| Infrastructure   | AWS CDK (TypeScript)   |
| Compute          | ECS Fargate / Lambda   |
| Queue            | Amazon SQS             |
| Events           | Amazon EventBridge     |
| Monitoring       | CloudWatch + Alarms    |
| Smart Contracts  | Solidity (optional)    |

## Security Considerations

- All API endpoints require JWT authentication
- Rate limiting at API Gateway level
- Database encryption at rest (RDS)
- Audit log for all financial operations
- Principle of least privilege (IAM roles)
- Input validation on all endpoints
- SQL injection prevention via parameterized queries
