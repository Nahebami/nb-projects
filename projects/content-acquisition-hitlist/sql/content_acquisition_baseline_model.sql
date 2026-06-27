/* SECTION 1  - reporting_layer.ad_hoc.nb_bmg_matches_revamp */


--CREATE TABLE reporting_layer.ad_hoc.nb_bmg_matches_revamp AS
DELETE FROM reporting_layer.ad_hoc.nb_bmg_matches_revamp;

INSERT INTO reporting_layer.ad_hoc.nb_bmg_matches_revamp
WITH bmg_invalid_isbns AS (
    SELECT * FROM reporting_layer.prod.stg__md__bmg_invalid_isbns
),

users AS (
    SELECT * FROM (
        SELECT
            *,
            RANK() OVER (
                PARTITION BY email
                ORDER BY registration_date DESC, id DESC
            ) AS rnk
        FROM reporting_layer.prod.int__users
        WHERE email IS NOT NULL
    )
    WHERE rnk = 1
),

us_book_country_access AS (
    SELECT * FROM reporting_layer.prod.int__book_country_access
    WHERE country_code_2 = 'US' /*allowed for US*/
),

/* CHANGE 5*/
uk_book_country_access AS (
    SELECT * FROM reporting_layer.prod.int__book_country_access
   WHERE country_code_2 = 'GB' /*allowed for UK*/
),

/* CHANGE 5*/
global_book_country_access AS (
SELECT book_id, country_count
FROM (
SELECT book_id, count(distinct country_id) country_count
FROM reporting_layer.prod.int__book_country_access
GROUP BY 1 /*allowed globally*/
)
),

books AS (
    SELECT DISTINCT
        id AS book_id,
        isbn_id,
        hardback_isbn,
        softback_isbn,
        book_is_available,
        book_restrictions,
        RANK() OVER (
            PARTITION BY isbn_id
            ORDER BY id ASC
        ) AS rnk
    FROM reporting_layer.prod.int__books
),

bmg_subjects AS (
    SELECT DISTINCT
        LOWER(course_subject) AS course_subject,
        NVL2(academic_discipline, academic_discipline, NULL) AS academic_discipline,
        NVL2(academic_discipline, academic_discipline_pip, NULL) AS academic_discipline_pip,
        NVL2(academic_discipline, academic_discipline_perlego, NULL) AS academic_discipline_perlego
    FROM reporting_layer.prod.stg__md__bmg_subjects
),

/* CHANGE 1*/
enriched_isbndb AS (
SELECT 
a.*, b.book_is_available,
ROW_NUMBER() OVER( PARTITION BY a.isbn_id ORDER BY
b.book_is_available desc, --- priority one take availablle books (true) before unavailable books (false)
a.algo_match_score desc, 
a.sys_date_ingested desc, 
a.algo_isbn_source desc 
) as dup_rank
FROM reporting_layer.prod.stg__dp__enriched_isbndb a
LEFT JOIN reporting_layer.prod.dim__books b on (a.book_id = b.book_id)
WHERE rnk = 1
and a.isbn_id is not null
qualify dup_rank = 1
),

bmg AS (
    SELECT
        bmg.isbn13,
        bmg.title,
        bmg.author,
        bmg.imprint,
        bmg.edition,
        bmg.published_year,
        bmg.school,
        bmg.school_year_type,
        bmg.state,
        bmg.dept_code,
        bmg.department,
        bmg.dept_description,
        bmg.course_number,
        bmg.course_title,
        bmg.course_level,
        bmg.course_subject,
        bmg.period,
        bmg.instructor,
        bmg.email,
        bmg.course_level_enrich,
        bmg.enrollments,
        bmg.enrollments_adjusted,
        COALESCE(bmg_subjects.academic_discipline_pip, 'Unknown') AS academic_discipline_pip,
        COALESCE(bmg_subjects.academic_discipline, 'Unknown') AS academic_discipline,
        COALESCE(bmg_subjects.academic_discipline_perlego, 'Unknown') AS academic_discipline_perlego
    FROM reporting_layer.prod.stg__md__bmg AS bmg
    LEFT JOIN bmg_subjects ON bmg.course_subject = bmg_subjects.course_subject
    WHERE
        NOT EXISTS (
            SELECT 1 FROM bmg_invalid_isbns
            WHERE bmg_invalid_isbns.bmg_isbn = bmg.isbn13
        )
),

match1 AS (
    SELECT
        bmg.*,
        books.book_id AS book_id1,
        books.isbn_id AS isbn1,
        books.book_is_available
    FROM bmg
    LEFT JOIN books
        ON
            bmg.isbn13 = books.isbn_id
            AND books.book_is_available
            AND books.isbn_id IS NOT NULL
            AND books.rnk = 1

),

match4 AS (
    SELECT
        match1.*,
        enriched_isbndb.book_id AS book_id4,
        enriched_isbndb.isbn_id AS isbn4,
        COALESCE(match1.book_id1, enriched_isbndb.book_id) AS book_id,
        COALESCE(match1.isbn1, enriched_isbndb.isbn_id) AS perlego_isbn,
        CASE
            WHEN match1.isbn1 IS NOT NULL THEN 'Exact Match'
            WHEN match1.isbn1 IS NULL AND enriched_isbndb.isbn_id IS NOT NULL THEN 'Algorithm Match'
        END AS perlego_isbn_status,
        enriched_isbndb.algo_title_short,
        enriched_isbndb.algo_title_long,
        enriched_isbndb.algo_authors,
        enriched_isbndb.algo_edition,
        enriched_isbndb.algo_year_published,
        enriched_isbndb.algo_other_isbns,
        enriched_isbndb.algo_publisher,
        enriched_isbndb.algo_match_score,
        enriched_isbndb.algo_title_similarity,
        enriched_isbndb.algo_author_similarity,
        enriched_isbndb.algo_edition_match,
        enriched_isbndb.algo_language_match,
        enriched_isbndb.algo_isbn_source
    FROM match1
    LEFT JOIN enriched_isbndb ON match1.isbn13 = enriched_isbndb.isbn_id
),

match5 AS (
    SELECT
        match4.*,
        books.book_is_available AS perlego_book_is_available,
        books.book_restrictions as perlego_book_restrictions
    FROM match4
    LEFT JOIN books ON match4.book_id = books.book_id
),

match6 AS (
    SELECT
        match5.*,
        CASE WHEN match5.book_id IS NULL THEN NULL
            WHEN match5.book_id IS NOT NULL AND us_book_country_access.book_id IS NOT NULL THEN TRUE ELSE FALSE
        END AS us_sales_right_flag,
            CASE WHEN match5.book_id IS NULL THEN NULL
            WHEN match5.book_id IS NOT NULL AND uk_book_country_access.book_id IS NOT NULL THEN TRUE ELSE FALSE
        END AS uk_sales_right_flag,
             CASE WHEN match5.book_id IS NULL THEN NULL
            WHEN match5.book_id IS NOT NULL AND global_book_country_access.book_id IS NOT NULL AND global_book_country_access.country_count >= 249 THEN TRUE ELSE FALSE
        END AS global_sales_right_flag,
            CASE WHEN match5.book_id IS NULL THEN NULL
        WHEN match5.book_id IS NOT NULL AND global_book_country_access.book_id IS NOT NULL THEN global_book_country_access.country_count ELSE NULL
        END AS global_country_count,     
        users.id AS user_id
    FROM match5
    LEFT JOIN users ON match5.email = users.email
    LEFT JOIN us_book_country_access ON match5.book_id = us_book_country_access.book_id
    LEFT JOIN uk_book_country_access ON match5.book_id = uk_book_country_access.book_id
    LEFT JOIN global_book_country_access ON match5.book_id = global_book_country_access.book_id
),

final AS (
    SELECT DISTINCT
        isbn13 AS isbn_id,
        book_id,
        title AS bmg_title,
        author AS bmg_author,
        UPPER(COALESCE(imprint,'Unknown')) AS bmg_inprint, /* CHANGE 4*/
        edition AS bmg_edition,
        published_year AS bmg_published_year,
        COALESCE(
            book_id IS NOT NULL
            AND NOT LOWER(imprint) IN ('pearson', 'cengage', 'mcgraw hill education', 'w.w. norton & company')
            -- AND us_sales_right_ind = TRUE -- we removed US sales right from match criteria /* CHANGE 3*/
            AND algo_match_score >= 0.94
            AND perlego_book_is_available = TRUE, FALSE
        ) AS bmg_available_status,
        us_sales_right_flag, /* CHANGE 6*/
        uk_sales_right_flag, /* CHANGE 7*/
        global_sales_right_flag,
        global_country_count,
        perlego_book_is_available,
        perlego_book_restrictions,
        algo_match_score,
        isbn1 AS perlego_isbn_13,
        isbn1 AS perlego_isbn_hardback,
        isbn1 AS perlego_isbn_softback,
        isbn4 AS perlego_isbn_algorithm,
        algo_title_short,
        algo_title_long,
        algo_authors,
        algo_edition,
        algo_year_published,
        algo_other_isbns,
        algo_publisher,
        algo_title_similarity,
        algo_author_similarity,
        algo_edition_match,
        algo_language_match,
        algo_isbn_source,
        school,
        school_year_type,
        state,
        dept_code,
        department,
        dept_description,
        course_number,
        course_title,
        course_level,
        course_level_enrich,
        enrollments,
        enrollments_adjusted,
        course_subject,
        academic_discipline,
        academic_discipline_pip,
        academic_discipline_perlego,
        period,
        instructor,
        user_id
    FROM match6
)

SELECT *,
current_timestamp AS last_updated_date
FROM final
;





/* SECTION 2 - reporting_layer.ad_hoc.nb_content_acquisition_all_baseline_model */


--CREATE TABLE reporting_layer.ad_hoc.nb_content_acquisition_all_baseline_model AS
DELETE FROM reporting_layer.ad_hoc.nb_content_acquisition_all_baseline_model;
INSERT INTO reporting_layer.ad_hoc.nb_content_acquisition_all_baseline_model

WITH BMG_AGGR_BASE AS 
(
---- BMG Base prep at isbn_id level aggregating schools & enrolment
SELECT 
isbn_id, book_id, bmg_inprint AS bmg_publisher, 
COALESCE(bmg_title,algo_title_short,algo_title_long) AS bmg_title, bmg_author, bmg_edition, bmg_published_year,
bmg_available_status as perlego_match_status, 
perlego_book_is_available, perlego_book_restrictions, 
us_sales_right_flag, uk_sales_right_flag, global_sales_right_flag, global_country_count,
algo_match_score, algo_other_isbns, period,
COUNT(DISTINCT UPPER(school)) AS total_school, 
SUM(enrollments_adjusted) AS total_enrolment
FROM reporting_layer.ad_hoc.nb_bmg_matches_revamp
GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17
),


BMG_BASE AS 
(
SELECT 
isbn_id, book_id, bmg_publisher, 
bmg_title, bmg_author, bmg_edition, bmg_published_year,
perlego_match_status, 
CASE 
WHEN perlego_match_status = TRUE THEN 'Matched'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND LOWER(bmg_publisher) IN ('pearson', 'cengage', 'mcgraw hill education', 'w.w. norton & company') THEN 'Not Matched - Big 4 publishers we dont have'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score < 0.94 AND perlego_book_is_available = TRUE THEN 'Not Matched - low match score'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score >= 0.94 AND perlego_book_is_available = FALSE THEN 'Not Matched - book on perlego but not live'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score < 0.94 AND perlego_book_is_available = FALSE THEN 'Not Matched - low match score + book on perlego but not live'
ELSE NULL END perlego_match_status_reason,
perlego_book_is_available, perlego_book_restrictions, 
us_sales_right_flag, uk_sales_right_flag, global_sales_right_flag, global_country_count,
algo_match_score, algo_other_isbns, period,
total_school,
/* When enrolment for an ISBN is 0, we assign it a value of 23 (the average from the source) to avoid impacting the score multiplier calculation. This applies to less than 0.1% of cases. */ 
CASE WHEN total_enrolment = 0 THEN 23 ELSE total_enrolment END AS total_enrolment
FROM BMG_AGGR_BASE
),


/* ============================================================
   READING_LIST_MASTER
   Single consolidated reading list table.
   To add a new RL: add a UNION ALL block with the correct
   rl_name, rl_tier and rl_weight values.

   Tier Weights:
   High   = 2.0 --> UWL, UOL, Slingshot, Derby, Boston
   Medium = 1.5 --> Westcliff, JSTOR, Baptist, Leicester, SACAP, HolyCross, MountSt, Follet
   Low    = 1.0 --> Norwich, Ascent
   ============================================================ */

READING_LIST_MASTER AS
(
    SELECT isbn13 AS isbn, title,          'UWL'       AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn13 ORDER BY isbn13)        AS rn FROM reporting_layer.ad_hoc.nb_uwl_reading_list_for_model       WHERE isbn13 IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           book_title,     'UOL'       AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn)           AS rn FROM reporting_layer.ad_hoc.nb_leeds_reading_list_for_model     WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           textbook_title, 'Westcliff' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn_type DESC) AS rn FROM reporting_layer.ad_hoc.nb_westcliff_reading_list_for_model WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Slingshot' AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn)           AS rn FROM reporting_layer.ad_hoc.nb_slingshot_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           book_title,     'JSTOR'     AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_jstor_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Derby'     AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_derby_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Baptist'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_baptist_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Norwich'   AS rl_name, 'Low'    AS rl_tier, 1.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_norwich_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Leicester' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_leicester_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'SACAP'     AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_sacap_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'HolyCross' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_holycross_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Ascent'    AS rl_name, 'Low'    AS rl_tier, 1.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_ascent_reading_list_for_model     WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'MountSt'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_mountst_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Follet'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_follet_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Boston'   AS rl_name, 'High' AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_boston_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1

    -- + ADD NEW READING LIST HERE:
    -- UNION ALL
    -- SELECT isbn, title, '<rl_name>' AS rl_name, '<High|Medium|Low>' AS rl_tier, <2.0|1.5|1.0> AS rl_weight,
    --        row_number() OVER(PARTITION BY isbn ORDER BY isbn ASC) AS rn
    -- FROM reporting_layer.ad_hoc.<new_table_name>
    -- WHERE isbn IS NOT NULL QUALIFY rn = 1
),


/* ============================================================
   RL_SCORES_PER_ISBN
   Aggregates master list to one row per ISBN.
   Computes M1 count, M2 weighted score and per-RL flags.
   ============================================================ */

RL_SCORES_PER_ISBN AS
(
    SELECT
        isbn,
        COUNT(DISTINCT rl_name)                                              AS m1_total_rl_count,
        SUM(rl_weight)                                                       AS m2_rl_score,
        MAX(CASE WHEN rl_name = 'UWL'       THEN TRUE ELSE FALSE END)        AS uwl_reading_list_flag,
        MAX(CASE WHEN rl_name = 'UOL'       THEN TRUE ELSE FALSE END)        AS uol_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Westcliff' THEN TRUE ELSE FALSE END)        AS westcliff_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Slingshot' THEN TRUE ELSE FALSE END)        AS slg_reading_list_flag,
        MAX(CASE WHEN rl_name = 'JSTOR'     THEN TRUE ELSE FALSE END)        AS jstor_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Derby'     THEN TRUE ELSE FALSE END)        AS derby_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Baptist'   THEN TRUE ELSE FALSE END)        AS baptist_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Norwich'   THEN TRUE ELSE FALSE END)        AS norwich_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Leicester' THEN TRUE ELSE FALSE END)        AS leicester_reading_list_flag,
        MAX(CASE WHEN rl_name = 'SACAP'     THEN TRUE ELSE FALSE END)        AS sacap_reading_list_flag,
        MAX(CASE WHEN rl_name = 'HolyCross' THEN TRUE ELSE FALSE END)        AS holycross_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Ascent'    THEN TRUE ELSE FALSE END)        AS ascent_reading_list_flag,
        MAX(CASE WHEN rl_name = 'MountSt'   THEN TRUE ELSE FALSE END)        AS mountst_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Follet'    THEN TRUE ELSE FALSE END)        AS follet_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Boston'   THEN TRUE ELSE FALSE END)         AS boston_reading_list_flag
    FROM READING_LIST_MASTER
    GROUP BY isbn
),


BASE_RL_JOIN AS
(
SELECT
    BMG_BASE.*,
    COALESCE(RL.uwl_reading_list_flag,       FALSE) AS uwl_reading_list_flag,
    COALESCE(RL.uol_reading_list_flag,       FALSE) AS uol_reading_list_flag,
    COALESCE(RL.westcliff_reading_list_flag, FALSE) AS westcliff_reading_list_flag,
    COALESCE(RL.slg_reading_list_flag,       FALSE) AS slg_reading_list_flag,
    COALESCE(RL.jstor_reading_list_flag,     FALSE) AS jstor_reading_list_flag,
    COALESCE(RL.derby_reading_list_flag,     FALSE) AS derby_reading_list_flag,
    COALESCE(RL.baptist_reading_list_flag,   FALSE) AS baptist_reading_list_flag,
    COALESCE(RL.norwich_reading_list_flag,   FALSE) AS norwich_reading_list_flag,
    COALESCE(RL.leicester_reading_list_flag, FALSE) AS leicester_reading_list_flag,
    COALESCE(RL.sacap_reading_list_flag,     FALSE) AS sacap_reading_list_flag,
    COALESCE(RL.holycross_reading_list_flag, FALSE) AS holycross_reading_list_flag,
    COALESCE(RL.ascent_reading_list_flag,    FALSE) AS ascent_reading_list_flag,
    COALESCE(RL.mountst_reading_list_flag,   FALSE) AS mountst_reading_list_flag,
    COALESCE(RL.follet_reading_list_flag,    FALSE) AS follet_reading_list_flag,
    COALESCE(RL.boston_reading_list_flag,    FALSE) AS boston_reading_list_flag,
    COALESCE(RL.m1_total_rl_count,           0)     AS m1_total_rl_count,
    COALESCE(RL.m2_rl_score,                 0)     AS m2_rl_score
FROM BMG_BASE
LEFT JOIN RL_SCORES_PER_ISBN RL ON (BMG_BASE.isbn_id = RL.isbn)
),


BASE_RL_ADJUSTMENT AS
(
SELECT *,

    /* -------- APPROACH 1 (M1): RL Count Multiplier --------
       All RLs treated equally regardless of tier
       Multiplier = 1 + total RL count
       Formula: total_enrolment × (1 + m1_total_rl_count)   */
    (1 + m1_total_rl_count)                              AS m1_multiplier,
    ROUND(total_enrolment * (1 + m1_total_rl_count), 0)  AS m1_adjusted_enrolment,

    /* -------- APPROACH 2 (M2): Tier-Weighted RL Multiplier --------
       High   = 2.0 → UWL, UOL, Slingshot, Derby, Boston
       Medium = 1.5 → Westcliff, JSTOR, Baptist, Leicester, SACAP, HolyCross, MountSt, Follet
       Low    = 1.0 → Norwich, Ascent
       RL Score pre-computed in RL_SCORES_PER_ISBN
       Formula: total_enrolment × (1 + m2_rl_score)         */
    ROUND(1 + m2_rl_score, 1)                            AS m2_multiplier,
    ROUND(total_enrolment * (1 + m2_rl_score), 0)        AS m2_adjusted_enrolment

FROM BASE_RL_JOIN
),


BASE_RL_SCORE_CALC AS
(
SELECT *,

    /* ---- Total number of reading lists used in the model (constant) ---- */
    15 AS total_rl_in_model,

    /* -------- M1: Normalised Score (1-100) - Log scaled -------- */
    ROW_NUMBER() OVER (ORDER BY m1_adjusted_enrolment DESC, total_enrolment DESC) AS m1_value_rank,

    ROUND(1 + (
        (LOG(NULLIF(m1_adjusted_enrolment, 0)) - MIN(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER()) /
        NULLIF(MAX(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER() - MIN(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER(), 0)
    ) * 99, 1) AS m1_value_score,

    /* -------- M2: Normalised Score (1-100) - Log scaled -------- */
    ROW_NUMBER() OVER (ORDER BY m2_adjusted_enrolment DESC, total_enrolment DESC ) AS m2_value_rank,

    ROUND(1 + (
        (LOG(NULLIF(m2_adjusted_enrolment, 0)) - MIN(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER()) /
        NULLIF(MAX(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER() - MIN(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER(), 0)
    ) * 99, 1) AS m2_value_score

FROM BASE_RL_ADJUSTMENT
)


SELECT *,
    DATE(current_timestamp) AS snapshot_date,
    current_timestamp       AS last_updated_date
FROM BASE_RL_SCORE_CALC
--ORDER BY m2_value_score DESC
;





/* SECTION 3  reporting_layer.ad_hoc.nb_content_acquisition_excl_baseline_model */


--CREATE TABLE reporting_layer.ad_hoc.nb_content_acquisition_excl_baseline_model AS
DELETE FROM reporting_layer.ad_hoc.nb_content_acquisition_excl_baseline_model;
INSERT INTO reporting_layer.ad_hoc.nb_content_acquisition_excl_baseline_model
WITH BMG_AGGR_BASE AS 
(
---- BMG Base prep at isbn_id level aggregating schools & enrolment
SELECT 
isbn_id, book_id, bmg_inprint AS bmg_publisher, 
COALESCE(bmg_title,algo_title_short,algo_title_long) AS bmg_title, bmg_author, bmg_edition, bmg_published_year,
bmg_available_status as perlego_match_status, 
perlego_book_is_available, perlego_book_restrictions, 
us_sales_right_flag, uk_sales_right_flag, global_sales_right_flag, global_country_count,
algo_match_score, algo_other_isbns, period,
COUNT(DISTINCT UPPER(school)) AS total_school, 
SUM(enrollments_adjusted) AS total_enrolment
FROM reporting_layer.ad_hoc.nb_bmg_matches_revamp
WHERE LOWER(bmg_inprint) NOT IN (
    'pearson',
    'cengage',
    'mcgraw hill education',
    'w.w. norton & company',
    'oxford university press',
    'penguin random house',
    'ppg-penguin books',
    'ppg-penguin classics',
    'ppg-penguin press',
    'penguin books',
    'pyr-penguin workshop',
    'pearson ecampus ivy tech',
    'pyr-penguin books',
    'ppg-penguin life',
    'sinauer associates is an imprint of oxford university press',
    'oup',
    'canada-penguin canada',
    'oxford university press canada',
    'penguin publishing group',
    'cengage l',
    'cengage south western',
    'pyr-penguin young readers group',
    'mcgraw-hill united kingdom',
    'ppg-penguin audio',
    'prh grupo editorial-penguin clásicos',
    'plume/penguin',
    'pyr-penguin young readers',
    'mcgraw go',
    'mcgraw-hill ryerson (canada)',
    'mcgraw hill',
    'granta books/penguin',
    'mit press (penguin random house)',
    'penguin random house audio',
    'pearson education canada (cana',
    'penguin (cornerstone)',
    'penguin usa/ inc.',
    'pyr-rise x penguin workshop',
    'oup',
    'marvel enterprises/ incorporated (c/o penguin random house)',
    'ace books c/o penguin random house',
    'penguin books / the viking critical library',
    'penguin publishing',
    'mcgraw cre',
    'canada-penguin teen',
    'harmondsworth penguin 1979',
    'pearson (2015)',
    'rent pearson',
    'penguin random house grupo editorial s.a.',
    'penguin pr',
    'mcgraw-hill education (ise editions)',
    'pearson education c',
    'disney press (c/o penguin random house)',
    'penguin books australia',
    'penguin (non-classics)',
    'penguin group usa/ inc',
    'mcgraw hill / asia',
    'penguin classics (6 sept. 2007)',
    'penguin ca'
)
GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17
),


BMG_BASE AS 
(
SELECT 
isbn_id, book_id, bmg_publisher, 
bmg_title, bmg_author, bmg_edition, bmg_published_year,
perlego_match_status, 
CASE 
WHEN perlego_match_status = TRUE THEN 'Matched'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND LOWER(bmg_publisher) IN ('pearson', 'cengage', 'mcgraw hill education', 'w.w. norton & company') THEN 'Not Matched - Big 4 publishers we dont have'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score < 0.94 AND perlego_book_is_available = TRUE THEN 'Not Matched - low match score'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score >= 0.94 AND perlego_book_is_available = FALSE THEN 'Not Matched - book on perlego but not live'
WHEN perlego_match_status = FALSE AND book_id IS NOT NULL AND algo_match_score < 0.94 AND perlego_book_is_available = FALSE THEN 'Not Matched - low match score + book on perlego but not live'
ELSE NULL END perlego_match_status_reason,
perlego_book_is_available, perlego_book_restrictions, 
us_sales_right_flag, uk_sales_right_flag, global_sales_right_flag, global_country_count,
algo_match_score, algo_other_isbns, period,
total_school, 
/* When enrolment for an ISBN is 0, we assign it a value of 23 (the average from the source) to avoid impacting the score multiplier calculation. This applies to less than 0.1% of cases. */ 
CASE WHEN total_enrolment = 0 THEN 23 ELSE total_enrolment END AS total_enrolment
FROM BMG_AGGR_BASE
),


/* ============================================================
   READING_LIST_MASTER
   Single consolidated reading list table.
   To add a new RL: add a UNION ALL block with the correct
   rl_name, rl_tier and rl_weight values.

   Tier Weights:
   High   = 2.0 --> UWL, UOL, Slingshot, Derby, Boston
   Medium = 1.5 --> Westcliff, JSTOR, Baptist, Leicester, SACAP, HolyCross, MountSt, Follet
   Low    = 1.0 --> Norwich, Ascent
   ============================================================ */

READING_LIST_MASTER AS
(
    SELECT isbn13 AS isbn, title,          'UWL'       AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn13 ORDER BY isbn13)        AS rn FROM reporting_layer.ad_hoc.nb_uwl_reading_list_for_model       WHERE isbn13 IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           book_title,     'UOL'       AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn)           AS rn FROM reporting_layer.ad_hoc.nb_leeds_reading_list_for_model     WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           textbook_title, 'Westcliff' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn_type DESC) AS rn FROM reporting_layer.ad_hoc.nb_westcliff_reading_list_for_model WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Slingshot' AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn)           AS rn FROM reporting_layer.ad_hoc.nb_slingshot_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           book_title,     'JSTOR'     AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_jstor_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Derby'     AS rl_name, 'High'   AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_derby_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Baptist'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_baptist_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Norwich'   AS rl_name, 'Low'    AS rl_tier, 1.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_norwich_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Leicester' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_leicester_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'SACAP'     AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_sacap_reading_list_for_model      WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'HolyCross' AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_holycross_reading_list_for_model  WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Ascent'    AS rl_name, 'Low'    AS rl_tier, 1.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_ascent_reading_list_for_model     WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'MountSt'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_mountst_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Follet'   AS rl_name, 'Medium' AS rl_tier, 1.5 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)       AS rn FROM reporting_layer.ad_hoc.nb_follet_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1
    UNION ALL
    SELECT isbn,           title,          'Boston'   AS rl_name, 'High' AS rl_tier, 2.0 AS rl_weight, row_number() OVER(PARTITION BY isbn  ORDER BY isbn ASC)        AS rn FROM reporting_layer.ad_hoc.nb_boston_reading_list_for_model    WHERE isbn   IS NOT NULL QUALIFY rn = 1

    -- + ADD NEW READING LIST HERE:
    -- UNION ALL
    -- SELECT isbn, title, '<rl_name>' AS rl_name, '<High|Medium|Low>' AS rl_tier, <2.0|1.5|1.0> AS rl_weight,
    --        row_number() OVER(PARTITION BY isbn ORDER BY isbn ASC) AS rn
    -- FROM reporting_layer.ad_hoc.<new_table_name>
    -- WHERE isbn IS NOT NULL QUALIFY rn = 1
),


/* ============================================================
   RL_SCORES_PER_ISBN
   Aggregates master list to one row per ISBN.
   Computes M1 count, M2 weighted score and per-RL flags.
   ============================================================ */

RL_SCORES_PER_ISBN AS
(
    SELECT
        isbn,
        COUNT(DISTINCT rl_name)                                              AS m1_total_rl_count,
        SUM(rl_weight)                                                       AS m2_rl_score,
        MAX(CASE WHEN rl_name = 'UWL'       THEN TRUE ELSE FALSE END)        AS uwl_reading_list_flag,
        MAX(CASE WHEN rl_name = 'UOL'       THEN TRUE ELSE FALSE END)        AS uol_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Westcliff' THEN TRUE ELSE FALSE END)        AS westcliff_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Slingshot' THEN TRUE ELSE FALSE END)        AS slg_reading_list_flag,
        MAX(CASE WHEN rl_name = 'JSTOR'     THEN TRUE ELSE FALSE END)        AS jstor_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Derby'     THEN TRUE ELSE FALSE END)        AS derby_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Baptist'   THEN TRUE ELSE FALSE END)        AS baptist_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Norwich'   THEN TRUE ELSE FALSE END)        AS norwich_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Leicester' THEN TRUE ELSE FALSE END)        AS leicester_reading_list_flag,
        MAX(CASE WHEN rl_name = 'SACAP'     THEN TRUE ELSE FALSE END)        AS sacap_reading_list_flag,
        MAX(CASE WHEN rl_name = 'HolyCross' THEN TRUE ELSE FALSE END)        AS holycross_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Ascent'    THEN TRUE ELSE FALSE END)        AS ascent_reading_list_flag,
        MAX(CASE WHEN rl_name = 'MountSt'   THEN TRUE ELSE FALSE END)        AS mountst_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Follet'    THEN TRUE ELSE FALSE END)        AS follet_reading_list_flag,
        MAX(CASE WHEN rl_name = 'Boston'   THEN TRUE ELSE FALSE END)         AS boston_reading_list_flag
    FROM READING_LIST_MASTER
    GROUP BY isbn
),


BASE_RL_JOIN AS
(
SELECT
    BMG_BASE.*,
    COALESCE(RL.uwl_reading_list_flag,       FALSE) AS uwl_reading_list_flag,
    COALESCE(RL.uol_reading_list_flag,       FALSE) AS uol_reading_list_flag,
    COALESCE(RL.westcliff_reading_list_flag, FALSE) AS westcliff_reading_list_flag,
    COALESCE(RL.slg_reading_list_flag,       FALSE) AS slg_reading_list_flag,
    COALESCE(RL.jstor_reading_list_flag,     FALSE) AS jstor_reading_list_flag,
    COALESCE(RL.derby_reading_list_flag,     FALSE) AS derby_reading_list_flag,
    COALESCE(RL.baptist_reading_list_flag,   FALSE) AS baptist_reading_list_flag,
    COALESCE(RL.norwich_reading_list_flag,   FALSE) AS norwich_reading_list_flag,
    COALESCE(RL.leicester_reading_list_flag, FALSE) AS leicester_reading_list_flag,
    COALESCE(RL.sacap_reading_list_flag,     FALSE) AS sacap_reading_list_flag,
    COALESCE(RL.holycross_reading_list_flag, FALSE) AS holycross_reading_list_flag,
    COALESCE(RL.ascent_reading_list_flag,    FALSE) AS ascent_reading_list_flag,
    COALESCE(RL.mountst_reading_list_flag,   FALSE) AS mountst_reading_list_flag,
    COALESCE(RL.follet_reading_list_flag,    FALSE) AS follet_reading_list_flag,
    COALESCE(RL.boston_reading_list_flag,   FALSE) AS boston_reading_list_flag,
    COALESCE(RL.m1_total_rl_count,           0)     AS m1_total_rl_count,
    COALESCE(RL.m2_rl_score,                 0)     AS m2_rl_score
FROM BMG_BASE
LEFT JOIN RL_SCORES_PER_ISBN RL ON (BMG_BASE.isbn_id = RL.isbn)
),


BASE_RL_ADJUSTMENT AS
(
SELECT *,

    /* -------- APPROACH 1 (M1): RL Count Multiplier --------
       All RLs treated equally regardless of tier
       Multiplier = 1 + total RL count
       Formula: total_enrolment × (1 + m1_total_rl_count)   */
    (1 + m1_total_rl_count)                              AS m1_multiplier,
    ROUND(total_enrolment * (1 + m1_total_rl_count), 0)  AS m1_adjusted_enrolment,

    /* -------- APPROACH 2 (M2): Tier-Weighted RL Multiplier --------
       High   = 2.0 → UWL, UOL, Slingshot, Derby, Boston
       Medium = 1.5 → Westcliff, JSTOR, Baptist, Leicester, SACAP, HolyCross, MountSt, Follet
       Low    = 1.0 → Norwich, Ascent
       RL Score pre-computed in RL_SCORES_PER_ISBN
       Formula: total_enrolment × (1 + m2_rl_score)         */
    ROUND(1 + m2_rl_score, 1)                            AS m2_multiplier,
    ROUND(total_enrolment * (1 + m2_rl_score), 0)        AS m2_adjusted_enrolment

FROM BASE_RL_JOIN
),


BASE_RL_SCORE_CALC AS
(
SELECT *,

    /* ---- Total number of reading lists used in the model (constant) ---- */
    15 AS total_rl_in_model,

    /* -------- M1: Normalised Score (1-100) - Log scaled -------- */
    ROW_NUMBER() OVER (ORDER BY m1_adjusted_enrolment DESC, total_enrolment DESC) AS m1_value_rank,

    ROUND(1 + (
        (LOG(NULLIF(m1_adjusted_enrolment, 0)) - MIN(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER()) /
        NULLIF(MAX(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER() - MIN(LOG(NULLIF(m1_adjusted_enrolment, 0))) OVER(), 0)
    ) * 99, 1) AS m1_value_score,

    /* -------- M2: Normalised Score (1-100) - Log scaled -------- */
    ROW_NUMBER() OVER (ORDER BY m2_adjusted_enrolment DESC, total_enrolment DESC) AS m2_value_rank,

    ROUND(1 + (
        (LOG(NULLIF(m2_adjusted_enrolment, 0)) - MIN(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER()) /
        NULLIF(MAX(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER() - MIN(LOG(NULLIF(m2_adjusted_enrolment, 0))) OVER(), 0)
    ) * 99, 1) AS m2_value_score

FROM BASE_RL_ADJUSTMENT
)


SELECT *,
    DATE(current_timestamp) AS snapshot_date,
    current_timestamp       AS last_updated_date
FROM BASE_RL_SCORE_CALC
--ORDER BY m2_value_score DESC
;
