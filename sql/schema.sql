-- =====================================================================
-- Customer profitability: data model (Databricks SQL / Unity Catalog)
-- =====================================================================

USE CATALOG main;
CREATE SCHEMA IF NOT EXISTS profitability;
USE SCHEMA profitability;

-- ---------------------------------------------------------------------
-- 1. dealers
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dealers (
  dealer_id        BIGINT      NOT NULL,
  dealer_name      STRING      NOT NULL,
  region           STRING,
  parent_dealer_id BIGINT,                 -- for the recursive CTE hierarchy drill
  CONSTRAINT dealers_pk PRIMARY KEY (dealer_id)
) USING DELTA
COMMENT 'Dealer network. parent_dealer_id enables hierarchy roll-ups.';

-- ---------------------------------------------------------------------
-- 2. customers
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS customers (
  customer_id BIGINT NOT NULL,
  full_name   STRING NOT NULL,
  segment     STRING NOT NULL,             -- private | business | fleet
  region      STRING,
  dealer_id   BIGINT,
  join_date   DATE   NOT NULL,
  CONSTRAINT customers_pk PRIMARY KEY (customer_id),
  CONSTRAINT customers_dealer_fk FOREIGN KEY (dealer_id) REFERENCES dealers (dealer_id)
) USING DELTA
COMMENT 'One row per customer. segment drives profitability comparisons.';

-- ---------------------------------------------------------------------
-- 3. contracts
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contracts (
  contract_id BIGINT NOT NULL,
  customer_id BIGINT NOT NULL,
  product     STRING NOT NULL,             -- purchase | lease | service_plan
  start_date  DATE   NOT NULL,
  end_date    DATE,                        -- NULL = still active
  CONSTRAINT contracts_pk PRIMARY KEY (contract_id),
  CONSTRAINT contracts_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) USING DELTA
COMMENT 'Commercial agreements per customer.';

-- ---------------------------------------------------------------------
-- 4. transactions  (revenue and direct cost live here)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
  transaction_id   BIGINT         NOT NULL,
  customer_id      BIGINT         NOT NULL,
  contract_id      BIGINT,
  transaction_date DATE           NOT NULL,
  transaction_type STRING         NOT NULL,
  amount           DECIMAL(12,2)  NOT NULL, -- revenue
  direct_cost      DECIMAL(12,2)  NOT NULL, -- cost of goods / labour for this transaction
  CONSTRAINT transactions_pk PRIMARY KEY (transaction_id),
  CONSTRAINT transactions_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) USING DELTA
CLUSTER BY (customer_id, transaction_date)
COMMENT 'Revenue and direct cost per transaction. Liquid clustering on customer and date.';

-- ---------------------------------------------------------------------
-- 5. service_costs  (direct, attributable costs after the sale)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS service_costs (
  cost_id     BIGINT        NOT NULL,
  customer_id BIGINT        NOT NULL,
  cost_date   DATE          NOT NULL,
  cost_type   STRING        NOT NULL,      -- warranty | dealer_visit | financing_risk
  amount      DECIMAL(12,2) NOT NULL,
  CONSTRAINT service_costs_pk PRIMARY KEY (cost_id),
  CONSTRAINT service_costs_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) USING DELTA
COMMENT 'Costs that can be tied directly to one customer.';

-- ---------------------------------------------------------------------
-- Two small helper tables that make the allocation rule work:
-- shared costs (a support team) cannot be tied to one customer,
-- so we allocate a monthly pool by ticket share.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS support_tickets (
  ticket_id   BIGINT    NOT NULL,
  customer_id BIGINT    NOT NULL,
  opened_at   TIMESTAMP NOT NULL,
  category    STRING,
  CONSTRAINT support_tickets_pk PRIMARY KEY (ticket_id),
  CONSTRAINT support_tickets_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) USING DELTA
COMMENT 'One row per support ticket. Used as the allocation driver.';

CREATE TABLE IF NOT EXISTS cost_pools (
  month_start DATE          NOT NULL,
  pool_name   STRING        NOT NULL,      -- e.g. support_team
  amount      DECIMAL(14,2) NOT NULL,
  CONSTRAINT cost_pools_pk PRIMARY KEY (month_start, pool_name)
) USING DELTA
COMMENT 'Shared monthly costs to be allocated to customers.';

-- ---------------------------------------------------------------------
-- Starting point for the Day 1 profitability query.
-- Each source is aggregated BEFORE joining, so rows never multiply
-- (the classic cause of inflated revenue and wrong margins).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_profitability AS
WITH revenue AS (
  SELECT customer_id,
         SUM(amount)      AS revenue,
         SUM(direct_cost) AS direct_cost
  FROM transactions
  GROUP BY customer_id
),
service AS (
  SELECT customer_id, 
         SUM(amount) AS service_cost
  FROM service_costs
  GROUP BY customer_id
),
tickets_month AS (
  SELECT customer_id,
         DATE_TRUNC('month', opened_at) AS month_start,
         COUNT(*) AS tickets
  FROM support_tickets
  GROUP BY customer_id, DATE_TRUNC('month', opened_at)
),
allocated AS (
  SELECT t.customer_id,
         SUM(p.amount * t.tickets
             / SUM(t.tickets) OVER (PARTITION BY t.month_start)) AS allocated_support_cost
  FROM tickets_month t
  JOIN cost_pools p
    ON p.month_start = t.month_start AND p.pool_name = 'support_team'
  GROUP BY t.customer_id
)
SELECT c.customer_id,
       c.segment,
       COALESCE(r.revenue, 0)                AS revenue,
       COALESCE(r.direct_cost, 0)            AS direct_cost,
       COALESCE(s.service_cost, 0)           AS service_cost,
       COALESCE(a.allocated_support_cost, 0) AS allocated_cost,
       COALESCE(r.revenue, 0) - COALESCE(r.direct_cost, 0)
         - COALESCE(s.service_cost, 0) - COALESCE(a.allocated_support_cost, 0) AS margin,
       CASE WHEN COALESCE(r.revenue, 0) = 0 THEN NULL
            ELSE (COALESCE(r.revenue, 0) - COALESCE(r.direct_cost, 0)
                  - COALESCE(s.service_cost, 0) - COALESCE(a.allocated_support_cost, 0))
                 / r.revenue END             AS margin_pct
FROM customers c
LEFT JOIN revenue   r ON r.customer_id = c.customer_id
LEFT JOIN service   s ON s.customer_id = c.customer_id
LEFT JOIN allocated a ON a.customer_id = c.customer_id;
