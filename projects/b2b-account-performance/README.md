# 🏢 B2B Account Performance

> A single monthly health read on every active B2B account. Each row is one organisation in one month, classified into a health category so Customer Success and Account Managers can see at a glance who needs deployment help, who is ready to grow, and who is drifting toward churn.

**Tech:** SQL · Databricks/Spark SQL · BI (ThoughtSpot)
**Role:** Design, build and delivery, end to end
**Domain:** Subscription EdTech · B2B / Customer Success · Account Health Scoring

---

## Table of Contents
1. [Context & Introduction](#1-context--introduction)
2. [Problem & Objective](#2-problem--objective)
3. [Value & Who Benefits](#3-value--who-benefits)
4. [Technical Build](#4-technical-build)
5. [The KPIs & Health Categories](#5-the-kpis--health-categories)
6. [Output & How to Use](#6-output--how-to-use)
7. [Key Takeaways](#7-key-takeaways)

---

## 1. Context & Introduction

Customer Success and Account Management teams manage a large portfolio of B2B accounts and need to know where to spend their time. The signals that matter - what an account pays, how many seats it uses, how many users read, and the value of that reading - lived in separate places. This model brings them onto one monthly grid and reduces them to a single health classification plus the KPIs behind it.

---

## 2. Problem & Objective

Give every active B2B account a monthly, comparable health read, with KPIs that are fair across accounts of different size and tenure, and a classification teams can act on without chasing one-off bad months.

The objective is an at-a-glance triage: **who needs help deploying, who is ready to grow, and who is at churn risk.**

---

## 3. Value & Who Benefits

- A monthly **health category** for every active account (7 categories, priority-ordered, first matching rule wins).
- A **priority/severity tag** plus a **3-month confirmation** flag, so teams act on sustained signals, not noise.
- The **5 core KPIs** plus a price-normalised internal ROI for fair internal comparison.
- **Reallocation trend monitoring** to catch accounts churning through their seat pool.
- A **current-state layer** that pins each org's latest-month KPIs onto every row (this sidesteps a nested group-aggregate limit in the BI tool, so the summary view needs no group-aggregate formula).
- A full per-account monthly time series feeding the dashboard.

**For the business:** CS and AM get a single, sustained-signal view of account health instead of stitching MRR, seats, users and reading together by hand. **For the customer:** the customer-facing ROI is fair and tenure-neutral, so it can be quoted directly as *"£ read per £1 paid this year"*, supporting renewal and expansion conversations.

---

## 4. Technical Build

**Script:** [`sql/b2b_account_performance.sql`](sql/b2b_account_performance.sql) - five sequential steps; run top to bottom, because Step 5 reads the outputs of Steps 1-4.

| Step | Output table | What it does |
|---|---|---|
| 1 | `nb_b2b_license_allocation_monthly_snapshot` | Contracted seats per org per month. Current month deleted and re-inserted each run (idempotent). |
| 2 | `nb_b2b_mrr_monthly_snapshot` | MRR per active B2B org per month, plus tiering and contract-start attributes. |
| 3 | `nb_b2b_active_subs_monthly_snapshot` | Distinct active indirect subscriptions and users per org per month, with rolling-12m and cumulative totals over a gap-free spine. |
| 4 | `nb_b2b_book_value_monthly_snapshot` | GBP value of books first-read each month (priced once per user-book), with reader/book counts and rolling/cumulative windows. |
| 5 | `nb_b2b_account_performance_monthly_snapshot` | Joins 1-4 on the monthly spine, computes the KPI layer, classification, confirmation and reallocation trend, and the current-state columns. |

**Key design choices**
- **Gap-free spine + LOCF (last observation carried forward):** every month from contract start to now is present; MRR and licences carry forward over a missing snapshot rather than dropping to zero (which previously understated cumulative spend).
- **Matched ROI windows:** the customer-facing ROI divides L12M reading value by MRR billed over the *same* 12 months, so it is tenure-neutral and comparable across accounts. A legacy ROI that decays with tenure is retained only for continuity.
- **Dynamic thresholds:** `arpu_floor` (0.75 × portfolio median ARPU) and `dlp_floor` recalculate each month from the live portfolio, so they never go stale.
- **Confirmation rule:** risk categories are only treated as actionable after holding for **3 consecutive months**.

---

## 5. The KPIs & Health Categories

**The 5 core KPIs**

| KPI | Column | Definition |
|---|---|---|
| ROI (L12M) | `roi_rolling_12m` | L12M reading value ÷ MRR over the same 12 months. Customer-facing. |
| ARPU | `arpu` | MRR ÷ contracted seats. Low = underpriced. |
| Redemption | `redemption_rate` | Cumulative active subs ÷ contracted seats. Low = churn signal; can exceed 100%. |
| Engagement (L12M) | `engagement_l12m` | L12M unique readers ÷ L12M active users. Low = signed up but not reading. |
| Avg DLP (L12M) | `avg_dlp_l12m` | L12M reading value ÷ L12M unique books. Low = shallow/cheap titles, often a catalogue gap. |

**Health categories (priority order, first match wins)**

| # | Category | Rule | Action |
|---|---|---|---|
| 1 | **Pricing: Critical** | ARPU < floor AND ROI (Internal) < 1 | Escalate, do not auto-renew |
| 2 | **Expansion Signal** | ROI (Internal) ≥ 5 AND Redemption ≥ 75% | Seat expansion / upgrade |
| 3 | **Pricing: At Risk** | ARPU < floor AND ROI (Internal) 1-2× | Fix price at renewal |
| 4 | **Adoption Risk** | Redemption < 50% AND ROI (L12M) < 2 | Urgent deployment campaign |
| 5 | **Engagement Gap** | Redemption ≥ 50% AND Engagement < 40% AND ROI (L12M) < 5 | Activation campaign |
| 6 | **Content / Publisher** | Redemption ≥ 50% AND Engagement ≥ 40% AND Avg DLP < floor | Flag content team |
| 7 | **Healthy** | None of the above | Quarterly check-in |

Use `health_category_confirmed` for the action list and `health_category_priority` to triage.

---

## 6. Output & How to Use

Surfaced through the BI layer (ThoughtSpot) in three tabs: **Info** (model explainer), **Summary** (current-state, one row per account via `is_latest_month = TRUE`), and **Movement Tracker** (the per-account historical grid, each account's health category coloured month by month alongside its current-state KPIs).

- **To build the summary table:** filter `is_latest_month = TRUE` (one row per org, every `current_*` column already native).
- **To colour or group a monthly pivot:** drop a `current_*` column straight on.

This lets a team see both where an account is **now** and **how it got there**, and triage the portfolio in priority order: escalate underpriced under-delivering accounts, push expansion where ROI and redemption are both strong, run deployment campaigns where seats sit unused, and flag catalogue gaps to the content team.

---

## 7. Key Takeaways

- **One classification from many signals.** Collapsing MRR, seats, users and reading value into a single priority-ordered health category is what makes the portfolio triageable.
- **Fairness is engineered, not assumed.** Matched ROI windows, dynamic percentile thresholds and a gap-free LOCF spine make accounts of different size and tenure genuinely comparable.
- **Confirm before acting.** The 3-month confirmation rule stops teams reacting to a single noisy month.
- **Design around the consuming tool.** The current-state layer was built specifically to sidestep a nested group-aggregate limit in the BI tool, keeping the dashboard simple.

*Skills demonstrated: account-health scoring · window functions & gap-free time-series spines · LOCF imputation · dynamic percentile thresholds · multi-table monthly snapshot modelling · customer-facing metric design · BI delivery.*

---

[⬅ Back to portfolio home](../../README.md)
