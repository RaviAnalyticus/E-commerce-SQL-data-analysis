-- SETUP: load the CSV, clean it, and build a small relational schema

SET TIME ZONE 'UTC';

DROP TABLE IF EXISTS retail_clean, order_items, orders, products, customers, retail_raw CASCADE;

-- 1) Staging table: everything as TEXT so the load can never fail on a bad value
CREATE TABLE retail_raw (
    invoice_no   TEXT,
    stock_code   TEXT,
    description  TEXT,
    quantity     TEXT,
    invoice_date TEXT,
    unit_price   TEXT,
    customer_id  TEXT,
    country      TEXT
);

\copy retail_raw FROM 'data/data_3.csv' WITH (FORMAT csv, HEADER true, ENCODING 'LATIN1')

-- 2) Typed + de-duplicated copy of the raw data
--    * exact duplicate rows are removed (SELECT DISTINCT before any transformation)
--    * dates like '12/1/2010 8:26' are parsed into real timestamps
--    * stock codes are trimmed / upper-cased ('85123a' and '85123A' are one product)
CREATE TABLE retail_clean AS
SELECT invoice_no,
       UPPER(TRIM(stock_code))                                   AS stock_code,
       NULLIF(TRIM(description), '')                             AS description,
       quantity::INT                                             AS quantity,
       TO_TIMESTAMP(invoice_date, 'MM/DD/YYYY HH24:MI')::TIMESTAMP AS invoice_date,
       unit_price::NUMERIC(10,2)                                 AS unit_price,
       customer_id::INT                                          AS customer_id,
       country
FROM (SELECT DISTINCT * FROM retail_raw) AS d;

-- 3) Relational schema
CREATE TABLE customers (
    customer_id INT  PRIMARY KEY,
    country     TEXT NOT NULL
);

CREATE TABLE products (
    stock_code     TEXT    PRIMARY KEY,
    description    TEXT    NOT NULL,
    is_merchandise BOOLEAN NOT NULL      -- FALSE for postage, fees, vouchers, manual adjustments
);

CREATE TABLE orders (
    invoice_no   TEXT      PRIMARY KEY,
    customer_id  INT       REFERENCES customers (customer_id),   -- NULL = no CustomerID (guest or internal adjustment)
    invoice_date TIMESTAMP NOT NULL,
    country      TEXT      NOT NULL,
    invoice_type TEXT      NOT NULL CHECK (invoice_type IN ('SALE', 'CANCELLATION', 'ADJUSTMENT'))
);

CREATE TABLE order_items (
    item_id    BIGSERIAL     PRIMARY KEY,
    invoice_no TEXT          NOT NULL REFERENCES orders (invoice_no),
    stock_code TEXT          NOT NULL REFERENCES products (stock_code),
    quantity   INT           NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL
);

-- 4) Populate (8 customers appear under 2 countries -> keep their most frequent one;
--    each product keeps its most frequent description; missing ones become 'UNKNOWN')
INSERT INTO customers (customer_id, country)
SELECT customer_id, MODE() WITHIN GROUP (ORDER BY country)
FROM retail_clean
WHERE customer_id IS NOT NULL
GROUP BY customer_id;

INSERT INTO products (stock_code, description, is_merchandise)
SELECT stock_code,
       COALESCE(MODE() WITHIN GROUP (ORDER BY description), 'UNKNOWN'),
       NOT (stock_code IN ('POST', 'DOT', 'M', 'C2', 'D', 'S', 'BANK CHARGES',
                           'AMAZONFEE', 'CRUK', 'PADS', 'B')
            OR stock_code LIKE 'GIFT%')
FROM retail_clean
GROUP BY stock_code;

-- InvoiceNo starting with 'C' = cancellation/return, 'A' = bad-debt adjustment.
-- A few invoices span more than one minute, so the earliest timestamp is used.
INSERT INTO orders (invoice_no, customer_id, invoice_date, country, invoice_type)
SELECT invoice_no,
       MAX(customer_id),
       MIN(invoice_date),
       MIN(country),
       CASE WHEN invoice_no LIKE 'C%' THEN 'CANCELLATION'
            WHEN invoice_no LIKE 'A%' THEN 'ADJUSTMENT'
            ELSE 'SALE' END
FROM retail_clean
GROUP BY invoice_no;

INSERT INTO order_items (invoice_no, stock_code, quantity, unit_price)
SELECT invoice_no, stock_code, quantity, unit_price
FROM retail_clean
ORDER BY invoice_date, invoice_no, stock_code;

DROP TABLE retail_clean;

-- 5) Base view used by most queries below: valid sale lines only
--    (no cancellations/adjustments, positive quantity, positive price) + revenue.
CREATE OR REPLACE VIEW v_sales AS
SELECT oi.item_id,
       o.invoice_no,
       o.invoice_date,
       o.customer_id,
       o.country,
       oi.stock_code,
       p.description,
       p.is_merchandise,
       oi.quantity,
       oi.unit_price,
       ROUND(oi.quantity * oi.unit_price, 2) AS revenue
FROM order_items oi
JOIN orders   o ON o.invoice_no = oi.invoice_no
JOIN products p ON p.stock_code = oi.stock_code
WHERE o.invoice_type = 'SALE'
  AND oi.quantity   > 0
  AND oi.unit_price > 0;

ANALYZE;



-- SECTION A: SELECT, WHERE, ORDER BY  (exploring the data)


-- Q01 | Row counts of every table (checks the load: 541,909 raw - 5,268 duplicates = 536,641 lines)
SELECT table_name, row_count
FROM (
    SELECT 1 AS ord, 'retail_raw (CSV as loaded)'          AS table_name, COUNT(*) AS row_count FROM retail_raw
    UNION ALL SELECT 2, 'customers',                                     COUNT(*) FROM customers
    UNION ALL SELECT 3, 'products',                                      COUNT(*) FROM products
    UNION ALL SELECT 4, 'orders (invoices)',                             COUNT(*) FROM orders
    UNION ALL SELECT 5, 'order_items (duplicates removed)',              COUNT(*) FROM order_items
    UNION ALL SELECT 6, 'v_sales (valid sale lines)',                    COUNT(*) FROM v_sales
) AS t
ORDER BY ord;

-- Q02 | Business snapshot: period covered, size and total revenue
SELECT MIN(invoice_date)::DATE            AS first_sale,
       MAX(invoice_date)::DATE            AS last_sale,
       COUNT(DISTINCT invoice_no)         AS invoices,
       COUNT(DISTINCT customer_id)        AS customers,
       COUNT(DISTINCT stock_code)         AS products_sold,
       COUNT(DISTINCT country)            AS countries,
       ROUND(SUM(revenue), 2)             AS total_revenue_gbp
FROM v_sales;

-- Q03 | WHERE + ORDER BY: heart-themed lines worth over 100 GBP sold to Germany/France in 2011
SELECT invoice_no,
       invoice_date::DATE AS invoice_date,
       country,
       description,
       quantity,
       unit_price,
       revenue
FROM v_sales
WHERE country IN ('Germany', 'France')
  AND invoice_date BETWEEN '2011-01-01' AND '2011-12-31'
  AND description ILIKE '%HEART%'
  AND revenue > 100
ORDER BY revenue DESC, invoice_date
LIMIT 10;

-- Q04 | Handling NULLs (1/3): how many orders have no CustomerID? Most are internal stock
--       adjustments; only the ones that also have valid sale lines are real guest purchases.
SELECT COUNT(*)                                                         AS total_orders,
       COUNT(*) - COUNT(o.customer_id)                                  AS orders_with_null_customer_id,
       ROUND(100.0 * (COUNT(*) - COUNT(o.customer_id)) / COUNT(*), 1)   AS pct_null,
       COUNT(*) FILTER (WHERE o.customer_id IS NULL
                          AND vs.invoice_no IS NOT NULL)                AS null_id_orders_with_sales,
       (SELECT COUNT(*) FROM products WHERE description = 'UNKNOWN')    AS products_missing_description
FROM orders o
LEFT JOIN (SELECT DISTINCT invoice_no FROM v_sales) AS vs
       ON vs.invoice_no = o.invoice_no;

-- Q05 | Handling NULLs (2/3): COALESCE gives NULL customers a label so they are not lost
SELECT COALESCE(customer_id::TEXT, 'GUEST (NULL id)') AS customer,
       COUNT(DISTINCT invoice_no)                     AS orders,
       ROUND(SUM(revenue), 2)                         AS revenue
FROM v_sales
GROUP BY COALESCE(customer_id::TEXT, 'GUEST (NULL id)')
ORDER BY revenue DESC
LIMIT 5;


-- SECTION B: AGGREGATES (SUM, AVG, COUNT), GROUP BY, HAVING


-- Q06 | Revenue, orders and average order value by country (Top 10)
SELECT country,
       COUNT(DISTINCT invoice_no)                                  AS orders,
       SUM(quantity)                                               AS units_sold,
       ROUND(SUM(revenue), 2)                                      AS revenue,
       ROUND(SUM(revenue) / COUNT(DISTINCT invoice_no), 2)         AS avg_order_value
FROM v_sales
GROUP BY country
ORDER BY revenue DESC
LIMIT 10;

-- Q07 | Which weekday is busiest? (no sales are recorded on Saturdays)
SELECT TRIM(TO_CHAR(invoice_date, 'Day'))      AS weekday,
       COUNT(DISTINCT invoice_no)              AS orders,
       ROUND(SUM(revenue), 2)                  AS revenue,
       ROUND(AVG(revenue), 2)                  AS avg_line_value
FROM v_sales
GROUP BY TRIM(TO_CHAR(invoice_date, 'Day')), EXTRACT(ISODOW FROM invoice_date)
ORDER BY EXTRACT(ISODOW FROM invoice_date);

-- Q08 | Top 10 products by revenue (merchandise only, JOIN + GROUP BY)
SELECT p.stock_code,
       p.description,
       SUM(oi.quantity)                              AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price), 2)    AS revenue
FROM order_items oi
JOIN orders   o ON o.invoice_no = oi.invoice_no
JOIN products p ON p.stock_code = oi.stock_code
WHERE o.invoice_type = 'SALE'
  AND oi.quantity > 0 AND oi.unit_price > 0
  AND p.is_merchandise
GROUP BY p.stock_code, p.description
ORDER BY revenue DESC
LIMIT 10;

-- Q09 | WHERE vs HAVING: WHERE filters rows BEFORE grouping, HAVING filters groups AFTER
SELECT country,
       COUNT(DISTINCT invoice_no)  AS orders,
       ROUND(SUM(revenue), 2)      AS revenue
FROM v_sales
WHERE country <> 'United Kingdom'               -- row-level filter
GROUP BY country
HAVING COUNT(DISTINCT invoice_no) >= 100        -- group-level filter on an aggregate
ORDER BY revenue DESC;

-- Q10 | Average revenue per user (ARPU), average order value and orders per customer
--       (registered customers only; Handling NULLs (3/3): NULLIF avoids division by zero)
SELECT COUNT(DISTINCT customer_id)                                               AS customers,
       COUNT(DISTINCT invoice_no)                                                AS orders,
       ROUND(SUM(revenue), 2)                                                    AS total_revenue,
       ROUND(SUM(revenue) / NULLIF(COUNT(DISTINCT customer_id), 0), 2)           AS avg_revenue_per_user,
       ROUND(SUM(revenue) / NULLIF(COUNT(DISTINCT invoice_no), 0), 2)            AS avg_order_value,
       ROUND(COUNT(DISTINCT invoice_no)::NUMERIC
             / NULLIF(COUNT(DISTINCT customer_id), 0), 2)                        AS orders_per_customer
FROM v_sales
WHERE customer_id IS NOT NULL;

-- Q11 | ARPU by country (countries with at least 10 customers, Top 10 by ARPU)
SELECT country,
       COUNT(DISTINCT customer_id)                                        AS customers,
       ROUND(SUM(revenue), 2)                                             AS revenue,
       ROUND(SUM(revenue) / NULLIF(COUNT(DISTINCT customer_id), 0), 2)    AS avg_revenue_per_user
FROM v_sales
WHERE customer_id IS NOT NULL
GROUP BY country
HAVING COUNT(DISTINCT customer_id) >= 10
ORDER BY avg_revenue_per_user DESC
LIMIT 10;


-- Q12 | Gross sales vs cancelled/returned value (CASE inside GROUP BY)
SELECT CASE WHEN o.invoice_type = 'SALE' AND oi.quantity > 0 AND oi.unit_price > 0 THEN '1. Valid sales'
            WHEN o.invoice_type = 'CANCELLATION'                                  THEN '2. Cancellations / returns'
            ELSE                                                                       '3. Adjustments, free and write-off lines'
       END                                              AS category,
       COUNT(*)                                         AS lines,
       ROUND(SUM(ABS(oi.quantity * oi.unit_price)), 2)  AS value_gbp
FROM orders o
JOIN order_items oi ON oi.invoice_no = o.invoice_no
GROUP BY 1
ORDER BY 1;


-- SECTION C: JOINS (INNER, LEFT, RIGHT)


-- Q13 | INNER JOIN (3 tables): Top 10 customers by revenue
SELECT c.customer_id,
       c.country,
       COUNT(DISTINCT o.invoice_no)                  AS orders,
       SUM(oi.quantity)                              AS units,
       ROUND(SUM(oi.quantity * oi.unit_price), 2)    AS revenue
FROM customers c
INNER JOIN orders      o  ON o.customer_id = c.customer_id
INNER JOIN order_items oi ON oi.invoice_no = o.invoice_no
WHERE o.invoice_type = 'SALE'
  AND oi.quantity > 0 AND oi.unit_price > 0
GROUP BY c.customer_id, c.country
ORDER BY revenue DESC
LIMIT 10;

-- Q14 | LEFT JOIN: keep every order, even guest orders that have no matching customer
SELECT CASE WHEN c.customer_id IS NULL THEN 'Guest (no CustomerID)'
            ELSE 'Registered customer' END                                   AS customer_type,
       COUNT(DISTINCT o.invoice_no)                                          AS orders,
       ROUND(SUM(s.revenue), 2)                                              AS revenue,
       ROUND(100.0 * SUM(s.revenue) / SUM(SUM(s.revenue)) OVER (), 1)        AS pct_of_revenue
FROM orders o
LEFT JOIN customers c ON c.customer_id = o.customer_id
JOIN      v_sales   s ON s.invoice_no  = o.invoice_no
GROUP BY CASE WHEN c.customer_id IS NULL THEN 'Guest (no CustomerID)'
              ELSE 'Registered customer' END;

-- Q15 | LEFT JOIN + IS NULL (anti-join): customers who never completed a valid purchase
--       (all of their invoices were cancellations or zero-value lines)
SELECT c.customer_id,
       c.country,
       COUNT(*) OVER () AS total_such_customers
FROM customers c
LEFT JOIN v_sales s ON s.customer_id = c.customer_id
WHERE s.customer_id IS NULL
ORDER BY c.customer_id
LIMIT 10;

-- Q16 | RIGHT JOIN: products with no valid sale at all (only returns, write-offs, damages, free items)
SELECT p.stock_code,
       p.description,
       p.is_merchandise,
       COUNT(*) OVER () AS total_never_sold
FROM v_sales s
RIGHT JOIN products p ON p.stock_code = s.stock_code
WHERE s.item_id IS NULL
ORDER BY (p.description = 'UNKNOWN'), p.stock_code      -- products with a real description first
LIMIT 10;



-- SECTION D: SUBQUERIES


-- Q17 | Subquery in HAVING + derived table: customers spending more than the average customer
SELECT customer_id,
       ROUND(SUM(revenue), 2) AS total_spend,
       COUNT(*) OVER ()       AS customers_above_average
FROM v_sales
WHERE customer_id IS NOT NULL
GROUP BY customer_id
HAVING SUM(revenue) > (SELECT AVG(customer_total)
                       FROM (SELECT SUM(revenue) AS customer_total
                             FROM v_sales
                             WHERE customer_id IS NOT NULL
                             GROUP BY customer_id) AS t)
ORDER BY total_spend DESC
LIMIT 10;

-- Q18 | Scalar subquery in SELECT: each country's share of total revenue
SELECT country,
       ROUND(SUM(revenue), 2)                                              AS revenue,
       ROUND(100.0 * SUM(revenue) / (SELECT SUM(revenue) FROM v_sales), 2) AS pct_of_total
FROM v_sales
GROUP BY country
ORDER BY revenue DESC
LIMIT 6;

-- Q19 | Correlated subquery: the biggest-spending customer in each country (Top 10 countries)
WITH customer_revenue AS (
    SELECT customer_id, country, ROUND(SUM(revenue), 2) AS revenue
    FROM v_sales
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id, country
)
SELECT cr.country, cr.customer_id, cr.revenue
FROM customer_revenue cr
WHERE cr.revenue = (SELECT MAX(x.revenue)
                    FROM customer_revenue x
                    WHERE x.country = cr.country)      -- refers to the outer row
ORDER BY cr.revenue DESC
LIMIT 10;

-- Q20 | EXISTS subquery: how many customers have at least one cancelled order?
SELECT COUNT(*)                                              AS customers_with_cancellation,
       (SELECT COUNT(*) FROM customers)                      AS total_customers,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customers), 1) AS pct_of_customers
FROM customers c
WHERE EXISTS (SELECT 1
              FROM orders o
              WHERE o.customer_id = c.customer_id
                AND o.invoice_type = 'CANCELLATION');


-- SECTION E: VIEWS FOR ANALYSIS  (+ CASE and window functions)


-- Monthly KPIs with month-over-month growth (LAG window function)
CREATE OR REPLACE VIEW v_monthly_revenue AS
WITH m AS (
    SELECT DATE_TRUNC('month', invoice_date)::DATE AS month,
           COUNT(DISTINCT invoice_no)              AS orders,
           COUNT(DISTINCT customer_id)             AS customers,
           ROUND(SUM(revenue), 2)                  AS revenue
    FROM v_sales
    GROUP BY 1
)
SELECT month,
       orders,
       customers,
       revenue,
       ROUND(revenue / orders, 2) AS avg_order_value,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 1) AS mom_growth_pct
FROM m;

-- One row per registered customer
CREATE OR REPLACE VIEW v_customer_summary AS
SELECT c.customer_id,
       c.country,
       COUNT(DISTINCT s.invoice_no)                                    AS orders,
       SUM(s.quantity)                                                 AS units,
       ROUND(SUM(s.revenue), 2)                                        AS revenue,
       ROUND(SUM(s.revenue) / COUNT(DISTINCT s.invoice_no), 2)         AS avg_order_value,
       MIN(s.invoice_date)::DATE                                       AS first_order,
       MAX(s.invoice_date)::DATE                                       AS last_order
FROM customers c
JOIN v_sales s ON s.customer_id = c.customer_id
GROUP BY c.customer_id, c.country;

-- One row per merchandise product
CREATE OR REPLACE VIEW v_product_performance AS
SELECT p.stock_code,
       p.description,
       SUM(s.quantity)                  AS units_sold,
       COUNT(DISTINCT s.invoice_no)     AS orders,
       ROUND(SUM(s.revenue), 2)         AS revenue,
       ROUND(AVG(s.unit_price), 2)      AS avg_unit_price
FROM products p
JOIN v_sales s ON s.stock_code = p.stock_code
WHERE p.is_merchandise
GROUP BY p.stock_code, p.description;

-- Q21 | Monthly revenue trend from the view (Dec-2011 is a partial month: data ends on 9 Dec)
SELECT * FROM v_monthly_revenue ORDER BY month;

-- Q22 | Customer segments with CASE: how much revenue comes from the biggest spenders?
SELECT CASE WHEN revenue >= 5000 THEN '1. High   (5,000+ GBP)'
            WHEN revenue >= 1000 THEN '2. Medium (1,000 - 4,999 GBP)'
            ELSE                      '3. Low    (under 1,000 GBP)' END        AS segment,
       COUNT(*)                                                                AS customers,
       ROUND(SUM(revenue), 2)                                                  AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)              AS pct_of_revenue
FROM v_customer_summary
GROUP BY 1
ORDER BY 1;

-- Q23 | Window function RANK(): best sellers by volume vs by value
SELECT description,
       units_sold,
       revenue,
       RANK() OVER (ORDER BY units_sold DESC) AS units_rank,
       RANK() OVER (ORDER BY revenue DESC)    AS revenue_rank
FROM v_product_performance
ORDER BY units_rank
LIMIT 10;

-- Q24 | Window function with PARTITION BY: top 3 customers inside each of the 4 biggest countries
WITH ranked AS (
    SELECT country,
           customer_id,
           revenue,
           RANK() OVER (PARTITION BY country ORDER BY revenue DESC) AS rank_in_country
    FROM v_customer_summary
    WHERE country IN ('United Kingdom', 'Germany', 'France', 'EIRE')
)
SELECT *
FROM ranked
WHERE rank_in_country <= 3
ORDER BY country, rank_in_country;



-- SECTION F: OPTIMISING QUERIES WITH INDEXES


-- Q25 | Index demo 1: finding every sale of one product (stock_code lookup)
SET max_parallel_workers_per_gather = 0;

EXPLAIN ANALYZE
SELECT COUNT(*) AS lines, SUM(quantity) AS units
FROM order_items
WHERE stock_code = '85123A';

CREATE INDEX idx_order_items_stock_code ON order_items (stock_code);
ANALYZE order_items;

EXPLAIN ANALYZE
SELECT COUNT(*) AS lines, SUM(quantity) AS units
FROM order_items
WHERE stock_code = '85123A';

-- Q26 | Index demo 2: one customer's order history (filter + join on foreign keys)
EXPLAIN ANALYZE
SELECT o.invoice_no, o.invoice_date, SUM(oi.quantity * oi.unit_price) AS order_value
FROM orders o
JOIN order_items oi ON oi.invoice_no = o.invoice_no
WHERE o.customer_id = 14646
GROUP BY o.invoice_no, o.invoice_date
ORDER BY o.invoice_date;

CREATE INDEX idx_orders_customer_id     ON orders (customer_id);
CREATE INDEX idx_order_items_invoice_no ON order_items (invoice_no);
ANALYZE orders;
ANALYZE order_items;

EXPLAIN ANALYZE
SELECT o.invoice_no, o.invoice_date, SUM(oi.quantity * oi.unit_price) AS order_value
FROM orders o
JOIN order_items oi ON oi.invoice_no = o.invoice_no
WHERE o.customer_id = 14646
GROUP BY o.invoice_no, o.invoice_date
ORDER BY o.invoice_date;

-- Q27 | Indexes now in place on the schema
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname LIKE 'idx_%'
ORDER BY tablename, indexname;

