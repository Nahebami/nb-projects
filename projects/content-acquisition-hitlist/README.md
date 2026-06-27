# 🎯 Content Acquisition Hitlist

> A demand-led acquisition hitlist: which missing titles matter most to our users, scored 1-100 by validated demand. It blends US university enrolment data with 15 institutional reading lists to rank the books Perlego should acquire next.

**Tech:** SQL · Databricks/Spark SQL · BI (ThoughtSpot)
**Role:** Design, build and delivery, end to end
**Domain:** Subscription EdTech · Content Strategy · Demand Modelling

> 🔗 **Related project:** the [Publisher Deduplication](../publisher-deduplication) model consumes this model's output to fix the publisher grain on the acquisition roll-up.

---

## Table of Contents
1. [Context & Introduction](#1-context--introduction)
2. [Problem & Objective](#2-problem--objective)
3. [Value & Who Benefits](#3-value--who-benefits)
4. [Method](#4-method)
5. [Output & How to Use](#5-output--how-to-use)
6. [Key Takeaways](#6-key-takeaways)

---

## 1. Context & Introduction

The content team needs to decide which books to acquire next. The strongest signal of demand is what universities actually assign to students, captured in **BMG** enrolment data (US reading lists). On its own BMG is US-skewed, so the model layers in **15 institutional / partner reading lists** to broaden coverage and validate demand beyond the US.

---

## 2. Problem & Objective

Answer one core question: **which titles not yet on Perlego matter most to our users?**

The objective is a single, comparable score per ISBN that ranks unacquired titles by validated demand, plus publisher-level roll-ups so the team can see where the most valuable gaps sit.

---

## 3. Value & Who Benefits

| Output | What it gives the team |
|---|---|
| **Value score (1-100)** per ISBN | Log-normalised so no single outlier distorts the ranking |
| Ranked **hitlist** | The highest-priority unacquired titles to go after |
| **Publisher roll-ups** | Where the most valuable unacquired titles concentrate |
| **Reading-list presence flags** | Which lists each title appears on |
| **Sales-rights flags** (US / UK / global) | Supporting context for deeper prioritisation |

**Bottom line:** the content acquisition team gets a defensible, demand-led order in which to acquire titles, instead of acquiring on intuition. Enrolment proves real classroom demand, the reading-list layer validates and broadens it beyond the US, and the publisher roll-ups point straight at the publishers holding the most valuable gaps, sharpening both acquisition and publisher negotiations.

---

## 4. Method

**Script:** [`sql/content_acquisition_baseline_model.sql`](sql/content_acquisition_baseline_model.sql) - three sections, run top to bottom.

### Section 1: BMG matching (`nb_bmg_matches_revamp`)
Matches BMG ISBNs to the Perlego catalogue and attaches availability, sales rights and enrolment.
- **Exact match** on ISBN to a live Perlego book, then **algorithm match** via the enriched ISBNDB table, prioritising available books and the highest match score.
- `perlego_match_status = TRUE` only when matched, not a Big-4 publisher we do not carry, **algo match score ≥ 0.94**, and the book is live.
- Adds **US / UK / global sales-right flags** and a global country count from book country access.
- Aggregates schools and enrolment per ISBN.

### Section 2: Baseline model, all publishers (`nb_content_acquisition_all_baseline_model`)
The full scoring model across every publisher.
- **Aggregate enrolment per ISBN** as the raw demand baseline (0-enrolment ISBNs are set to the source average of 23 so they do not break the multiplier; < 0.1% of cases).
- **Reading-list master:** all 15 lists unioned with a tier weight - High = 2.0, Medium = 1.5, Low = 1.0. Adding a list is a single `UNION ALL` block.
- **Two parallel multipliers:**
  - **M1 (equal weight):** `enrolment × (1 + total RL count)`
  - **M2 (tier weighted, used for the value score):** `enrolment × (1 + RL score)`
- **Value score (1-100):** log-normalised adjusted enrolment, `1 + (log-normalised value) × 99`, produced for both M1 and M2, plus a value rank.
- A boolean flag per reading list is materialised for filtering.

### Section 3: Baseline model, exclusions (`nb_content_acquisition_excl_baseline_model`)
Identical logic to Section 2 but **excludes the Big-4 / Penguin / OUP imprint family** (a curated list of imprint name variants), giving a cleaner hitlist focused on publishers we can realistically acquire.

**Why log-normalisation?** Enrolment is heavily skewed - a handful of mega-courses would otherwise dominate the 1-100 scale and flatten everything else. Log-normalising compresses the long tail so the score discriminates across the whole catalogue, not just the top few titles.

---

## 5. Output & How to Use

Surfaced in the BI layer (ThoughtSpot) at book/ISBN grain and publisher-roll-up grain.

**To build a hitlist:**
1. Filter `perlego_match_status = FALSE` (the unacquired titles).
2. Sort by `m2_value_score` descending.
3. Use `perlego_match_status_reason` to understand why each is unmatched (e.g. Big-4 publisher, low match score, on Perlego but not live).

The publisher roll-up ranks where the most valuable unacquired titles sit, via the average value score for titles not on Perlego.

---

## 6. Key Takeaways

- **Validated demand beats raw demand.** Enrolment alone is US-skewed; layering 15 reading lists with tiered weights both broadens and validates the signal.
- **Tunable by design.** Two multipliers (equal vs tier-weighted) and a one-block-per-list structure make the model easy to extend and reason about.
- **Score shape matters.** Log-normalisation keeps a skewed metric usable across the full 1-100 range.
- **Feeds the wider system.** This model's output is the input to the [Publisher Deduplication](../publisher-deduplication) work, which cleans the publisher grain on the roll-up.

*Skills demonstrated: demand modelling · weighted scoring design · log-normalisation · fuzzy/algorithmic ISBN matching · large multi-source SQL · BI delivery.*

---

[⬅ Back to portfolio home](../../README.md)
