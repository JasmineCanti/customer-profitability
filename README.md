# customer-profitability

## Domain model and profitability logic

This project calculates **customer profitability** for an automotive business: which customers and segments actually make money once all costs are counted, not just which ones generate the most revenue.

### Data model

| Table | Purpose |
|---|---|
| `customers` | One row per customer, with segment (private, business, fleet), region and dealer |
| `contracts` | Purchase, lease and service-plan agreements |
| `transactions` | Revenue and direct cost per sale, service, parts or financing event |
| `service_costs` | Costs attributable to one customer: warranty, dealer visits, financing risk |
| `dealers` | Dealer network, with a parent link for hierarchy roll-ups |
| `support_tickets` | One row per ticket; the driver used to allocate shared support cost |
| `cost_pools` | Monthly shared costs (such as the support team) that must be allocated |

The full DDL is in [`sql/schema.sql`](sql/schema.sql).

### Metric definitions

| Metric | Definition |
|---|---|
| **Revenue** | Sum of `transactions.amount` per customer |
| **Direct cost** | Sum of `transactions.direct_cost` per customer |
| **Service cost** | Sum of `service_costs.amount` per customer |
| **Allocated cost** | Share of the monthly shared support pool assigned to the customer (see below) |
| **Margin** | Revenue − direct cost − service cost − allocated cost |
| **Margin %** | Margin / revenue (undefined when revenue is zero) |
| **CLV (simple)** | Average annual margin × expected customer lifetime in years |

### Cost allocation rule

Shared costs, such as the support team's monthly cost, cannot be tied to a single customer, so they are allocated.

**Rule:** each month, the support cost pool is split across customers in proportion to the number of support tickets they opened that month.

```
allocated_cost(customer, month) = pool(month) × tickets(customer, month) / total_tickets(month)
```

**Why tickets:** they reflect actual support effort. Splitting by revenue would make large customers look more expensive regardless of how much support they use, which hides exactly the unprofitable high-maintenance customers this analysis is meant to find.

**Alternatives considered:**
- *Revenue share:* simple, but penalises big customers without evidence they cost more to serve.
- *Contract count:* ignores how much each contract is actually used.
- *Ticket handling time:* more accurate, but needs data not available in this dataset.

### Assumptions and limitations

- The data is **synthetic**, generated for this project. Absolute values are illustrative; the logic and architecture are the point.
- Only the support team pool is allocated. Other shared costs (marketing, overhead) are excluded.
- Months with no tickets receive no allocation, so that month's pool is not fully distributed. In production this would be handled explicitly (for example, falling back to revenue share).
- CLV uses a fixed expected lifetime rather than a churn model.
- The allocation rule should be validated with finance before real use.

### Worked example

Customer A in one month: revenue €1,000, direct cost €600, service cost €50, 4 of 100 tickets, support pool €5,000.

- Allocated cost = 5,000 × 4 / 100 = **€200**
- Margin = 1,000 − 600 − 50 − 200 = **€150**
- Margin % = 150 / 1,000 = **15%**
