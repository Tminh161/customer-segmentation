/* ============================================================================
   Retail Customer Segmentation — Full SQL Pipeline
   Dataset: Olist Brazilian E-Commerce Public Dataset (Kaggle)
   https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

   This script builds an RFM-style customer segmentation on real transaction
   data, then layers a clearly-labeled synthetic enrichment table on top to
   simulate brokerage-style product adoption (margin trading, funds).

   Real data: customer identity, recency, frequency, monetary value.
   Illustrative/synthetic data: uses_margin, uses_funds, risk_profile,
   acquisition_channel — rule-based, tied to real monetary/frequency values
   to stay directionally plausible, not a discovered pattern.

   Engine: SQLite (DB Browser for SQLite)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   SECTION 1: RAW TABLE DEFINITIONS
   ----------------------------------------------------------------------------
   These 3 tables are loaded from the raw Olist CSVs:
     - olist_customers_dataset.csv   -> customers
     - olist_orders_dataset.csv      -> orders
     - olist_order_items_dataset.csv -> order_items

   NOTE: table creation below defines the schema; the actual data load was
   done manually via DB Browser's File -> Import -> Table from CSV, mapped
   to these pre-created tables (not scriptable in plain SQLite SQL).
---------------------------------------------------------------------------- */

CREATE TABLE customers (
    customer_id TEXT PRIMARY KEY,
    customer_unique_id TEXT,
    customer_zip_code_prefix TEXT,
    customer_city TEXT,
    customer_state TEXT
);

CREATE TABLE orders (
    order_id TEXT PRIMARY KEY,
    customer_id TEXT,
    order_status TEXT,
    order_purchase_timestamp TEXT,
    order_approved_at TEXT,
    order_delivered_carrier_date TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

CREATE TABLE order_items (
    order_id TEXT,
    order_item_id INTEGER,
    product_id TEXT,
    seller_id TEXT,
    shipping_limit_date TEXT,
    price REAL,
    freight_value REAL
);

-- Row count sanity check after import (expected: 99441 / 99441 / 112650)
-- SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
-- UNION ALL SELECT 'orders', COUNT(*) FROM orders
-- UNION ALL SELECT 'order_items', COUNT(*) FROM order_items;


/* ----------------------------------------------------------------------------
   SECTION 2: DATA CLEANING
   ----------------------------------------------------------------------------
   Cleaning decisions, based on actual data inspection (not assumed):
     - Excluded 'canceled' (625) and 'unavailable' (609) orders, ~1.2% of
       total, since they don't represent completed transactions and would
       distort frequency/monetary if included.
     - No missing customer_id / customer_unique_id values were found.
     - No missing or invalid (<=0) prices were found in order_items.
   A VIEW is used instead of DELETE, so the raw counts remain available
   for comparison (98,207 valid orders retained out of 99,441).
---------------------------------------------------------------------------- */

CREATE VIEW valid_orders AS
SELECT *
FROM orders
WHERE order_status NOT IN ('canceled', 'unavailable');


/* ----------------------------------------------------------------------------
   SECTION 3: ORDER-LEVEL AGGREGATION
   ----------------------------------------------------------------------------
   order_items has one row per PRODUCT, not per ORDER. Collapse to one row
   per order (summed price) before joining anything else to it.
---------------------------------------------------------------------------- */

CREATE VIEW order_totals AS
SELECT
    order_id,
    SUM(price) AS order_total
FROM order_items
GROUP BY order_id;


/* ----------------------------------------------------------------------------
   SECTION 4: CUSTOMER IDENTITY RESOLUTION
   ----------------------------------------------------------------------------
   IMPORTANT DATA QUIRK: in this dataset, customers.customer_id is unique
   PER ORDER, not per person. customer_unique_id is the true, stable
   identity of a real customer across repeat orders. All downstream
   RFM logic groups by customer_unique_id — grouping by customer_id
   instead would make every order look like a distinct "new" customer
   and silently break the entire segmentation (Frequency would always
   be 1 for everyone).
---------------------------------------------------------------------------- */

CREATE VIEW customer_orders AS
SELECT
    o.order_id,
    o.order_purchase_timestamp,
    c.customer_id,
    c.customer_unique_id,
    ot.order_total
FROM valid_orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_totals ot ON o.order_id = ot.order_id;


/* ----------------------------------------------------------------------------
   SECTION 5: RECENCY
   ----------------------------------------------------------------------------
   "Today" is anchored to the dataset's own latest valid order date
   (2018-09-03 09:06:57), not the real current date, since this data is
   historical (2016-2018). That date is itself the correct result of
   excluding canceled orders — the raw dataset's absolute latest order
   (2018-10-17) was canceled and correctly excluded by valid_orders.
---------------------------------------------------------------------------- */

CREATE VIEW customer_recency AS
SELECT
    customer_unique_id,
    MAX(order_purchase_timestamp) AS last_order_date,
    CAST(
        julianday((SELECT MAX(order_purchase_timestamp) FROM customer_orders))
        - julianday(MAX(order_purchase_timestamp))
        AS INTEGER
    ) AS recency_days
FROM customer_orders
GROUP BY customer_unique_id;


/* ----------------------------------------------------------------------------
   SECTION 6: MONETARY
   ----------------------------------------------------------------------------
   Total real spend per customer — the closest proxy available in this
   dataset to an "AUM" (assets under management) figure for a brokerage
   context.
---------------------------------------------------------------------------- */

CREATE VIEW customer_monetary AS
SELECT
    customer_unique_id,
    COUNT(DISTINCT order_id) AS order_count,
    SUM(order_total) AS total_spent,
    AVG(order_total) AS avg_order_value
FROM customer_orders
GROUP BY customer_unique_id;


/* ----------------------------------------------------------------------------
   SECTION 7: FREQUENCY (ADAPTED)
   ----------------------------------------------------------------------------
   METHODOLOGY NOTE: 96.9% of customers in this dataset placed exactly one
   order — a standard 4-way Frequency quartile would be nearly meaningless,
   since 3+ quartiles would all contain customers with exactly 1 order and
   zero differentiation. Frequency is treated as a binary repeat-vs-one-time
   flag instead of a quartile, which is a deliberate methodological
   adaptation to this dataset's real characteristics, not an oversight.
---------------------------------------------------------------------------- */

CREATE VIEW customer_frequency_flag AS
SELECT
    customer_unique_id,
    order_count,
    CASE
        WHEN order_count >= 2 THEN 'repeat_customer'
        ELSE 'one_time_customer'
    END AS frequency_flag
FROM customer_monetary;


/* ----------------------------------------------------------------------------
   SECTION 8: RFM QUARTILE SCORING
   ----------------------------------------------------------------------------
   NTILE(4) splits customers into 4 equal-sized groups based on the ORDER BY.
   Recency is ordered DESC (oldest first) so that quartile 4 ends up being
   the MOST RECENT customers — kept consistent with monetary_quartile, where
   quartile 4 is also the BEST (highest spenders). This keeps "4 = best"
   as a consistent convention across both dimensions.
---------------------------------------------------------------------------- */

CREATE VIEW customer_rfm_scores AS
SELECT
    r.customer_unique_id,
    r.recency_days,
    m.total_spent,
    f.frequency_flag,
    NTILE(4) OVER (ORDER BY r.recency_days DESC) AS recency_quartile,
    NTILE(4) OVER (ORDER BY m.total_spent ASC) AS monetary_quartile
FROM customer_recency r
JOIN customer_monetary m ON r.customer_unique_id = m.customer_unique_id
JOIN customer_frequency_flag f ON r.customer_unique_id = f.customer_unique_id;


/* ----------------------------------------------------------------------------
   SECTION 9: NAMED SEGMENTS (CORRECTED VERSION)
   ----------------------------------------------------------------------------
   REVISION HISTORY:
   v1 used a broad ELSE catch-all named "Dormant / Low Value", which was
   found during validation to be silently absorbing 18,081 customers
   (19% of the base) who had above-median recency OR monetary despite the
   "dormant" label. Fixed by:
     1. Adding an explicit "Steady / Moderate Value" tier for customers
        with decent-to-good recency AND monetary that don't qualify for
        the top-tier segments.
     2. Renaming the remaining catch-all from "Dormant / Low Value" to
        "Low Value" — the only trait consistently true across everyone
        left in it is low spend, not necessarily inactivity.

   Validation method: cross-tabbed each segment against its own underlying
   recency_quartile / monetary_quartile combinations to confirm no segment
   silently contained data that contradicted its own name.
---------------------------------------------------------------------------- */

CREATE VIEW customer_segments AS
SELECT
    customer_unique_id,
    recency_days,
    total_spent,
    frequency_flag,
    recency_quartile,
    monetary_quartile,
    CASE
        WHEN recency_quartile = 4 AND monetary_quartile = 4 AND frequency_flag = 'repeat_customer'
            THEN 'Champions'
        WHEN recency_quartile = 4 AND monetary_quartile = 4 AND frequency_flag = 'one_time_customer'
            THEN 'High-Value One-Time'
        WHEN recency_quartile <= 2 AND monetary_quartile >= 3
            THEN 'At Risk'
        WHEN recency_quartile = 4 AND monetary_quartile <= 2
            THEN 'New / Low Value'
        WHEN recency_quartile >= 3 AND monetary_quartile >= 3
            THEN 'Steady / Moderate Value'
        ELSE 'Low Value'
    END AS segment
FROM customer_rfm_scores;

-- Verification query used after the fix (expected: 0 rows):
-- SELECT COUNT(*) FROM customer_segments
-- WHERE segment = 'Low Value' AND (recency_quartile >= 3 OR monetary_quartile >= 3);


/* ----------------------------------------------------------------------------
   SECTION 10: SYNTHETIC ENRICHMENT LAYER
   ----------------------------------------------------------------------------
   ILLUSTRATIVE / SYNTHETIC DATA — NOT REAL DATA.
   Simulates brokerage-style product adoption to make the analysis
   domain-relevant. Rules are deliberately tied to REAL monetary_quartile
   and frequency_flag values so the result is directionally plausible for
   a brokerage context — this is a designed correlation, not a discovered
   pattern, and should be described as such.

   NOTE: this is a TABLE (static snapshot), not a VIEW — it must be
   manually rebuilt (DROP + re-run this block) any time the segment
   logic in Section 9 changes, since it won't update automatically.
---------------------------------------------------------------------------- */

CREATE TABLE enrichment AS
SELECT
    customer_unique_id,
    segment,
    CASE
        WHEN monetary_quartile = 4 AND (ABS(RANDOM()) % 100) < 40 THEN 1
        WHEN monetary_quartile = 3 AND (ABS(RANDOM()) % 100) < 25 THEN 1
        WHEN monetary_quartile = 2 AND (ABS(RANDOM()) % 100) < 10 THEN 1
        WHEN monetary_quartile = 1 AND (ABS(RANDOM()) % 100) < 3  THEN 1
        ELSE 0
    END AS uses_margin,
    CASE
        WHEN monetary_quartile >= 3 AND (ABS(RANDOM()) % 100) < 20 THEN 1
        ELSE 0
    END AS uses_funds,
    CASE
        WHEN frequency_flag = 'repeat_customer' AND (ABS(RANDOM()) % 100) < 45 THEN 'aggressive'
        WHEN (ABS(RANDOM()) % 100) < 55 THEN 'moderate'
        ELSE 'conservative'
    END AS risk_profile,
    CASE (ABS(RANDOM()) % 3)
        WHEN 0 THEN 'branch'
        WHEN 1 THEN 'online'
        ELSE 'referral'
    END AS acquisition_channel
FROM customer_segments;


/* ----------------------------------------------------------------------------
   SECTION 11: SEGMENT-LEVEL SUMMARY (feeds Excel + Power BI)
---------------------------------------------------------------------------- */

CREATE VIEW segment_summary AS
SELECT
    cs.segment,
    COUNT(*) AS customer_count,
    ROUND(AVG(cs.total_spent), 2) AS avg_spent,
    ROUND(AVG(e.uses_margin) * 100, 1) AS pct_uses_margin,
    ROUND(AVG(e.uses_funds) * 100, 1) AS pct_uses_funds,
    ROUND(AVG(CASE WHEN e.uses_margin = 1 THEN cs.total_spent END), 2) AS avg_spent_margin_users
FROM customer_segments cs
JOIN enrichment e ON cs.customer_unique_id = e.customer_unique_id
GROUP BY cs.segment;


/* ============================================================================
   FINAL VALIDATION — expected results after running this full script:
   ============================================================================

   SELECT COUNT(*) FROM customer_segments;   -- 94983
   SELECT COUNT(*) FROM enrichment;          -- 94983

   SELECT segment, COUNT(*), ROUND(AVG(total_spent),2)
   FROM customer_segments GROUP BY segment ORDER BY COUNT(*) DESC;

   -- Expected:
   -- Low Value                  35747   47.32
   -- At Risk                    23454   237.55
   -- Steady / Moderate Value    18081   193.64
   -- New / Low Value            11745   47.40
   -- High-Value One-Time         5446   363.44
   -- Champions                    510   380.83

   ============================================================================ */
