# Example Flows — CryptoLend Protocol

## Flow 1: Healthy Loan Lifecycle

```
Timeline    Action                          LTV     Status
─────────────────────────────────────────────────────────────
t=0         User deposits 1.0 BTC           —       —
            BTC price: $42,500
            Collateral value: $42,500

t=1         User requests $15,000 loan      35.3%   SAFE ✅
            LTV = $15,000 / $42,500

t=2         BTC rises to $50,000            30.0%   SAFE ✅
            LTV = $15,000 / $50,000

t=3         User repays $5,000              20.0%   SAFE ✅
            LTV = $10,000 / $50,000

t=4         User repays remaining $10,000   0.0%    REPAID ✅
            Collateral unlocked
            User withdraws 1.0 BTC
```

### API Calls
```bash
# 1. Create user
curl -X POST http://localhost:8080/v1/users \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@bank.com","full_name":"Alice Smith"}'
# → {"id":"usr_abc123", ...}

# 2. Deposit collateral
curl -X POST http://localhost:8080/v1/collateral/deposit \
  -H "Content-Type: application/json" \
  -d '{"user_id":"usr_abc123","asset":"BTC","amount":"1.0"}'
# → {"id":"pos_xyz789", "amount":"1.0", "value_usd":"42500.00", ...}

# 3. Request loan
curl -X POST http://localhost:8080/v1/loans \
  -H "Content-Type: application/json" \
  -d '{"user_id":"usr_abc123","collateral_position_id":"pos_xyz789","requested_amount_usd":"15000.00","currency":"USDC"}'
# → {"id":"loan_def456", "current_ltv":"0.3529", "ltv_status":"SAFE", ...}

# 4. Check LTV
curl http://localhost:8080/v1/loans/loan_def456/ltv
# → {"current_ltv":"0.3529", "ltv_status":"SAFE", ...}

# 5. Repay
curl -X POST http://localhost:8080/v1/loans/loan_def456/repay \
  -H "Content-Type: application/json" \
  -d '{"user_id":"usr_abc123","amount_usd":"15000.00"}'
# → {"remaining_principal":"0.00", "ltv_status":"SAFE"}

# 6. Withdraw collateral
curl -X POST http://localhost:8080/v1/collateral/withdraw \
  -H "Content-Type: application/json" \
  -d '{"position_id":"pos_xyz789","amount":"1.0"}'
```

---

## Flow 2: Near-Liquidation & Recovery

```
Timeline    Action                          LTV     Status
─────────────────────────────────────────────────────────────
t=0         User deposits 1.0 BTC           —       —
            BTC price: $42,500

t=1         User requests $20,000 loan      47.1%   WARNING ⚠️
            LTV = $20,000 / $42,500

t=2         BTC drops to $35,000            57.1%   WARNING ⚠️
            LTV = $20,000 / $35,000
            → System sends WARNING notification

t=3         BTC drops to $32,000            62.5%   CRITICAL 🔴
            LTV = $20,000 / $32,000
            → System sends CRITICAL alert
            → "Add collateral or repay to avoid liquidation"

t=4         User repays $8,000              37.5%   SAFE ✅
            LTV = $12,000 / $32,000
            → Crisis averted!

t=5         BTC recovers to $40,000         30.0%   SAFE ✅
            LTV = $12,000 / $40,000
```

---

## Flow 3: Liquidation Event

```
Timeline    Action                          LTV     Status
─────────────────────────────────────────────────────────────
t=0         User deposits 1.5 BTC           —       —
            BTC price: $42,500
            Collateral value: $63,750

t=1         User requests $25,000 loan      39.2%   SAFE ✅
            LTV = $25,000 / $63,750

t=2         BTC drops to $30,000            55.6%   WARNING ⚠️
            Collateral value: $45,000
            LTV = $25,000 / $45,000

t=3         BTC crashes to $22,000          75.8%   LIQUIDATING 🚨
            Collateral value: $33,000
            LTV = $25,000 / $33,000
            → LTV exceeds 70% threshold!

            LIQUIDATION ENGINE ACTIVATES:
            ─────────────────────────────
            1. Mark position as LIQUIDATING
            2. Sell 1.5 BTC at $22,000 (- 0.5% slippage)
               Sale price: $21,890/BTC
               Proceeds: $32,835.00

            3. Calculate amounts:
               Outstanding debt:     $25,000.00
               Penalty (10%):        $ 2,500.00
               Total owed:           $27,500.00

            4. Distribute:
               Debt repaid:          $25,000.00
               Penalty collected:    $ 2,500.00
               Returned to user:     $ 5,335.00  ← excess

            5. Update statuses:
               Loan:     ACTIVE → LIQUIDATED
               Position: ACTIVE → LIQUIDATED

t=4         User receives $5,335.00 (excess after debt + penalty)
```

### Liquidation Event Record
```json
{
  "id": "liq_ghi789",
  "loan_id": "loan_def456",
  "trigger_ltv": "0.7576",
  "collateral_amount": "1.5",
  "sale_price_usd": "21890.00",
  "sale_proceeds_usd": "32835.00",
  "debt_repaid_usd": "25000.00",
  "penalty_usd": "2500.00",
  "returned_to_user_usd": "5335.00",
  "status": "COMPLETED",
  "executed_at": "2026-03-17T11:00:00Z"
}
```

---

## Flow 4: Admin Circuit Breaker

```bash
# Pause all liquidations (e.g., during flash crash investigation)
curl -X POST http://localhost:8080/v1/admin/circuit-breaker \
  -H "Content-Type: application/json" \
  -d '{"feature":"LIQUIDATION","enabled":false}'

# Resume liquidations
curl -X POST http://localhost:8080/v1/admin/circuit-breaker \
  -H "Content-Type: application/json" \
  -d '{"feature":"LIQUIDATION","enabled":true}'

# Override BTC price manually (e.g., oracle failure)
curl -X POST http://localhost:8080/v1/admin/set-price \
  -H "Content-Type: application/json" \
  -d '{"asset":"BTC","price_usd":"42000.00"}'
```

---

## LTV Calculation Pseudocode

```
function calculateLTV(loan):
    position = getPosition(loan.collateral_position_id)
    price    = oracle.getPrice(position.asset)

    total_debt       = loan.outstanding_usd + loan.accrued_interest_usd
    collateral_value = position.amount × price.price_usd

    if collateral_value == 0:
        return LTV_INFINITE  // force liquidation

    ltv = total_debt / collateral_value

    status = match ltv:
        >= 0.70 → LIQUIDATING
        >= 0.60 → CRITICAL
        >= 0.40 → WARNING
        < 0.40  → SAFE

    return { ltv, status, collateral_value, total_debt }
```

## Liquidation Trigger Pseudocode

```
function scanAndLiquidate():
    if circuit_breaker("LIQUIDATION") == OPEN:
        return  // skip scan

    for loan in getAllActiveLoans():
        ltv_result = calculateLTV(loan)

        if ltv_result.status == LIQUIDATING:
            // Idempotency check
            idempotency_key = "liq_" + loan.id + "_" + timestamp_ms()
            if liquidation_exists(idempotency_key):
                continue

            // Execute liquidation
            position  = getPosition(loan.collateral_position_id)
            price     = oracle.getPrice(position.asset)

            sale_price = price × (1 - slippage_bps / 10000)
            proceeds   = position.amount × sale_price

            total_debt = loan.outstanding + loan.accrued_interest
            penalty    = total_debt × PENALTY_RATE

            if proceeds >= total_debt + penalty:
                returned_to_user = proceeds - total_debt - penalty
            else if proceeds >= total_debt:
                penalty = proceeds - total_debt
                returned_to_user = 0
            else:
                debt_repaid = proceeds
                penalty = 0
                returned_to_user = 0

            // Persist
            createLiquidationEvent(...)
            updateLoanStatus(loan, LIQUIDATED)
            updatePositionStatus(position, LIQUIDATED)
            recordTransactions(sale, penalty, return)
```
