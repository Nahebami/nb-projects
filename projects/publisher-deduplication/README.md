# 🏷️ Publisher Deduplication (ISBN-Based Publisher Resolution)

> Real publishers were fragmented across dozens of messy name variants, distorting every publisher-level acquisition metric. This project resolves the true publisher straight from the structure of the ISBN, lifting publisher-identity accuracy from 69% to 91%.

**Tech:** Databricks (serverless) · PySpark · Python (`isbnlib`, pandas) · SQL
**Role:** Design, build and validation, end to end
**Domain:** Subscription EdTech · Data Quality · Entity Resolution · Content Acquisition

---

## Table of Contents
1. [Context & Introduction](#1-context--introduction)
2. [Problem & Objective](#2-problem--objective)
3. [Value & Who Benefits](#3-value--who-benefits)
4. [Method](#4-method)
5. [Technical Build](#5-technical-build)
6. [Results & Validation](#6-results--validation)
7. [How to Use the Output](#7-how-to-use-the-output)
8. [Limitations & Next Steps](#8-limitations--next-steps)
9. [Key Takeaways](#9-key-takeaways)

---

## 1. Context & Introduction

The Content Acquisition Hitlist scores which missing books Perlego should acquire next, using BMG US enrolment data weighted by institutional reading-list signals. One of its core outputs is a **Publisher Roll-up**: a view grained at one row per publisher, surfacing each publisher's title count, Perlego coverage %, and the average value score of their un-acquired titles, in short, *"which publishers hold the most valuable books we don't yet have."*

That roll-up is only as trustworthy as the publisher grain it sits on, and BMG publisher labels are messy. The same real-world publisher appears under many spellings and, worse, under entirely unrelated imprint names. An existing name-matching process (the "canonical" mapping, maintained by the PM) collapses obvious spelling variants but cannot recover cases where one publisher trades under names that look nothing alike.

This project introduces an **ISBN-based publisher resolution** method that reads the publisher directly from the structure of the ISBN itself, producing a far more accurate publisher grain.

---

## 2. Problem & Objective

**The problem.** Publisher metrics in the hitlist roll-up are distorted because a single real publisher is fragmented across multiple names:

- **Spelling / formatting variants** of the same name (e.g. `W. W. NORTON & COMPANY` vs `W.W. NORTON & COMPANY`).
- **Unrelated imprint names** owned by one parent (e.g. Vintage, Crown, Signet and Knopf all being Penguin Random House; academic titles mislabelled as `MACMILLAN PUBLISHING/ INC.` that are actually Bloomsbury).
- **Distributor / supplier mislabels**, where the listed "publisher" is a wholesaler, not the real publisher.

Because of this, a publisher's true title count, coverage %, and "most valuable un-acquired books" are scattered across phantom rows. The Content team cannot reliably read genuine publisher-level demand, so they cannot confidently prioritise which publishers to approach.

**The objective.** Produce an accurate, consolidated publisher identity per ISBN, so the existing roll-up metrics mean what they claim and the Content team can act on real publisher signals.

---

## 3. Value & Who Benefits

The value is unlocked downstream in the Content Acquisition roll-up. Every roll-up metric is grained on publisher, so fixing the grain fixes the metric:

| Roll-up metric | Why duplication breaks it | What dedup restores |
|---|---|---|
| Number of Titles (per publisher) | One publisher's titles split across several name rows | A true catalogue size per publisher |
| Perlego Title Coverage % | Coverage looks artificially low/high on each fragment | An honest "how much of this publisher do we already have" |
| Title Share % (Not on Perlego) | Acquisition opportunity diluted across phantom names | A clear view of which publishers dominate the opportunity |
| AVG Value Score (Not on Perlego) | "Most valuable un-acquired books" is mis-attributed | Reliable ranking of which publishers hold the best un-acquired titles |

| Stakeholder | Value delivered |
|---|---|
| **Content / Acquisition team** | Rank genuine publishers by un-acquired value and coverage gap, and approach the ones that actually expand demand-weighted coverage, instead of chasing fragmented or mislabelled rows. |
| **Leadership** | Acquisition decisions made on real signals, not metadata noise. |
| **Customers (students & institutions)** | Better-targeted acquisition means high-demand reading-list titles are more likely to reach the platform, so the book a student needs is more likely to be available. |

---

## 4. Method

Three publisher groupings are computed side by side on the same input, so they can be compared directly:

| Grouping | What it is | How it works |
|---|---|---|
| `group_variant_name` | The old raw, name-only grouping (baseline) | Union-find (DSU) over normalised raw labels with token-overlap and anchor-token rules |
| `group_canonical_name` | The current production method | Driven by the signed-off canonical name mapping (variant to canonical) |
| `group_isbn_name` | **The new method** | Validate the ISBN, extract the **registrant element** to identify the publisher, roll imprints to their parent where known, and name the cluster from Perlego's own publisher authority where the book is on-platform (ground truth), falling back to the ISBN-derived name otherwise |

A `publisher_best` field then picks the most reliable available name per ISBN, in strict trust priority:

> **Perlego authority** > **ISBN-derived** (where the ISBN resolved) > **Canonical** (where the mapping matched) > **raw BMG label**

The key insight: an ISBN's registrant element is assigned to a single publisher, so it survives spelling chaos and imprint renaming that defeat name matching.

---

## 5. Technical Build

**Environment.** Databricks (serverless), PySpark. ISBN parsing uses `isbnlib`. On serverless there are no cluster libraries, so `isbnlib` is added in the notebook Environment panel (Add dependency, then Apply).

**Notebook.** [`src/publisher_resolution_databricks.py`](src/publisher_resolution_databricks.py) reads the input table, runs all three groupings with enrichments, and writes the output. The parameters cell opens with `dbutils.widgets.removeAll()` to clear stale widget values, since Databricks does not refresh an existing widget's value when only the code default changes.

**Core logic, in brief:**
- `registrant()` validates an ISBN-13 and uses `isbnlib.mask()` to extract the registration-group + registrant prefix that identifies the publisher.
- `resolve_isbn()` groups books by registrant, names each cluster from Perlego's authority label where available (majority vote), and otherwise from the most common non-distributor BMG label, then rolls to parent via an imprint crosswalk.
- `resolve_name_only()` reproduces the old baseline with a disjoint-set (union-find) over normalised tokens, gated by "anchor" tokens (rare, informative words) to avoid over-merging on generic words like *press* or *publishing*.
- A `DISTRIBUTORS` regex strips wholesalers (Ingram, Publishers Group West, etc.) so a distributor never names a cluster.

**Tables**

| Role | Table (generic placeholders) |
|---|---|
| Input | `content_acquisition_baseline_model` |
| Canonical mapping (signed-off) | `publisher_name_mapping` |
| Publisher authority (ground truth) | `publisher_authority` |
| Output | `publisher_dedup_mapping_data` |

Output is written with overwrite + overwriteSchema. The join back to the input is on a cleaned ISBN, `regexp_replace(isbn_id, '[^0-9]', '')`.

---

## 6. Results & Validation

The method was run over **347,935 books**, with accuracy measured on the ~**31,500** books verifiable against Perlego's own publisher authority (the on-platform slice = ground truth):

| Method | Matches Perlego ground truth |
|---|---|
| `group_canonical_name` (current) | **69.3%** |
| `group_isbn_name` (new) | **91.2%** |

- **Where the two methods disagree, ISBN is right ~24x more often** (7,178 ISBN-only-correct vs 300 canonical-only-correct).
- **Consolidation:** ~17,699 raw BMG labels → ~10,440 canonical groups → ~7,587 ISBN groups.
- **Worked example:** ~1,709 books labelled `MACMILLAN PUBLISHING/ INC.` resolve to **Bloomsbury Publishing** via the ISBN registrant. Bloomsbury acquired Rowman & Littlefield's academic list, which shares those registrant blocks, a link no name match could ever make.

The notebook ships with SQL cells that print the headline accuracy, a per-book verdict breakdown (`isbn_only_match`, `canonical_only_match`, etc.), the distinct-publisher consolidation counts, and a **review queue** of the biggest disagreements for human sign-off.

---

## 7. How to Use the Output

The output table `publisher_dedup_mapping_data` has **one row per ISBN**, carrying all three group names, `publisher_best`, the resolution flags, and per-method agreement/accuracy fields.

- For publisher-level reporting and the Content Acquisition roll-up, group on **`group_isbn_name`** (or `publisher_best`) instead of the raw BMG publisher.
- For downstream filters that previously excluded a hand-maintained list of messy spellings, filter on `group_isbn_name` instead, the consolidated names replace dozens of variant strings with a handful.
- If `group_isbn_name` is not present on a downstream table, join this mapping on cleaned `isbn_id` to bring it in.

---

## 8. Limitations & Next Steps

- **Imprint-to-parent crosswalk is a stub.** Some parent groups (notably Penguin Random House) do not yet absorb all their imprints, so Random House, Vintage, Knopf, etc. remain separate groups. Account for this when rolling up or excluding a parent. Replacing the stub with the reviewed imprint sheet is the main next step.
- **Accuracy is only measurable on the on-platform slice** (books with a Perlego ground-truth label). Off-platform resolution is trusted by construction (ISBN registrant) but not independently verified.
- Status: **validated, pending review.**

---

## 9. Key Takeaways

- **Structure beats strings.** Resolving identity from the ISBN's registrant element sidesteps the entire class of spelling and imprint-renaming problems that defeat name matching.
- **Validate against ground truth.** Measuring both methods against Perlego's own labels turned "I think this is better" into "91% vs 69%, and 24x more often right on disagreements", a number a stakeholder can sign off on.
- **Trust hierarchies make outputs safe to consume.** `publisher_best` with an explicit `publisher_best_source` lets downstream users see exactly how confident each name is.
- **Fix the grain, fix every metric.** A single grain correction repaired four separate roll-up metrics at once.

*Skills demonstrated: entity resolution · PySpark at scale (~348K rows) · ISBN/`isbnlib` domain modelling · union-find algorithms · ground-truth validation design · data-quality engineering · stakeholder-ready reporting.*

---

[⬅ Back to portfolio home](../../README.md)
