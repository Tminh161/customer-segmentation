# Retail Customer Segmentation & Cross-Sell Analysis

RFM-based customer segmentation and cross-sell opportunity analysis, built on real e-commerce transaction data and adapted for a retail brokerage context.

![SQL](https://img.shields.io/badge/SQL-SQLite-blue)
![Excel](https://img.shields.io/badge/Excel-Analysis-217346)
![Power BI](https://img.shields.io/badge/Power%20BI-Dashboard-F2C811)

## Overview

This project applies RFM (Recency, Frequency, Monetary) segmentation to 94,983 real customers from the [Olist Brazilian E-Commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), then layers illustrative brokerage-style product attributes on top of the real segments to model a retail securities brokerage use case — customer segmentation and cross-sell analysis for a Data Analyst role.

**What makes this more than a standard RFM exercise:** the methodology was adapted to the dataset's actual characteristics rather than applied by default, and a segmentation logic error affecting 19% of customers was caught and corrected through deliberate validation — both documented in full below.

## Key Findings

- **96.9% of customers placed exactly one order** — a standard 4-way Frequency quartile would have been meaningless, so Frequency was adapted to a binary repeat-vs-one-time flag instead.
- **Caught and fixed a segmentation bug**: an initial catch-all segment was found (via validation against underlying quartile data, not just checking the query ran) to be mislabeling 18,081 customers — 19% of the base — despite many having above-median recency or spend. Corrected with an explicit "Steady / Moderate Value" tier.
- **Recommendation**: the "Steady / Moderate Value" segment (18,081 customers, ~544K BRL illustrative opportunity, 30.1% existing product adoption) offers the strongest balance of scale and engagement for cross-sell targeting — a finding that only emerged after fixing the segmentation logic.

## Methodology

1. **Data cleaning** (SQL) — loaded 3 real tables (customers, orders, order items), excluded canceled/unavailable orders (99,441 → 98,207 valid transactions), resolved a data quirk where `customer_id` is unique per order rather than per person.
2. **RFM scoring** (SQL) — Recency and Monetary computed via `NTILE(4)` window functions; Frequency adapted to a binary flag based on the dataset's actual repeat-purchase rate.
3. **Segmentation** (SQL) — 6 segments built via `CASE` logic, validated by cross-tabbing each segment against its own underlying quartile composition.
4. **Cross-sell analysis** (Excel) — opportunity sizing per segment, chi-square test to confirm adoption differences were statistically meaningful (p < 0.001).
5. **Dashboard** (Power BI) — 3-page interactive report with DAX measures, relationships, and slicers.

Full commented SQL pipeline: [`sql/segmentation_pipeline.sql`](sql/segmentation_pipeline.sql)
Full written summary: [`docs/Customer_Segmentation_Project_Summary.pdf`](docs/Customer_Segmentation_Project_Summary.pdf)

## Tech Stack

| Tool | Purpose |
|---|---|
| SQL (SQLite) | Data cleaning, customer identity resolution, RFM scoring, segmentation logic |
| Excel | Validation spot-checks, opportunity sizing, chi-square test |
| Power BI | 3-page interactive dashboard, DAX measures |

## Repository Structure

├── sql/
│   └── segmentation_pipeline.sql                    # Full commented pipeline, tested end-to-end
├── excel/
│   └── cross_sell_analysis.xlsx                     # Opportunity sizing, chi-square test
├── docs/
│   └── Customer_Segmentation_Project_Summary.pdf    # 1-page written project summary
├── retail-segmentation-dashboard.pbix               # Power BI report (3 pages)
└── README.md

*Note: raw source CSVs are not included in this repo — see Dataset link below to download them directly.*

## Dashboard Preview

*(Insert screenshot of Overview page here)*

## Limitations

Segment membership, recency, and monetary values are derived from real transaction data. Product adoption, risk profile, and acquisition channel are illustrative — rule-based and tied to real monetary/frequency values to stay directionally plausible for a brokerage context, but not discovered patterns. Two assumptions underlie the recommendation: a 20% conversion rate, and prioritizing total opportunity over adoption rate — both would require validation against real historical data before informing an actual business decision.

## Dataset

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), Kaggle. Download `olist_customers_dataset.csv`, `olist_orders_dataset.csv`, and `olist_order_items_dataset.csv` to reproduce the SQL pipeline.

---
