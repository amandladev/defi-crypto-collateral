# CryptoLend — Crypto-Collateralized Lending Protocol (MVP)

A production-oriented MVP for a **bank-operated crypto lending platform** where users deposit BTC as collateral and receive loans in fiat/stablecoin, with automated liquidation when collateral value drops.

## Quick Start

```bash
# Run the API server
go run ./cmd/api

# In another terminal, test the flow:
# 1. Create user
curl -s -X POST http://localhost:8080/v1/users \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@bank.com","full_name":"Alice Smith"}' | jq .

# 2. Deposit 1.5 BTC
curl -s -X POST http://localhost:8080/v1/collateral/deposit \
  -H "Content-Type: application/json" \
  -d '{"user_id":"<USER_ID>","asset":"BTC","amount":"1.5"}' | jq .

# 3. Request $25,000 loan
curl -s -X POST http://localhost:8080/v1/loans \
  -H "Content-Type: application/json" \
  -d '{"user_id":"<USER_ID>","collateral_position_id":"<POS_ID>","requested_amount_usd":"25000","currency":"USDC"}' | jq .

# 4. Check LTV
curl -s http://localhost:8080/v1/loans/<LOAN_ID>/ltv | jq .

# 5. Check oracle prices
curl -s http://localhost:8080/v1/oracle/prices | jq .
```

## Project Structure

```
protocolo DeFI/
├── cmd/
│   ├── api/                    # HTTP API server
│   │   └── main.go
│   └── liquidator/             # Standalone liquidation worker
│       └── main.go
├── internal/
│   ├── domain/                 # Core domain models
│   │   └── models.go
│   ├── config/                 # Configuration
│   │   └── config.go
│   ├── service/                # Business logic
│   │   ├── collateral.go       # Collateral deposits/withdrawals
│   │   ├── loan.go             # Loan origination/repayment
│   │   ├── liquidation.go      # Liquidation engine
│   │   └── user.go             # User management
│   ├── handler/                # HTTP handlers
│   │   └── handler.go
│   ├── repository/             # Data persistence
│   │   └── store.go            # In-memory store (swap for PostgreSQL)
│   ├── oracle/                 # Price oracle
│   │   └── oracle.go           # Mock price feed
│   ├── risk/                   # Risk engine
│   │   ├── engine.go           # LTV calculation + validation
│   │   └── engine_test.go      # Risk engine tests
│   └── middleware/             # HTTP middleware
│       └── middleware.go       # Rate limiter, logging, recovery
├── migrations/
│   └── 001_initial_schema.sql  # PostgreSQL schema
├── contracts/
│   └── CollateralVault.sol     # Optional Solidity contract
├── infra/
│   └── lib/
│       └── cryptolend-stack.ts # AWS CDK infrastructure
├── docs/
│   ├── ARCHITECTURE.md         # System architecture
│   ├── API_SPEC.md             # API specification
│   └── EXAMPLE_FLOWS.md        # Example flows with pseudocode
├── Dockerfile
├── go.mod
└── README.md
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system design.

**Key components:**
- **Risk Engine** — Continuously calculates LTV ratios and classifies position health
- **Liquidation Engine** — Monitors positions and executes idempotent liquidations
- **Price Oracle** — Simulates market prices (pluggable for Chainlink/CoinGecko)
- **Circuit Breakers** — Admin-controlled kill switches for lending/liquidation/withdrawals

## Risk Parameters

| Parameter              | Default | Description                        |
|------------------------|---------|------------------------------------|
| Max LTV                | 50%     | Maximum LTV at loan origination    |
| Warning Threshold      | 40%     | LTV triggers WARNING status        |
| Critical Threshold     | 60%     | LTV triggers CRITICAL status       |
| Liquidation Threshold  | 70%     | LTV triggers automatic liquidation |
| Liquidation Penalty    | 10%     | Penalty on liquidated debt         |
| Slippage               | 0.5%    | Simulated market slippage          |

## API Endpoints

See [docs/API_SPEC.md](docs/API_SPEC.md) for full specification.

| Method | Endpoint                     | Description              |
|--------|------------------------------|--------------------------|
| POST   | /v1/collateral/deposit       | Deposit BTC collateral   |
| POST   | /v1/collateral/withdraw      | Withdraw collateral      |
| POST   | /v1/loans                    | Request new loan         |
| POST   | /v1/loans/:id/repay          | Repay loan               |
| GET    | /v1/loans/:id/ltv            | Get current LTV          |
| GET    | /v1/risk/positions           | At-risk positions        |
| GET    | /v1/oracle/prices            | Current asset prices     |
| POST   | /v1/admin/circuit-breaker    | Toggle circuit breaker   |

## Running Tests

```bash
go test ./internal/risk/ -v
```

## Infrastructure

The `infra/` directory contains AWS CDK (TypeScript) that provisions:
- VPC with public/private/isolated subnets
- ECS Fargate services (API + Liquidator)
- RDS PostgreSQL
- SQS queues with DLQ
- EventBridge for event routing
- CloudWatch alarms

```bash
cd infra && npm install && npx cdk synth
```

## DeFi Integration Roadmap

This MVP can evolve to integrate with DeFi protocols:

1. **Aave/Spark Integration** — Deposit idle stablecoin reserves into Aave/Spark
   lending pools for yield optimization while maintaining withdrawal liquidity.

2. **Chainlink Oracles** — Replace mock oracle with Chainlink price feeds for
   tamper-proof, decentralized pricing.

3. **On-Chain Collateral** — Deploy the `CollateralVault.sol` contract to hold
   WBTC on-chain, enabling transparent proof of reserves.

4. **Cross-Chain Lending** — Use LayerZero or Wormhole to accept collateral on
   multiple chains (Ethereum, Arbitrum, Base).

5. **Tokenized Loan Positions** — Mint NFTs representing loan positions, enabling
   secondary market trading of bank-originated loans.

6. **Liquidity Optimization** — Rehypothecate a portion of collateral into DeFi
   yield strategies (e.g., Pendle, Ethena) with strict risk limits.

## License

Proprietary — AmandlaDev
