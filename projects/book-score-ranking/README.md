# 📚 Book Score Ranking

> A weekly, multi-signal ranking engine that decides which books get resurfaced to users in search — blending revenue, academic demand, readership, search interest and recency into a single defensible score.

**Tech:** AWS Step Functions · AWS Athena (Presto SQL) · BigQuery · Metabase · Power BI · Git
**Role:** End-to-end design, modelling and delivery
**Domain:** Subscription EdTech · Content Discovery · Search Ranking

---

## Table of Contents
1. [Context & Introduction](#1-context--introduction)
2. [Problem & Objective](#2-problem--objective)
3. [Value & Who Benefits](#3-value--who-benefits)
4. [The Technical Build](#4-the-technical-build)
5. [Output & Results](#5-output--results)
6. [Key Takeaways](#6-key-takeaways)

---

## 1. Context & Introduction

In a subscription library with a large and constantly growing catalogue, **what users see first matters enormously**. When a reader searches, the order in which books are returned directly influences what gets read, what drives conversions, and which content feels "worth the subscription."

The original ranking process leaned on a narrow set of signals and didn't fully reflect how valuable a book actually was to the business *and* the reader. This project refines that ranking by introducing a **composite, multi-parameter score** — refreshed weekly and pushed to the third-party search provider that ultimately orders books for end users.

---

## 2. Problem & Objective

**The problem:** A single or limited ranking signal can't capture the many, sometimes competing, ways a book creates value. A book might earn little direct revenue but be heavily assigned in academic courses; another might be brand new with strong search interest but little reading history yet. Ranking on any one of these alone buries genuinely valuable titles.

**The question we set out to answer:**
> *Across every active book in the catalogue, how do we fairly and repeatably prioritise the titles most likely to be valuable to our users — and keep that priority fresh as behaviour changes week to week?*

**Objectives:**
- Combine multiple, independent value signals into one comparable score.
- Normalise signals onto a common scale so no single metric dominates by accident.
- Apply a transparent, ordered tie-breaking rule so ranking is deterministic and explainable.
- Automate the full refresh so rankings stay current with zero manual intervention.

---

## 3. Value & Who Benefits

| Stakeholder | Value delivered |
|---|---|
| **Users / Readers** | More relevant, higher-quality books surfaced first — better discovery and a stronger sense of catalogue value. |
| **Product & Search** | A defensible, data-driven ranking feed that plugs directly into the search experience. |
| **Content & Commercial** | Visibility into *why* a book ranks where it does, informing acquisition and curation decisions. |
| **Leadership** | A repeatable, automated process that ties content visibility to measurable business signals (revenue, engagement, demand). |

The core value: **ranking decisions stop being subjective and become explainable, reproducible, and refreshed automatically** — improving search-to-read outcomes while freeing the team from manual list-building.

---

## 4. The Technical Build

### 4.1 Data Sources
The score is built from six independent inputs, each capturing a different dimension of a book's value:

| # | Source | Signal it provides |
|---|---|---|
| 1 | Subscriber Revenue | Direct-to-consumer revenue attributable to a book (referrer) |
| 2 | Subscriber Registration | Sign-ups referred by a given book |
| 3 | Assigned Book Reading-list | Academic enrolment / course-mandated demand |
| 4 | Subscriber Reading Activity | Real readership and time spent reading |
| 5 | Google SEO Pages | Search interest (clicks / impressions on landing pages) |
| 6 | Book Catalogue | Book metadata, availability and publication recency |

### 4.2 Tools
- **AWS Step Functions** — orchestrates the weekly pipeline run
- **AWS Athena (Presto SQL)** — the transformation and scoring engine
- **BigQuery** — upstream data
- **Metabase & Power BI** — result visualisation and QA
- **Git** — version control for the SQL models

### 4.3 The Scoring Parameters
Each book is scored across five parameters, then ranked in a strict order of preference:

| Order | Parameter | What it measures | How it's computed |
|---|---|---|---|
| 1 | **DTC Revenue** | Direct revenue driven by the book | Min-max normalised to a 0–1000 scale |
| 2 | **Academic Mandate** | Course enrolment demand | Enrolment de-duplicated per book, then normalised |
| 3 | **Readership** | Engagement / reading time | **Bayesian average** of reading minutes (see below), then normalised |
| 4 | **Interest** | Search demand | Google landing-page clicks, normalised |
| 5 | **Newness** | Recency | Ranked by cleaned publication date, with activation/added dates as tie-breakers |

**Why a Bayesian average for readership?** A book read intensely by only a handful of users would otherwise unfairly beat a broadly-read title. Smoothing each book's average reading time toward the global average prevents low-sample books from dominating:

```
bay_read_mins = ( (all_users × global_avg_read_mins) + total_reading_mins )
                ─────────────────────────────────────────────────────────────
                            ( all_users + book_users )
```

**Normalisation.** Every raw signal is rescaled with min-max normalisation onto a common 0–1000 band so the parameters are directly comparable, with a floor applied so a present-but-small signal never collapses to zero.

### 4.4 Process Flow

The pipeline runs weekly: each parameter is computed independently over its own time window, consolidated against the list of **active books**, scored, ranked, and written to a reporting table that is then pushed to the third-party search service.

**Data Requirement Mapping**

<img width="1326" alt="Data requirement mapping" src="https://github.com/user-attachments/assets/6f834e38-aa00-4f37-94ad-194ef45e13d8">

**Data Process Flow**

<img width="997" alt="Data process flow" src="https://github.com/user-attachments/assets/7bc35171-d643-4d25-974b-0b11e91f9b9e">

### 4.5 Code

| File | Purpose |
|---|---|
| [`sql/01-create-table.sql`](sql/01-create-table.sql) | Defines the `reporting_layer.book_score_rank_data` external table (Parquet on S3) |
| [`sql/02-transform-and-load.sql`](sql/02-transform-and-load.sql) | The full scoring model — builds each parameter as a CTE, consolidates, normalises and ranks every active book |

The transformation is structured as a sequence of CTEs — one per value signal (`dtc_revenue`, `academic_mandate`, `readership`, `interest`, `newness`) — joined onto the `active_books` spine and ranked in `score_result`.

---

## 5. Output & Results

After every parameter is computed for all active books, the **overall rank** is applied in the order of parameter preference, with the tie-breaking rule resolving books that are otherwise level. The output is a fully ranked catalogue, refreshed weekly.

<img width="1077" alt="Ranking result dashboard 1" src="https://github.com/user-attachments/assets/3967a496-c8b8-478f-bc60-626ed3e7d8d4">
<img width="1079" alt="Ranking result dashboard 2" src="https://github.com/user-attachments/assets/5228af2f-46f9-47de-b2f3-abfe944ae5d5">

**Consumption:** the final ranked table is automated and pushed on a recurring schedule to the third-party search service, where it directly orders the books resurfaced to users based on their search criteria — closing the loop from raw behavioural data to the reader's screen.

---

## 6. Key Takeaways

- **Multi-signal scoring** beats any single metric for capturing "value" in a nuanced domain.
- **Statistical rigour matters:** Bayesian smoothing and min-max normalisation make signals fair and comparable.
- **Deterministic tie-breaking** keeps the ranking explainable to non-technical stakeholders.
- **Automation** turns a one-off analysis into a living product feature.

*Skills demonstrated: dimensional data modelling · advanced SQL (window functions, CTEs, Bayesian averaging) · pipeline orchestration · normalisation & scoring design · stakeholder-facing reporting.*

---

[⬅ Back to portfolio home](../../README.md)
