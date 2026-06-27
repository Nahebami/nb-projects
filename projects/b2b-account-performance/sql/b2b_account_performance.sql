/* =====================================================================
   B2B ACCOUNT PERFORMANCE - MONTHLY SNAPSHOT PIPELINE
   ---------------------------------------------------------------------
   Builds the monthly B2B reporting stack in five sequential steps. Steps
   1-4 produce single-metric snapshot tables; Step 5 joins them into the
   account-health model that downstream dashboards consume.

     Step 1  License allocation   -> nb_b2b_license_allocation_monthly_snapshot
     Step 2  MRR                   -> nb_b2b_mrr_monthly_snapshot
     Step 3  Active subscriptions  -> nb_b2b_active_subs_monthly_snapshot
     Step 4  Value of books read   -> nb_b2b_book_value_monthly_snapshot
     Step 5  Account health + KPIs -> nb_b2b_account_performance_monthly_snapshot

   Run order matters: Step 5 reads the outputs of Steps 1-4, so run the
   steps top to bottom. All steps are written to be safely re-runnable.
   ===================================================================== */


/* =====================================================================
   STEP 1 - B2B LICENSE ALLOCATION  (monthly snapshot)
   ---------------------------------------------------------------------
   Captures the number of contracted licenses (seats) allocated to each
   B2B organisation as a point-in-time snapshot dated to the 1st of the
   current month.

   Source : dim__organisations -> dim__plans -> dim__b2b_bundles
   Target : nb_b2b_license_allocation_monthly_snapshot
   Grain  : one row per organisation per snapshot_month

   Reload : the current month's snapshot is deleted then re-inserted on
            every run, so re-running within the same month is idempotent.
            Prior months are never touched.
   ===================================================================== */

-- Clear the current month so the re-insert below does not duplicate it.
DELETE FROM reporting_layer.ad_hoc.nb_b2b_license_allocation_monthly_snapshot
WHERE date(snapshot_month) >= date_trunc('MONTH', current_timestamp);

/* ---------------------------------------------------------------------
   ONE-OFF HISTORICAL BACKFILL (run once, then leave commented out).
   Loads every month prior to the first live snapshot (2026-05) from the
   legacy monthly table, so the snapshot history is complete from launch.
   --------------------------------------------------------------------- */
-- INSERT INTO reporting_layer.ad_hoc.nb_b2b_license_allocation_monthly_snapshot
-- SELECT month_date AS snapshot_month, organisation_id, organisation_name,
--        allocated_license AS b2b_allocated_licenses, current_timestamp AS updated_at
-- FROM reporting_layer.ad_hoc.nb_b2b_license_allocation_by_month_2
-- WHERE organisation_id IS NOT NULL
--   AND date(month_date) < date'2026-05-01';   -- live snapshots begin 2026-05

INSERT INTO reporting_layer.ad_hoc.nb_b2b_license_allocation_monthly_snapshot
WITH current_license_allocation AS (
    -- Sum allocated seats per org, counting only live bundles on live plans.
    -- A deleted bundle or plan contributes NULL (excluded), defaulting to 0.
    SELECT
        org.organisation_id,
        org.organisation_name,
        IFNULL(SUM(CASE
            WHEN bundle.b2b_bundle_is_deleted = FALSE
             AND plan.plan_is_deleted        = FALSE
            THEN bundle.b2b_bundle_subscription_count
            ELSE NULL
        END), 0) AS b2b_allocated_licenses
    FROM reporting_layer.prod.dim__organisations org
    LEFT JOIN reporting_layer.prod.dim__plans plan
        ON org.organisation_id = plan.organisation_id
    LEFT JOIN reporting_layer.prod.dim__b2b_bundles bundle
        ON plan.plan_id = bundle.plan_id
    GROUP BY 1, 2
),

-- De-duplicate to one row per organisation_id, keeping the highest seat count.
-- NOTE: currently not selected downstream (dedup_by_name is used instead).
--       Retained as the id-grain alternative if name collisions ever need it.
dedup_by_id AS (
    SELECT organisation_id, organisation_name, b2b_allocated_licenses
    FROM (
        SELECT organisation_id, organisation_name, b2b_allocated_licenses,
               ROW_NUMBER() OVER (
                   PARTITION BY organisation_id
                   ORDER BY b2b_allocated_licenses DESC) AS rnk
        FROM current_license_allocation
        QUALIFY rnk = 1
    )
),

-- De-duplicate to one row per organisation_name, keeping the highest seat
-- count. This is the grain written to the snapshot table.
dedup_by_name AS (
    SELECT organisation_id, organisation_name, b2b_allocated_licenses
    FROM (
        SELECT organisation_id, organisation_name, b2b_allocated_licenses,
               ROW_NUMBER() OVER (
                   PARTITION BY organisation_name
                   ORDER BY b2b_allocated_licenses DESC) AS rnk
        FROM current_license_allocation
        QUALIFY rnk = 1
    )
)

SELECT
    date_trunc('MONTH', current_timestamp) AS snapshot_month,
    organisation_id,
    organisation_name,
    b2b_allocated_licenses,
    current_timestamp                      AS updated_at
FROM dedup_by_name
;


/* =====================================================================
   STEP 2 - B2B MRR  (monthly snapshot)
   ---------------------------------------------------------------------
   Captures monthly recurring revenue per active B2B organisation, plus
   the account attributes used later for tiering and tenure.

   Source : gold_hubspot_company
   Target : nb_b2b_mrr_monthly_snapshot
   Grain  : one row per organisation per snapshot_month

   Reload : deletes the current month (and anything beyond it) then
            re-inserts, so re-running within the month is idempotent.
   ===================================================================== */

-- Clear the current month onward so the re-insert does not duplicate it.
DELETE FROM reporting_layer.ad_hoc.nb_b2b_mrr_monthly_snapshot
WHERE date(snapshot_month) >= date_trunc('MONTH', current_timestamp);

/* ---------------------------------------------------------------------
   ONE-OFF HISTORICAL BACKFILL (run once, then leave commented out).
   Loads months prior to the first live snapshot (2026-05) from the
   legacy historical MRR table.
   --------------------------------------------------------------------- */
-- INSERT INTO reporting_layer.ad_hoc.nb_b2b_mrr_monthly_snapshot
-- SELECT month_date AS snapshot_month, organisation_id, organisation_name, mrr,
--        internal_tiering_category, first_contract_start_date,
--        b_2_b_active_partnership, current_timestamp AS updated_at
-- FROM reporting_layer.ad_hoc.nb_b2b_mrr_by_month_historical_upd
-- WHERE date(month_date) < date'2026-05-01';   -- live snapshots begin 2026-05

INSERT INTO reporting_layer.ad_hoc.nb_b2b_mrr_monthly_snapshot
WITH mrr_base AS (
    -- One row per org, keeping the record with the highest MRR.
    -- Restricted to active B2B partnerships, which is the population the
    -- forward snapshot tracks.
    SELECT
        perlego_organisation_id   AS organisation_id,
        perlego_organisation_name AS organisation_name,
        COALESCE(company_mrr, 0)  AS mrr,
        internal_tiering_category,
        first_contract_start_date,
        b_2_b_active_partnership,
        ROW_NUMBER() OVER (
            PARTITION BY perlego_organisation_id
            ORDER BY COALESCE(company_mrr, 0) DESC) AS rnk
    FROM data_platform.prod.gold_hubspot_company
    WHERE b_2_b_active_partnership > 0          -- active B2B accounts only
      AND perlego_organisation_id IS NOT NULL
    QUALIFY rnk = 1                             -- enforce one row per org
    ORDER BY perlego_organisation_id
)

SELECT
    date_trunc('MONTH', current_timestamp) AS snapshot_month,
    organisation_id,
    organisation_name,
    mrr,
    internal_tiering_category,
    first_contract_start_date,
    b_2_b_active_partnership,
    current_timestamp                      AS updated_at
FROM mrr_base
;


/* =====================================================================
   STEP 3 - B2B ACTIVE SUBSCRIPTIONS  (monthly snapshot)
   ---------------------------------------------------------------------
   Counts active indirect (B2B) subscriptions and distinct active users
   per organisation per month, then derives rolling-12-month and
   cumulative totals across a gap-free monthly spine.

   Source : fct__subscriptions, dim__organisations, dim__users
   Target : nb_b2b_active_subs_monthly_snapshot
   Grain  : one row per organisation per subscription_month

   Reload : full rebuild - the table is truncated and rewritten each run
            because every month is recomputed from source.
   ===================================================================== */

-- Full rebuild: every month is recomputed below, so clear the table first.
DELETE FROM reporting_layer.ad_hoc.nb_b2b_active_subs_monthly_snapshot;

INSERT INTO reporting_layer.ad_hoc.nb_b2b_active_subs_monthly_snapshot
WITH date_spine AS (
    -- Contiguous month series from 2017-01 to the current month. A generated
    -- spine (vs DISTINCT months from source) guarantees no missing months,
    -- which keeps the rolling-window maths correct.
    SELECT DATE_TRUNC('MONTH', ADD_MONTHS(CURRENT_DATE(), -pos)) AS subscription_month
    FROM (
        SELECT EXPLODE(SEQUENCE(0, MONTHS_BETWEEN(CURRENT_DATE(), '2017-01-01')::INT)) AS pos
    )
),

org_spine AS (
    -- Distinct organisations to cross-join against the date spine, so every
    -- org gets a complete monthly history (zero-filled where inactive).
    SELECT DISTINCT organisation_id, organisation_name
    FROM reporting_layer.prod.dim__organisations
    WHERE organisation_id IS NOT NULL
),

monthly_subscription AS (
    -- Distinct active users / subscriptions per org per month.
    --   active_indirect_users        : subscribed + indirect channel
    --   active_indirect_subscriptions : the above AND processing_rule = active
    SELECT
        DATE_TRUNC('MONTH', CAST(sub.subscription_start_time AS TIMESTAMP)) AS subscription_month,
        org.organisation_id,
        org.organisation_name,
        COUNT(DISTINCT CASE
            WHEN LOWER(sub.subscription_type) = 'subscribed'
             AND LOWER(sub.payment_channel)  = 'indirect'
            THEN sub.user_id
        END) AS active_indirect_users,
        COUNT(DISTINCT CASE
            WHEN LOWER(sub.subscription_type) = 'subscribed'
             AND LOWER(sub.payment_channel)  = 'indirect'
             AND LOWER(sub.processing_rule)  = 'active'
            THEN sub.user_id
        END) AS active_indirect_subscriptions
    FROM reporting_layer.prod.fct__subscriptions sub
    JOIN reporting_layer.prod.dim__organisations org
        ON sub.organisation_id = org.organisation_id
    JOIN reporting_layer.prod.dim__users usr
        ON sub.user_id = usr.user_id
    GROUP BY subscription_month, org.organisation_id, org.organisation_name
),

final_monthly_subscription AS (
    -- Lay the actual counts onto the full org x month grid, zero-filling
    -- months where an org had no activity.
    SELECT
        ds.subscription_month,
        os.organisation_id,
        os.organisation_name,
        IFNULL(mc.active_indirect_subscriptions, 0) AS active_subscriptions,
        IFNULL(mc.active_indirect_users, 0)         AS active_users
    FROM date_spine ds
    CROSS JOIN org_spine os
    LEFT JOIN monthly_subscription mc
        ON ds.subscription_month = mc.subscription_month
       AND os.organisation_id    = mc.organisation_id
)

SELECT
    subscription_month,
    organisation_id,
    organisation_name,
    active_subscriptions,
    -- Trailing 12-month total (current month + 11 prior).
    SUM(active_subscriptions) OVER (
        PARTITION BY organisation_id, organisation_name
        ORDER BY subscription_month
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS rolling_12m_active_subscriptions,
    -- Running total since the start of the spine.
    SUM(active_subscriptions) OVER (
        PARTITION BY organisation_id, organisation_name
        ORDER BY subscription_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_active_subscriptions,
    active_users,
    SUM(active_users) OVER (
        PARTITION BY organisation_id, organisation_name
        ORDER BY subscription_month
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS rolling_12m_active_users,
    SUM(active_users) OVER (
        PARTITION BY organisation_id, organisation_name
        ORDER BY subscription_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_active_users,
    current_timestamp AS updated_at
FROM final_monthly_subscription
WHERE subscription_month <= date_trunc('MONTH', current_timestamp)  -- cap output at the current month
;


/* =====================================================================
   STEP 4 - VALUE OF BOOKS READ  (monthly snapshot)
   ---------------------------------------------------------------------
   Values the books read by each organisation each month, plus reader and
   title counts. Each (org, user, book) is valued once (first read only),
   so the value reflects unique consumption rather than repeat opens.

   Source : fct__reading_activity, dim__books, fct__subscriptions,
            dim__organisations
   Target : nb_b2b_book_value_monthly_snapshot
   Grain  : one row per organisation per reading_month

   Reload : full rebuild - truncated and rewritten each run.
   ===================================================================== */

-- Full rebuild: every month is recomputed below, so clear the table first.
DELETE FROM reporting_layer.ad_hoc.nb_b2b_book_value_monthly_snapshot;

INSERT INTO reporting_layer.ad_hoc.nb_b2b_book_value_monthly_snapshot
WITH date_spine AS (
    -- Contiguous month series from 2017-01 to the current month (keeps the
    -- rolling/cumulative windows gap-free).
    SELECT DATE_TRUNC('MONTH', ADD_MONTHS(CURRENT_DATE(), -pos)) AS reading_month
    FROM (
        SELECT EXPLODE(SEQUENCE(0, MONTHS_BETWEEN(CURRENT_DATE(), '2017-01-01')::INT)) AS pos
    )
),

org_spine AS (
    SELECT DISTINCT organisation_id, organisation_name
    FROM reporting_layer.prod.dim__organisations
),

book_prices AS (
    -- One GBP price per book, with currency fallback:
    --   use GBP ex-VAT if present; else convert USD at 0.83; else EUR at 0.85.
    SELECT
        book_id,
        book_is_available,
        IFNULL(SUM(CASE
            WHEN gbp_price_exvat > 0                          THEN gbp_price_exvat
            WHEN gbp_price_exvat = 0 AND usd_price_exvat > 0  THEN (usd_price_exvat * 0.83)
            WHEN gbp_price_exvat = 0 AND usd_price_exvat = 0  THEN (eur_price_exvat * 0.85)
            ELSE 0
        END), 0) AS book_price_gbp
    FROM reporting_layer.prod.dim__books
    GROUP BY book_id, book_is_available
),

reading_activity_base AS (
    -- Indirect (B2B) reading events, priced, with a per-(org, user, book)
    -- sequence so we can value only the first read of each title per user.
    SELECT
        DATE_TRUNC('MONTH', CAST(ra.read_date AS TIMESTAMP)) AS reading_month,
        org.organisation_id,
        org.organisation_name,
        ra.user_id,
        ra.book_id,
        books.book_price_gbp,
        ROW_NUMBER() OVER (
            PARTITION BY org.organisation_id, ra.user_id, ra.book_id
            ORDER BY ra.read_date ASC) AS user_book_occurrence
    FROM reporting_layer.prod.fct__reading_activity ra
    JOIN book_prices books
        ON ra.book_id = books.book_id
    LEFT JOIN reporting_layer.prod.fct__subscriptions sub
        ON ra.subscription_key_id = sub.subscription_key_id
    JOIN reporting_layer.prod.dim__organisations org
        ON sub.organisation_id = org.organisation_id
    WHERE LOWER(sub.payment_channel)  = 'indirect'
      AND LOWER(sub.subscription_type) = 'subscribed'
),

first_seen_users AS (
    -- First month each user appears, per org (basis for "new readers").
    SELECT organisation_id, organisation_name, user_id,
           MIN(reading_month) AS first_seen_month
    FROM reading_activity_base
    GROUP BY organisation_id, organisation_name, user_id
),

first_seen_books AS (
    -- First month each book appears, per org (basis for "new books").
    SELECT organisation_id, organisation_name, book_id,
           MIN(reading_month) AS first_seen_month
    FROM reading_activity_base
    GROUP BY organisation_id, organisation_name, book_id
),

monthly_new_readers AS (
    -- Count of readers reading for the first time in a given month.
    SELECT first_seen_month AS reading_month, organisation_id, organisation_name,
           COUNT(DISTINCT user_id) AS new_unique_readers
    FROM first_seen_users
    GROUP BY 1, 2, 3
),

monthly_new_books AS (
    -- Count of books read for the first time in a given month.
    SELECT first_seen_month AS reading_month, organisation_id, organisation_name,
           COUNT(DISTINCT book_id) AS new_unique_books
    FROM first_seen_books
    GROUP BY 1, 2, 3
),

reading_book_value AS (
    -- Per org per month: distinct readers, distinct books, and the value of
    -- first-read titles only (user_book_occurrence = 1).
    SELECT
        reading_month,
        organisation_id,
        organisation_name,
        COUNT(DISTINCT user_id) AS unique_readers,
        COUNT(DISTINCT book_id) AS unique_books,
        IFNULL(SUM(CASE WHEN user_book_occurrence = 1 THEN book_price_gbp ELSE 0 END), 0)
            AS value_of_books_read_gbp
    FROM reading_activity_base
    GROUP BY 1, 2, 3
),

spine_filled AS (
    -- Lay all metrics onto the full org x month grid, zero-filling gaps.
    SELECT
        ds.reading_month,
        os.organisation_id,
        os.organisation_name,
        IFNULL(rbv.value_of_books_read_gbp, 0) AS value_of_books_read_gbp,
        IFNULL(rbv.unique_readers, 0)          AS unique_readers,
        IFNULL(rbv.unique_books, 0)            AS unique_books,
        IFNULL(mnr.new_unique_readers, 0)      AS new_unique_readers,
        IFNULL(mnb.new_unique_books, 0)        AS new_unique_books
    FROM date_spine ds
    CROSS JOIN org_spine os
    LEFT JOIN reading_book_value rbv
        ON ds.reading_month = rbv.reading_month AND os.organisation_id = rbv.organisation_id
    LEFT JOIN monthly_new_readers mnr
        ON ds.reading_month = mnr.reading_month AND os.organisation_id = mnr.organisation_id
    LEFT JOIN monthly_new_books mnb
        ON ds.reading_month = mnb.reading_month AND os.organisation_id = mnb.organisation_id
),

reading_book_value_final AS (
    -- Add cumulative and rolling-12-month windows for value, readers, books.
    -- Reader/book windows sum the NEW counts so totals stay distinct over time.
    SELECT
        reading_month,
        organisation_id,
        organisation_name,
        value_of_books_read_gbp,
        SUM(value_of_books_read_gbp) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_value_of_books_read_gbp,
        SUM(value_of_books_read_gbp) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)        AS rolling_12m_value_of_books_read_gbp,
        unique_readers,
        unique_books,
        new_unique_readers,
        new_unique_books,
        SUM(new_unique_readers) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_unique_readers,
        SUM(new_unique_readers) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)        AS rolling_12m_unique_readers,
        SUM(new_unique_books) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_unique_books,
        SUM(new_unique_books) OVER (
            PARTITION BY organisation_id, organisation_name ORDER BY reading_month
            ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)        AS rolling_12m_unique_books
    FROM spine_filled
    WHERE reading_month <= DATE_TRUNC('MONTH', current_timestamp)  -- cap at the current month
)

SELECT
    reading_month,
    organisation_id,
    organisation_name,
    value_of_books_read_gbp,
    cumulative_value_of_books_read_gbp,
    rolling_12m_value_of_books_read_gbp,
    unique_readers,
    new_unique_readers,
    cumulative_unique_readers,
    rolling_12m_unique_readers,
    unique_books,
    new_unique_books,
    cumulative_unique_books,
    rolling_12m_unique_books,
    current_timestamp AS updated_at
FROM reading_book_value_final
;



/* =====================================================================
   STEP 5 - B2B ACCOUNT HEALTH + KPI + CATEGORY LAYER
   ---------------------------------------------------------------------
   Joins the Step 1-4 snapshots into one account-health model and layers
   on KPIs and a priority-ordered health classification.

   Source : nb_b2b_mrr_monthly_snapshot, nb_b2b_license_allocation_monthly_snapshot,
            nb_b2b_active_subs_monthly_snapshot, nb_b2b_book_value_monthly_snapshot,
            gold_hubspot_company, gold_hubspot_owner, dim__organisations
   Target : nb_b2b_account_performance_monthly_snapshot
   Grain  : one row per organisation per snapshot_month

     KPIs
       arpu              = MRR / contracted seats (b2b_allocated_licenses)
       redemption_rate   = cumulative active subs / contracted seats
       engagement_l12m   = L12M unique readers / L12M active users
       avg_dlp_l12m      = L12M reading value / L12M unique books
       reallocation_l12m = L12M active users / L12M active subscriptions (supplementary)
       roi_rolling_12m   = ROI over the last 12 months (the customer-facing figure)
       roi_internal      = roi_rolling_12m * (arpu / portfolio_median_arpu)
       expansion_l12m    = contracted seats now vs 12 months ago (Yes / No / New account)

     Classification (priority order, first match wins)
       health_category                 = raw monthly classification
       consecutive_months_in_category  = streak length in the current category
       is_risk_confirmed               = risk acted on only after 3 consecutive months
       health_category_confirmed       = category that hides unconfirmed (<3m) risks

     CURRENT-STATE LAYER (new) - every org's LATEST month pinned onto all of
     its rows, so BI tools can show / group / colour the current state with
     NO group-aggregate formula (and therefore no nesting errors). Columns:
       is_latest_month                   = TRUE on each org's most recent month
       current_l12m_mrr_gbp              = rolling_12m_mrr_gbp                  @ latest month
       current_l12m_reading_value_gbp    = rolling_12m_value_of_books_read_gbp  @ latest month
       current_redemption_rate           = redemption_rate                     @ latest month
       current_engagement_l12m           = engagement_l12m                     @ latest month
       current_avg_dlp_l12m              = avg_dlp_l12m                        @ latest month
       current_roi_rolling_12m           = roi_rolling_12m                     @ latest month
       current_roi_internal              = roi_internal                        @ latest month
       current_monthly_arpu              = arpu                                @ latest month
       current_annual_arpu               = arpu * 12                           @ latest month
       current_12m_assigned_subscriptions = rolling_12m_assigned_subscriptions @ latest month
       current_12m_assigned_users         = rolling_12m_assigned_users         @ latest month
       current_cum_assigned_subscriptions = cumulative_assigned_subscriptions  @ latest month
       current_cum_assigned_users         = cumulative_assigned_users          @ latest month
       current_contracted_seats          = b2b_allocated_licenses              @ latest month
       current_expansion_l12m            = expansion_l12m                      @ latest month
       current_health_category           = health_category                    @ latest month
       current_health_category_confirmed = health_category_confirmed           @ latest month
       current_health_category_priority  = health_category_priority            @ latest month
       current_reallocation_trend_flag   = reallocation_trend_flag (3m trend)  @ latest month
     Build the summary table by filtering is_latest_month = true (one row per
     org, every column native) OR drop a current_* column straight onto the
     monthly pivot.

   DEFINITIONS - two metrics are deliberately seat/book based:
     * ARPU is per CONTRACTED SEAT (not per active sub). The portfolio
       median ARPU lands around GBP5.86 on this basis.
     * Avg DLP is per UNIQUE BOOK (not per reader). A per-reader variant is
       given on that line if the denominator ever needs to change.

   Reload : full rebuild - truncated and rewritten each run.
   ===================================================================== */

/* ---------------------------------------------------------------------
   ONE-TIME MIGRATION - run ONCE, then remove/skip on scheduled runs.
   The recurring job below is DELETE + INSERT INTO a fixed-schema table, so
   the new current_* columns must exist on the target first. (Alternatively,
   replace the DELETE + INSERT pattern with CREATE OR REPLACE TABLE ... AS
   and you can drop this ALTER entirely, since the schema is rebuilt each run.)
   --------------------------------------------------------------------- */

-- Full rebuild: every month is recomputed below, so clear the table first.
DELETE FROM reporting_layer.ad_hoc.nb_b2b_account_performance_monthly_snapshot;

INSERT INTO reporting_layer.ad_hoc.nb_b2b_account_performance_monthly_snapshot
-- CREATE TABLE reporting_layer.ad_hoc.nb_b2b_account_performance_monthly_snapshot AS 
WITH
date_spine AS (
    -- Contiguous month series from 2017-01 to the current month.
    SELECT DATE_TRUNC('MONTH', ADD_MONTHS(CURRENT_DATE(), -pos)) AS snapshot_month
    FROM (SELECT EXPLODE(SEQUENCE(0, MONTHS_BETWEEN(CURRENT_DATE(), DATE'2017-01-01')::INT)) AS pos)
),

mrr_raw AS (
    -- Active-partnership MRR snapshots, straight from Step 2's table.
    SELECT snapshot_month, organisation_id, organisation_name, mrr,
           internal_tiering_category, first_contract_start_date, b_2_b_active_partnership
    FROM reporting_layer.ad_hoc.nb_b2b_mrr_monthly_snapshot
    WHERE b_2_b_active_partnership > 0
),

mrr_org AS (
    -- One row per org: stable name + earliest contract start (the org's
    -- anchor attributes used to bound its history below).
    SELECT organisation_id,
           MAX(organisation_name)        AS organisation_name,
           MIN(first_contract_start_date) AS first_contract_start_date
    FROM mrr_raw
    GROUP BY organisation_id
),

first_mrr AS (
    -- First month each org actually paid (MRR > 0).
    SELECT organisation_id,
           MIN(CASE WHEN mrr > 0 THEN snapshot_month END) AS first_mrr_month
    FROM mrr_raw
    GROUP BY organisation_id
),

mrr_spine AS (
    -- Every org placed on the month grid from its contract start to now.
    SELECT ds.snapshot_month, o.organisation_id, o.organisation_name,
           r.mrr AS mrr_snapshot
    FROM date_spine ds
    CROSS JOIN mrr_org o
    LEFT JOIN mrr_raw r
        ON ds.snapshot_month = r.snapshot_month AND o.organisation_id = r.organisation_id
    WHERE ds.snapshot_month >= DATE_TRUNC('MONTH', o.first_contract_start_date)
      AND ds.snapshot_month <= DATE_TRUNC('MONTH', CURRENT_TIMESTAMP)
),

mrr_locf AS (
    -- Carry the last known MRR forward over months with no snapshot
    -- (last-observation-carried-forward); default to 0 before the first.
    SELECT snapshot_month, organisation_id, organisation_name,
           COALESCE(LAST(mrr_snapshot, true) OVER (
               PARTITION BY organisation_id ORDER BY snapshot_month
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 0) AS mrr_gbp
    FROM mrr_spine
),

mrr_final AS (
    -- Add cumulative and rolling-12-month MRR.
    SELECT snapshot_month, organisation_id, organisation_name, mrr_gbp,
           SUM(mrr_gbp) OVER (PARTITION BY organisation_id ORDER BY snapshot_month
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_mrr_gbp,
           SUM(mrr_gbp) OVER (PARTITION BY organisation_id ORDER BY snapshot_month
               ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)        AS rolling_12m_mrr_gbp
    FROM mrr_locf
),

license_raw AS (
    -- Seat snapshots from Step 1's table.
    SELECT snapshot_month, organisation_id, b2b_allocated_licenses
    FROM reporting_layer.ad_hoc.nb_b2b_license_allocation_monthly_snapshot
),

license_locf AS (
    -- Carry the last known seat count forward over gap months; default 0.
    SELECT ds.snapshot_month, o.organisation_id,
           COALESCE(LAST(l.b2b_allocated_licenses, true) OVER (
               PARTITION BY o.organisation_id ORDER BY ds.snapshot_month
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 0) AS b2b_allocated_licenses
    FROM date_spine ds
    CROSS JOIN mrr_org o
    LEFT JOIN license_raw l
        ON ds.snapshot_month = l.snapshot_month AND o.organisation_id = l.organisation_id
    WHERE ds.snapshot_month >= DATE_TRUNC('MONTH', o.first_contract_start_date)
      AND ds.snapshot_month <= DATE_TRUNC('MONTH', CURRENT_TIMESTAMP)
),

account_manager AS (
    -- One display name per HubSpot owner, preferring active + most recent.
    SELECT owner_id,
           CONCAT(first_name, ' ', last_name) AS account_manager,
           ROW_NUMBER() OVER (PARTITION BY owner_id ORDER BY is_active DESC, updated_at DESC) rnk
    FROM data_platform.prod.gold_hubspot_owner
    QUALIFY rnk = 1
),

b2b_org AS (
    -- One row per org from the dimension, keeping the most recent record.
    -- Used as a name fallback when HubSpot's name is blank.
    SELECT organisation_id, organisation_name,
           ROW_NUMBER() OVER (PARTITION BY organisation_id ORDER BY organisation_created_date DESC) rnk
    FROM reporting_layer.prod.dim__organisations
    WHERE organisation_id IS NOT NULL
      AND (organisation_name IS NOT NULL OR organisation_name <> '')
    QUALIFY rnk = 1
),

hubspot_org AS (
    -- One row per active org from HubSpot, keeping the highest-MRR record;
    -- carries tiering, contract start, and the owner (account manager) id.
    SELECT perlego_organisation_id   AS organisation_id,
           perlego_organisation_name AS organisation_name,
           internal_tiering_category, first_contract_start_date, b_2_b_active_partnership,
           account_manager           AS account_manager_id,
           ROW_NUMBER() OVER (PARTITION BY perlego_organisation_id ORDER BY COALESCE(company_mrr,0) DESC) rnk
    FROM data_platform.prod.gold_hubspot_company
    WHERE b_2_b_active_partnership > 0 AND perlego_organisation_id IS NOT NULL
    QUALIFY rnk = 1
),

b2b_org_dimension AS (
    -- Final account dimension: HubSpot attributes, resolved account-manager
    -- name, and a non-blank organisation name (HubSpot first, dim fallback).
    SELECT h.organisation_id,
           COALESCE(NULLIF(h.organisation_name,''), NULLIF(b.organisation_name,'')) AS organisation_name,
           h.internal_tiering_category, h.first_contract_start_date,
           h.b_2_b_active_partnership, am.account_manager
    FROM hubspot_org h
    LEFT JOIN account_manager am ON h.account_manager_id = am.owner_id
    LEFT JOIN b2b_org          b ON h.organisation_id    = b.organisation_id
),

assigned_subs AS (
    -- Subscription / user metrics from Step 3's table.
    SELECT subscription_month, organisation_id,
           active_users, rolling_12m_active_users, cumulative_active_users,
           active_subscriptions, rolling_12m_active_subscriptions, cumulative_active_subscriptions
    FROM reporting_layer.ad_hoc.nb_b2b_active_subs_monthly_snapshot
),

book_value AS (
    -- Reading-value / reader / book metrics from Step 4's table.
    SELECT reading_month, organisation_id,
           value_of_books_read_gbp, rolling_12m_value_of_books_read_gbp, cumulative_value_of_books_read_gbp,
           unique_readers, new_unique_readers, rolling_12m_unique_readers, cumulative_unique_readers,
           unique_books, new_unique_books, rolling_12m_unique_books, cumulative_unique_books
    FROM reporting_layer.ad_hoc.nb_b2b_book_value_monthly_snapshot
),

assembled AS (
    -- Join everything onto the MRR spine (the driving monthly grid) and
    -- derive contract tenure. All metrics default to 0 where a join misses.
    SELECT
        mf.snapshot_month,
        mf.organisation_id,
        COALESCE(NULLIF(bod.organisation_name,''), mf.organisation_name) AS organisation_name,
        bod.account_manager, bod.internal_tiering_category,
        bod.first_contract_start_date, fm.first_mrr_month,
        -- Contract tenure in whole months; floored at 1 so ROI maths never divides by 0.
        CASE WHEN bod.first_contract_start_date IS NULL THEN 1
             WHEN FLOOR(MONTHS_BETWEEN(mf.snapshot_month, bod.first_contract_start_date)) <= 0 THEN 1
             ELSE FLOOR(MONTHS_BETWEEN(mf.snapshot_month, bod.first_contract_start_date))
        END AS months_since_first_contract_start_date,
        mf.mrr_gbp, mf.rolling_12m_mrr_gbp, mf.cumulative_mrr_gbp,
        COALESCE(ll.b2b_allocated_licenses, 0) AS b2b_allocated_licenses,
        COALESCE(s.active_subscriptions, 0)             AS assigned_subscriptions,
        COALESCE(s.rolling_12m_active_subscriptions, 0) AS rolling_12m_assigned_subscriptions,
        COALESCE(s.cumulative_active_subscriptions, 0)  AS cumulative_assigned_subscriptions,
        COALESCE(s.active_users, 0)             AS assigned_users,
        COALESCE(s.rolling_12m_active_users, 0) AS rolling_12m_assigned_users,
        COALESCE(s.cumulative_active_users, 0)  AS cumulative_assigned_users,
        COALESCE(b.value_of_books_read_gbp, 0)            AS value_of_books_read_gbp,
        COALESCE(b.rolling_12m_value_of_books_read_gbp,0) AS rolling_12m_value_of_books_read_gbp,
        COALESCE(b.cumulative_value_of_books_read_gbp,0)  AS cumulative_value_of_books_read_gbp,
        COALESCE(b.unique_readers,0)             AS unique_readers,
        COALESCE(b.new_unique_readers,0)         AS new_unique_readers,
        COALESCE(b.rolling_12m_unique_readers,0) AS rolling_12m_unique_readers,
        COALESCE(b.cumulative_unique_readers,0)  AS cumulative_unique_readers,
        COALESCE(b.unique_books,0)             AS unique_books,
        COALESCE(b.new_unique_books,0)         AS new_unique_books,
        COALESCE(b.rolling_12m_unique_books,0) AS rolling_12m_unique_books,
        COALESCE(b.cumulative_unique_books,0)  AS cumulative_unique_books
    FROM mrr_final mf
    LEFT JOIN b2b_org_dimension bod ON mf.organisation_id = bod.organisation_id
    LEFT JOIN first_mrr         fm  ON mf.organisation_id = fm.organisation_id
    LEFT JOIN license_locf      ll  ON mf.organisation_id = ll.organisation_id AND mf.snapshot_month = ll.snapshot_month
    LEFT JOIN assigned_subs     s   ON mf.organisation_id = s.organisation_id  AND mf.snapshot_month = s.subscription_month
    LEFT JOIN book_value        b   ON mf.organisation_id = b.organisation_id  AND mf.snapshot_month = b.reading_month
),

-- ------------------------------------------------------------------
-- KPI LAYER - every ratio guards its denominator with NULLIF(...,0).
-- ------------------------------------------------------------------
kpis AS (
    SELECT a.*,
        a.mrr_gbp / NULLIF(a.b2b_allocated_licenses,0)                               AS arpu,                -- MRR per contracted seat
        a.cumulative_assigned_subscriptions / NULLIF(a.b2b_allocated_licenses,0)     AS redemption_rate,     -- subs taken up vs seats
        a.rolling_12m_unique_readers / NULLIF(a.rolling_12m_assigned_users,0)        AS engagement_l12m,     -- readers vs active users (L12M)
        a.rolling_12m_value_of_books_read_gbp / NULLIF(a.rolling_12m_unique_books,0) AS avg_dlp_l12m,        -- value per unique book (L12M)
        a.rolling_12m_assigned_users / NULLIF(a.rolling_12m_assigned_subscriptions,0) AS reallocation_l12m,  -- users per sub (seat reuse)
        a.rolling_12m_value_of_books_read_gbp / NULLIF(a.rolling_12m_mrr_gbp,0)      AS roi_rolling_12m,     -- ROI (L12M) - customer-facing
        a.cumulative_value_of_books_read_gbp
            / NULLIF(a.mrr_gbp * a.months_since_first_contract_start_date,0)         AS roi_original,        -- legacy ROI (kept for reference)
        a.cumulative_value_of_books_read_gbp / NULLIF(a.cumulative_mrr_gbp,0)        AS roi_lifetime,        -- ROI since contract start
        a.value_of_books_read_gbp / NULLIF(a.mrr_gbp,0)                              AS roi_single_month,    -- ROI for this month only (noisy)
        LAG(a.b2b_allocated_licenses, 12) OVER (
            PARTITION BY a.organisation_id ORDER BY a.snapshot_month)                AS licenses_12m_ago     -- seats 12 months ago
    FROM assembled a
),

-- Per-month portfolio benchmarks used by the classification rules:
--   portfolio_median_arpu : median ARPU across the portfolio (~GBP5.86); ROI-internal normaliser.
--   arpu_floor            : dynamic pricing floor = 0.75 x median ARPU (~GBP4.40).
--   dlp_floor             : hybrid value floor = LEAST( p25 of per-book DLP among ENGAGED
--                           accounts , GBP35 ). The relative part tracks the catalogue and
--                           ranks the shallowest engaged accounts; the GBP35 cap means an
--                           account reading > GBP35/book is never flagged, so the bucket
--                           empties if the catalogue genuinely improves (a pure percentile
--                           would always flag ~25%).
-- "engaged" = redemption >= 0.5 AND engagement >= 0.4 (the population the rule applies to).
portfolio_arpu AS (
    SELECT snapshot_month,
           PERCENTILE(arpu, 0.5)        AS portfolio_median_arpu,
           PERCENTILE(arpu, 0.5) * 0.75 AS arpu_floor,
           LEAST(
               PERCENTILE(CASE WHEN redemption_rate >= 0.50 AND engagement_l12m >= 0.40
                               THEN avg_dlp_l12m END, 0.25),
               35) AS dlp_floor
    FROM kpis
    WHERE arpu IS NOT NULL AND mrr_gbp > 0
    GROUP BY snapshot_month
),

kpis2 AS (
    SELECT k.*,
        pa.portfolio_median_arpu,
        pa.arpu_floor,
        pa.dlp_floor,
        -- ROI (INTERNAL): ROI (L12M) re-scaled by this account's price vs the
        -- portfolio (arpu / median arpu). Normalises out regional/discount
        -- pricing so accounts compare fairly; a low-ARPU deal no longer looks
        -- misleadingly high-ROI.
        k.roi_rolling_12m * (k.arpu / NULLIF(pa.portfolio_median_arpu,0)) AS roi_internal,
        -- EXPANSION (L12M): did contracted seats grow vs 12 months ago?
        --   'New account' = no row 12 months back; 'Yes' = grew; 'No' = flat/shrunk.
        CASE WHEN k.licenses_12m_ago IS NULL                    THEN 'New account'
             WHEN k.b2b_allocated_licenses > k.licenses_12m_ago THEN 'Yes'
             ELSE 'No' END AS expansion_l12m
    FROM kpis k
    LEFT JOIN portfolio_arpu pa ON k.snapshot_month = pa.snapshot_month
),

-- ------------------------------------------------------------------
-- HEALTH CATEGORY - rules checked top to bottom; first match wins,
-- so the CASE order encodes priority.
-- ------------------------------------------------------------------
categorised AS (
    SELECT k.*,
        CASE
            -- Underpriced AND under-delivering -> commercial escalation, no auto-renew.
            WHEN arpu < arpu_floor AND roi_internal < 1                              THEN 'Pricing: Critical'
            -- Exceptional value AND seats fully used -> seat expansion / upgrade.
            WHEN roi_internal >= 5 AND redemption_rate >= 0.75                       THEN 'Expansion Signal'
            -- Underpriced but delivering modest value -> fix price at renewal.
            WHEN arpu < arpu_floor AND roi_internal >= 1 AND roi_internal < 2        THEN 'Pricing: At Risk'
            -- < half the seats in use AND low value -> deployment campaign (biggest churn risk).
            WHEN redemption_rate < 0.50 AND roi_rolling_12m < 2                      THEN 'Adoption Risk'
            -- Seats assigned but users not returning to read -> activation campaign.
            WHEN redemption_rate >= 0.50 AND engagement_l12m < 0.40
                                          AND roi_rolling_12m < 5                    THEN 'Engagement Gap'
            -- Engaged but reading shallow/cheap titles -> likely catalogue gap, flag content team.
            WHEN redemption_rate >= 0.50 AND engagement_l12m >= 0.40
                                          AND avg_dlp_l12m < dlp_floor               THEN 'Content / Publisher'
            -- No flag tripped -> monitor, quarterly check-in.
            ELSE 'Healthy'
        END AS health_category
    FROM kpis2 k
),

-- Consecutive-month streak of the SAME raw category (gaps-and-islands).
-- The spine is contiguous monthly, so adjacent rows are consecutive months;
-- island_key is constant while the category is unbroken.
streaked AS (
    SELECT c.*,
        ROW_NUMBER() OVER (PARTITION BY organisation_id ORDER BY snapshot_month)
          - ROW_NUMBER() OVER (PARTITION BY organisation_id, health_category ORDER BY snapshot_month)
          AS island_key
    FROM categorised c
),

confirmed AS (
    -- Position within the current streak (1 = first month in this category).
    SELECT s.*,
        ROW_NUMBER() OVER (PARTITION BY organisation_id, health_category, island_key
                           ORDER BY snapshot_month) AS consecutive_months_in_category
    FROM streaked s
),

-- ------------------------------------------------------------------
-- REALLOCATION TREND - per-account monitoring of the rate of increase.
-- Reallocation is normally flat/declining, so a sustained rise is rare and
-- worth watching. Everything is measured against each account's OWN history
-- on a trailing window.
-- ------------------------------------------------------------------
reallocation_trend AS (
    SELECT c.*,
        -- Account's own recent baseline (trailing 6 months incl. current).
        AVG(reallocation_l12m) OVER (
            PARTITION BY organisation_id ORDER BY snapshot_month
            ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)                     AS reallocation_6m_avg,
        -- Absolute change vs 6 months ago.
        reallocation_l12m - LAG(reallocation_l12m, 6) OVER (
            PARTITION BY organisation_id ORDER BY snapshot_month)          AS reallocation_6m_delta,
        -- % change vs 6 months ago (size-neutral) - the rate-of-increase signal.
        reallocation_l12m / NULLIF(LAG(reallocation_l12m, 6) OVER (
            PARTITION BY organisation_id ORDER BY snapshot_month), 0) - 1  AS reallocation_6m_pct_change
    FROM confirmed c
),

-- ------------------------------------------------------------------
-- SCORED - the full per-month projection with ALL derived classification
-- columns materialised (priority / confirmed / trend flag / vs baseline),
-- plus each org's latest month. Materialising them here is what lets the
-- current-state layer below pin them with a plain window (no nested group
-- aggregates). The month cut-off is applied here so "latest" respects it.
-- ------------------------------------------------------------------
scored AS (
    SELECT
        -- ---- identifiers / dimensions ----
        snapshot_month,
        organisation_id,
        organisation_name,
        account_manager,
        internal_tiering_category,
        first_contract_start_date,
        first_mrr_month,
        months_since_first_contract_start_date,
        -- ---- revenue (MRR), gap-filled & windowed ----
        mrr_gbp,
        rolling_12m_mrr_gbp,
        cumulative_mrr_gbp,
        b2b_allocated_licenses,
        -- ---- subscriptions ----
        assigned_subscriptions,
        rolling_12m_assigned_subscriptions,
        cumulative_assigned_subscriptions,
        -- ---- users ----
        assigned_users,
        rolling_12m_assigned_users,
        cumulative_assigned_users,
        -- ---- reading value ----
        value_of_books_read_gbp,
        rolling_12m_value_of_books_read_gbp,
        cumulative_value_of_books_read_gbp,
        -- ---- readers / books ----
        unique_readers,
        new_unique_readers,
        rolling_12m_unique_readers,
        cumulative_unique_readers,
        unique_books,
        new_unique_books,
        rolling_12m_unique_books,
        cumulative_unique_books,
        -- ---- KPI layer ----
        redemption_rate,
        arpu,
        portfolio_median_arpu,
        arpu_floor,
        dlp_floor,
        roi_original,
        roi_rolling_12m,
        roi_lifetime,
        roi_single_month,
        roi_internal,
        engagement_l12m,
        avg_dlp_l12m,
        reallocation_l12m,
        -- ---- reallocation monitoring ----
        reallocation_6m_avg,
        reallocation_6m_delta,
        reallocation_6m_pct_change,
        reallocation_l12m / NULLIF(reallocation_6m_avg,0) AS reallocation_vs_baseline,  -- >1 = above its own norm / still rising
        CASE
            WHEN reallocation_l12m >= 1.5 AND reallocation_6m_pct_change >= 0.25 THEN 'Sharp rise'
            WHEN reallocation_l12m >= 1.5 AND reallocation_6m_pct_change >= 0.10 THEN 'Rising'
            ELSE 'Stable / declining'
        END AS reallocation_trend_flag,
        expansion_l12m,
        -- ---- classification ----
        health_category,
        CASE health_category
            WHEN 'Pricing: Critical'   THEN 'Critical'    -- '🔴 Critical'
            WHEN 'Expansion Signal'    THEN 'Opportunity' -- '🟢 Opportunity'
            WHEN 'Pricing: At Risk'    THEN 'Medium'      -- '🟡 Medium'
            WHEN 'Adoption Risk'       THEN 'High'        -- '🔴 High'
            WHEN 'Engagement Gap'      THEN 'High'        -- '🟠 High'
            WHEN 'Content / Publisher' THEN 'Low'         -- '⚪ Low'
            WHEN 'Healthy'             THEN 'Low'         -- '⚪ Low'
        END AS health_category_priority,
        consecutive_months_in_category,
        CASE
            WHEN health_category NOT IN ('Pricing: Critical','Pricing: At Risk','Adoption Risk','Engagement Gap')
                 THEN 'Not a risk'
            WHEN consecutive_months_in_category >= 3 THEN 'Confirmed'   -- 3rd consecutive month -> act
            ELSE 'Unconfirmed'                                          -- 1-2 months -> watch, don't escalate yet
        END AS is_risk_confirmed,
        CASE WHEN health_category IN ('Pricing: Critical','Pricing: At Risk','Adoption Risk','Engagement Gap')
                  AND consecutive_months_in_category < 3
             THEN 'Monitoring (unconfirmed risk)'
             ELSE health_category END AS health_category_confirmed,
        -- Each org's most recent month within the cut-off - the pin target for
        -- the current-state columns below. Plain window (not nested).
        MAX(snapshot_month) OVER (PARTITION BY organisation_id) AS org_latest_month
    FROM reallocation_trend
    -- Cut-off: on/after the 27th include the current month; before the 27th the
    -- current month is too sparse, so cap at the prior month instead.
    WHERE snapshot_month <= CASE
            WHEN DAY(current_timestamp) >= 27 THEN DATE_TRUNC('MONTH', current_timestamp)
            ELSE ADD_MONTHS(DATE_TRUNC('MONTH', current_timestamp), -1) END
)

-- ------------------------------------------------------------------
-- FINAL OUTPUT - every monthly row, plus a CURRENT-STATE block that pins
-- each org's LATEST-month KPIs onto all of its rows (constant per org).
-- These current_* columns are physical, so ThoughtSpot can display / group /
-- colour them with no formula (and no group-aggregate nesting). Build the
-- summary table by filtering is_latest_month = true.
--   How the pin works: MAX(CASE WHEN this row is the org's latest month THEN
--   <col> END) OVER (org) - there is exactly one latest row per org, so MAX
--   simply returns that single value and copies it onto every month.
-- ------------------------------------------------------------------
SELECT
    * EXCEPT (org_latest_month),
    -- TRUE only on each org's most recent month (one row per org).
    CASE WHEN snapshot_month = org_latest_month THEN TRUE ELSE FALSE END AS is_latest_month,
    -- ---- current state: latest-month value of each KPI, repeated on every row ----
    MAX(CASE WHEN snapshot_month = org_latest_month THEN rolling_12m_mrr_gbp END)                 OVER (PARTITION BY organisation_id) AS current_l12m_mrr_gbp,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN rolling_12m_value_of_books_read_gbp END) OVER (PARTITION BY organisation_id) AS current_l12m_reading_value_gbp,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN redemption_rate END)                     OVER (PARTITION BY organisation_id) AS current_redemption_rate,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN engagement_l12m END)                     OVER (PARTITION BY organisation_id) AS current_engagement_l12m,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN avg_dlp_l12m END)                        OVER (PARTITION BY organisation_id) AS current_avg_dlp_l12m,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN roi_rolling_12m END)                     OVER (PARTITION BY organisation_id) AS current_roi_rolling_12m,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN roi_internal END)                        OVER (PARTITION BY organisation_id) AS current_roi_internal,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN arpu END)                                OVER (PARTITION BY organisation_id) AS current_monthly_arpu,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN arpu * 12 END)                           OVER (PARTITION BY organisation_id) AS current_annual_arpu,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN rolling_12m_assigned_subscriptions END)  OVER (PARTITION BY organisation_id) AS current_12m_assigned_subscriptions,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN rolling_12m_assigned_users END)          OVER (PARTITION BY organisation_id) AS current_12m_assigned_users,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN cumulative_assigned_subscriptions END)   OVER (PARTITION BY organisation_id) AS current_cum_assigned_subscriptions,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN cumulative_assigned_users END)           OVER (PARTITION BY organisation_id) AS current_cum_assigned_users,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN b2b_allocated_licenses END)              OVER (PARTITION BY organisation_id) AS current_contracted_seats,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN expansion_l12m END)                      OVER (PARTITION BY organisation_id) AS current_expansion_l12m,
    -- ---- classification companions (for grouping / colouring the summary table) ----
    MAX(CASE WHEN snapshot_month = org_latest_month THEN health_category END)                     OVER (PARTITION BY organisation_id) AS current_health_category,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN health_category_confirmed END)           OVER (PARTITION BY organisation_id) AS current_health_category_confirmed,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN health_category_priority END)            OVER (PARTITION BY organisation_id) AS current_health_category_priority,
    MAX(CASE WHEN snapshot_month = org_latest_month THEN reallocation_trend_flag END)             OVER (PARTITION BY organisation_id) AS current_reallocation_trend_flag,
    
    CURRENT_TIMESTAMP AS updated_at
FROM scored
ORDER BY organisation_id, snapshot_month
;
