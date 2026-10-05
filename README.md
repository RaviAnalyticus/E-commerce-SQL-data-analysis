# Task 3: SQL for Data Analysis (PostgreSQL)

Data Analyst Internship, Elevate Labs. I loaded an e-commerce transactions dataset into **PostgreSQL**, built a small relational schema from it, and used SQL to answer business questions about sales, customers, products and returns.

## Dataset
`data/data_3.csv` is the **Online Retail** dataset: 541,909 invoice lines from a UK-based online gift retailer, 1 Dec 2010 to 9 Dec 2011, covering 38 countries. Prices are in GBP.

| Column | Meaning |
|---|---|
| InvoiceNo | Invoice id (a leading `C` means cancellation) |
| StockCode / Description | Product code and name |
| Quantity / UnitPrice | Units and price per unit |
| InvoiceDate | Invoice timestamp |
| CustomerID | Customer id (missing on 25% of lines) |
| Country | Customer country |

## What I did
1. **Loaded** the CSV into a TEXT staging table with `\copy` (the file is Latin-1 encoded, so `ENCODING 'LATIN1'`).
2. **Cleaned**: removed 5,268 exact duplicate rows, parsed dates (`12/1/2010 8:26`) into timestamps, upper-cased stock codes, and flagged cancellations (`C...`) and bad-debt adjustments (`A...`).
3. **Modelled** four tables: `customers`, `products`, `orders`, `order_items` with primary and foreign keys.
4. **Analysed** with 27 queries (below), created views, and tuned two queries with indexes.

```
customers (customer_id PK, country)
products  (stock_code PK, description, is_merchandise)
orders    (invoice_no PK, customer_id FK, invoice_date, country, invoice_type)
order_items (item_id PK, invoice_no FK, stock_code FK, quantity, unit_price)
```

## Task hints covered
| Hint | Where |
|---|---|
| SELECT, WHERE, ORDER BY, GROUP BY | Q01 to Q11 |
| JOINs (INNER, LEFT, RIGHT) | Q13 (INNER), Q14 and Q15 (LEFT), Q16 (RIGHT) |
| Subqueries | Q17 to Q20 (derived table, scalar, correlated, EXISTS) |
| Aggregates (SUM, AVG, COUNT) | Q06 to Q12, Q21 to Q24 |
| Views | `v_sales`, `v_monthly_revenue`, `v_customer_summary`, `v_product_performance` (Q21 to Q24 query them) |
| Indexes | Q25 to Q27 with `EXPLAIN ANALYZE` before and after |

Extras: `CASE` segmentation (Q12, Q22), window functions `LAG` and `RANK` (Q21, Q23, Q24), NULL handling with `COALESCE` and `NULLIF` (Q04, Q05, Q10).

## Key findings
- **Revenue:** 10.63M GBP from valid sales across 19,959 invoices and 4,338 registered customers.
- **Geography:** the UK brings in 84.6% of revenue. Netherlands, EIRE, Germany and France come next (about 2 to 3% each).
- **Average revenue per user:** 2,048.69 GBP. Average order value is 479.56 GBP and customers placed 4.27 orders on average.
- **Concentration:** 274 customers (about 6%) account for 53.9% of revenue.
- **Guests:** orders without a CustomerID are 16.4% of revenue.
- **Returns:** cancelled invoices are worth 893,980 GBP, about 8.4% of valid sales. 36.3% of customers cancelled at least once.
- **Seasonality:** November 2011 was the peak month (1.50M GBP, +30.6% vs October). There are no Saturday sales in the data, and Thursday is the busiest day by orders.
- **Indexes:** a product lookup went from 24.6 ms to 2.3 ms, and a customer order-history join from 72.9 ms to 1.7 ms (timings from my run, they will vary by machine).

## Notes on the data
- Revenue is `quantity * unit_price` on valid sale lines only (not cancelled, quantity > 0, price > 0), so figures are gross of returns. The cancelled value is reported separately in Q12.
- 3,710 invoices have no CustomerID. Most are internal stock adjustments; 1,427 are real purchases (Q04).
- Eight customers appear under two countries, so each keeps its most frequent one.
- December 2011 is a partial month (data ends on 9 Dec).

## How to run
```bash
createdb ecommerce_db
psql -d ecommerce_db -f sql/task3_sql_analysis.sql     # run from the repo root
```
`\copy` only works in `psql`. In pgAdmin, create `retail_raw` (first block of the script), import the CSV through right-click > Import/Export Data (Header on, Encoding LATIN1), then run the rest of the file.

## Repository structure
```
.
├── README.md
├── INTERVIEW_QUESTIONS.md        answers to the 7 interview questions, linked to the queries
├── data/data_3.csv               dataset
├── sql/task3_sql_analysis.sql    all SQL: setup, Q01 to Q27, views, indexes
└── screenshots/                  one image per query (SQL and its output)
```
The screenshots are rendered from the real `psql` output of this script on PostgreSQL 16.
