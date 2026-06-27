# 💸 AI Usage & Cost Tracking (LLM Tokens + TTS Voice)

> Two AI features were running up third-party bills with no event-level visibility into what drove them. This project turns raw AI usage events into a per-event cost in GBP and USD, and surfaces the cost drivers so product and finance can see exactly where the money goes.

**Tech:** SQL · Databricks/Spark SQL · BI (ThoughtSpot) · Azure OpenAI & AWS Polly (cost sources)
**Role:** Design, build and delivery, end to end
**Domain:** Subscription EdTech · FinOps · AI Cost Observability

---

## Table of Contents
1. [Context & Introduction](#1-context--introduction)
2. [Problem & Objective](#2-problem--objective)
3. [Value & Who Benefits](#3-value--who-benefits)
4. [Technical Build](#4-technical-build)
5. [Output & How to Use](#5-output--how-to-use)
6. [Key Takeaways](#6-key-takeaways)

---

## 1. Context & Introduction

Two third-party AI costs were growing without clear visibility into what was driving them:

- **AWS Polly** powers the **Read Aloud** (text-to-speech) voices. Spend is charged per character synthesised, with caching meant to cut repeat calls.
- **LLM tokens** (GPT-4o-mini via Azure OpenAI) power the **Research Assistant** and **Ask The Book**. Spend is charged per input (prompt) and output (completion) token.

New tracking events were introduced for both so usage could be measured at the event grain and priced. The Polly work came first; the token tracking was a direct follow-on built on the same pattern. The two are documented and maintained together because they do the same job and share the same shape.

---

## 2. Problem & Objective

We were spending on Polly and LLM tokens with no event-level view of where the money went. The work set out to answer:

- **What drives the most cost?** Identify the primary cost drivers across events and usage patterns.
- **Is the cache working?** For Read Aloud, confirm cached audio is being served instead of re-calling Polly.
- **Which segments cost most?** Break cost down by user type, payment channel, book, voice and model.
- **What interventions reduce cost?** Surface caching, limit and feature opportunities.
- **Ongoing monitoring.** Track usage and cost trends over time so the impact of any intervention is visible.

---

## 3. Value & Who Benefits

| Stakeholder | Value delivered |
|---|---|
| **Finance** | A single, defensible **cost per event** in GBP and USD for both AI features, priced at the live FX rate on the event date. |
| **Product** | Cost sliced by the dimensions that matter (segment, payment channel, org, book, voice, model), so interventions are targeted, not guessed. |
| **Engineering** | **Cache effectiveness is measurable**: cached Read Aloud events are costed at £0, so the served-from-cache share and its saving are explicit. |

Both feeds refresh daily, so the effect of any change shows up in the same dashboards automatically, no rework needed to monitor a trend.

---

## 4. Technical Build

Both pipelines follow the same flow: take the raw tracking events, parse the JSON `event_properties`, attach the pricing reference, convert USD to GBP on the event date, and write a priced event-level table.
**Script:** [`sql/ai_usage_and_cost_tracking.sql`](sql/ai_usage_and_cost_tracking.sql)

### A. LLM token usage (Research Assistant + Ask The Book)
- **Source:** the gold event-tracking table, events `research assistant response generated` and `talk to book response generated`, from when token tracking began.
- **Parsing:** extracts `promptTokens`, `completionTokens`, `totalTokens`, `model`, `bookId`, `raId`, `threadId`, `requestId`, `location`. The `location` value distinguishes **Research Assistant** vs **Ask The Book**. The model string is split into `model_name` and `model_date` for clean grouping.
- **Pricing:** GPT-4o-mini at **$0.16 / million input tokens** and **$0.60 / million output tokens**, converted to GBP via the daily currency-exchange-rate table.
- **Enrichment:** each event carries the user's latest subscription (payment channel, org, plan, subscription type); internal users are excluded.
- **Target:** `nb_research_assistant_token_usage_event`, refreshed daily.

### B. TTS voice usage (Read Aloud)
- **Source:** the events fact table, events `get audio for book type epub` and `get audio for book type pdf`, from when the events began.
- **Two-table build:**
  - **Detail** (`nb_read_aloud_voice_usage_detail_event`): parses `bookId`, `chapterId`/`pageId`, `paragraphId`, `voiceId`, `fileFromCache`, `characterCount`.
  - **Event** (`nb_read_aloud_voice_usage_event`): joins book character counts, the voice dimension (**SCD2 date-range join** so a voice that changed tier over time is priced correctly at the event timestamp), the daily FX rate, and the per-million-character cost.
- **Cache-aware costing:** when `is_file_from_cache = TRUE` the event costs £0/$0; only genuine Polly calls are charged. This is what makes cache savings visible.
- **Target:** `nb_read_aloud_voice_usage_event`, refreshed daily.

---

## 5. Output & How to Use

Both feeds surface through the BI layer (ThoughtSpot) at several aggregation levels, so each question is answered at the right grain.

| Feature | Base view | Datamart | Aggregations |
|---|---|---|---|
| **LLM tokens** | `nb__research_assistant_token_usage_event` | `mart__research_assistant_token_usage_event` | event level |
| **Read Aloud (TTS)** | `nb__read_aloud_tts_usage_event` | `mart__read_aloud_tts_usage_event` | event, user, user+voice, book and catalogue rollups |

Use the dashboards to read total spend and trend, the cache-served share for Read Aloud, and the heaviest segments / books / users, so interventions can be aimed where the spend actually sits.

---

## 6. Key Takeaways

- **Price at the event grain.** Costing each individual event (not a monthly lump) is what lets you attribute spend to segments, books and features.
- **Make savings measurable.** Costing cached events at £0 turns "the cache should help" into a quantified served-from-cache saving.
- **Correctness in the details:** daily FX conversion on the event date and an SCD2 voice-tier join keep the numbers defensible rather than approximate.
- **One reusable pattern, two features.** The token pipeline reused the Polly pattern wholesale, cutting build time.

*Skills demonstrated: FinOps / cost modelling · JSON event parsing in SQL · SCD2 slowly-changing-dimension joins · FX-aware costing · LLM & TTS pricing models · BI delivery at multiple grains.*

---

[⬅ Back to portfolio home](../../README.md)
