/* =====================================================================
   AI USAGE & COST TRACKING  (LLM Tokens + TTS Voice)
   ---------------------------------------------------------------------
   Two event-level pipelines that price AI usage into GBP/USD:

     SECTION A  LLM token usage  -> nb_research_assistant_token_usage_event
                (Research Assistant + Ask The Book) - daily 7:05 PM
     SECTION B  TTS voice usage  -> nb_read_aloud_voice_usage_detail_event
                                    nb_read_aloud_voice_usage_event
                (Read Aloud / AWS Polly) - daily 8:35 AM

   Both parse event_properties JSON, attach pricing, convert USD->GBP on
   the event date, and write a priced event-level table. Re-runnable
   (DELETE + INSERT pattern).
   ===================================================================== */


/* =====================================================================
   SECTION A - LLM TOKEN USAGE (Research Assistant + Ask The Book)
   Target: reporting_layer.ad_hoc.nb_research_assistant_token_usage_event
   ===================================================================== */

--CREATE TABLE reporting_layer.ad_hoc.nb_research_assistant_token_usage_event AS
DELETE FROM reporting_layer.ad_hoc.nb_research_assistant_token_usage_event;

INSERT INTO reporting_layer.ad_hoc.nb_research_assistant_token_usage_event
WITH BASE AS 
(
SELECT 
date(record_date) as event_date,
CASE 
WHEN get_json_object(event_properties, '$.location') = 'research assistant' THEN 'Research Assistant'
WHEN get_json_object(event_properties, '$.location') = 'talk to book' THEN 'Ask The Book'
ELSE 'Unknown' END event_product,
CASE WHEN user_id is not null then 'User' else 'Visitor' end AS user_login_type,
coalesce(cast(user_id as string), get_json_object(event_properties, '$.raId')) as user_id_enrich,
get_json_object(event_properties, '$.raId') AS raId,
get_json_object(event_properties, '$.threadId') AS threadId,
get_json_object(event_properties, '$.requestId') AS requestId,
get_json_object(event_properties, '$.bookId') AS book_id,

get_json_object(event_properties, '$.promptTokens') AS prompt_tokens,
get_json_object(event_properties, '$.completionTokens') AS completion_tokens,
get_json_object(event_properties, '$.totalTokens') AS total_tokens,

get_json_object(event_properties, '$.model') AS model_value,
get_json_object(event_properties, '$.location') AS location,
case when event_properties = '[object Object]' then 'EMPTY' ELSE 'POPULATED' END event_properties_status,
a.*

FROM data_platform.prod.gold_event_tracking a
WHERE date(record_date) >= DATE'2026-03-11' -- when we started tracking the token eventevents
AND event_name IN ('research assistant response generated', 'talk to book response generated') -- This report caters for both research assistant & Ask the book
and coalesce(user_id,1) not in (select user_id from reporting_layer.prod.dim__users where is_internal_user = true)
),

TOKEN_USAGE_1 AS 
(
SELECT 
event_date,
event_product,
User_login_type,
user_id_enrich,
raId,
threadId,
requestId,
CAST(book_id AS bigint) AS book_id,
COALESCE(cast(prompt_tokens as bigint),0) AS prompt_tokens,
COALESCE(cast(completion_tokens as bigint),0) AS completion_tokens,
COALESCE(cast(total_tokens as bigint),0) AS total_tokens,
CASE WHEN total_tokens IS NOT NULL THEN TRUE ELSE FALSE END AS is_token_value_present,
model_value,
split(model_value, '-\\d{4}-')[0] AS model_name,     -- gpt-4o-mini
regexp_extract(model_value, '(\\d{4}-\\d{2}-\\d{2})', 1) AS model_date , -- 2024-07-18
location,
event_properties_status,
event_id,
unique_id,
session_id,
user_agent,
user_id,
user_ip_address,
geo_location,  
-- ip_location, device_type, device_id, screen_size, current_url, referrer_url, page_title,
environment_name,
event_name,
event_label,
event_properties,
timestamp,
record_date
FROM BASE
),


gbp_exchange_rate AS 
(
SELECT base,
    TO_DATE(extraction_date, 'yyyy-MM-dd') as extraction_date,
    FROM_UNIXTIME(extraction_epoch_timestamp) as extraction_timestamp,
    USD,
    row_number() OVER(PARTITION BY TO_DATE(extraction_date, 'yyyy-MM-dd')  ORDER BY TO_DATE(extraction_date, 'yyyy-MM-dd')  DESC) AS rnk
FROM data_platform.prod.gold_currency_exchange_rates
QUALIFY rnk  = 1
),



TOKEN_USAGE_2 AS 
(
/* We are currently using GPT-4o-mini

Input: $0.15 per million tokens
Output: $0.60 per million tokens

https://azure.microsoft.com/en-us/pricing/details/azure-openai/#:~:text=GPT%2D4o%2Dmini%2D0718%20Global 
*/
SELECT 
TOKEN_USAGE_1.*,
0.16 AS cost_per_million_input_token_usd,
0.60 AS cost_per_million_output_token_usd,
0.16 / gbp_exchange_rate.USD AS cost_per_million_input_token_gbp,
0.60 / gbp_exchange_rate.USD AS cost_per_million_output_token_gbp,
gbp_exchange_rate.USD as gbp_exchange_rate
FROM TOKEN_USAGE_1
LEFT JOIN gbp_exchange_rate ON (TOKEN_USAGE_1.event_date = gbp_exchange_rate.extraction_date)
),



TOKEN_USAGE_3 AS 
(
SELECT TOKEN_USAGE_2.*,
/* USD */
CASE 
WHEN prompt_tokens IS NULL THEN 0.0
WHEN prompt_tokens IS NOT NULL THEN cost_per_million_input_token_usd * (prompt_tokens/1000000) 
ELSE 0.0 END AS prompt_token_cost_usd,

CASE 
WHEN completion_tokens IS NULL THEN 0.0
WHEN completion_tokens IS NOT NULL THEN cost_per_million_output_token_usd * (completion_tokens/1000000) 
ELSE 0.0 END AS completion_token_cost_usd,

/* GBP */
CASE 
WHEN prompt_tokens IS NULL THEN 0.0
WHEN prompt_tokens IS NOT NULL THEN cost_per_million_input_token_gbp * (prompt_tokens/1000000) 
ELSE 0.0 END AS prompt_token_cost_gbp,

CASE 
WHEN completion_tokens IS NULL THEN 0.0
WHEN completion_tokens IS NOT NULL THEN cost_per_million_output_token_gbp * (completion_tokens/1000000) 
ELSE 0.0 END AS completion_token_cost_gbp

FROM TOKEN_USAGE_2
),


TOKEN_USAGE_4 AS (
SELECT TOKEN_USAGE_3.*,
(prompt_token_cost_usd + completion_token_cost_usd) AS total_token_cost_usd,
(prompt_token_cost_gbp + completion_token_cost_gbp) AS total_token_cost_gbp
FROM TOKEN_USAGE_3
),


LATEST_SUBSCRIPTION AS (
select user_id, subscription_key_id, plan_key_id, subscription_id, subscription_type, payment_channel, 
cast(organisation_id as bigint) as organisation_id, 
row_number() over(partition by user_id order by subscription_start_time desc ) rnk
from reporting_layer.prod.fct__subscriptions
qualify rnk = 1
),

/* We are using the users latest subscription info to extract payment channel to report on for not */
TOKEN_USAGE_5 AS (
SELECT TU4.*,
sub.subscription_key_id, sub.plan_key_id, sub.subscription_id, sub.subscription_type, sub.payment_channel, sub.organisation_id
FROM TOKEN_USAGE_4 TU4
LEFT JOIN LATEST_SUBSCRIPTION sub ON ( TU4.user_id = sub.user_id)
)



SELECT TOKEN_USAGE_5.*,
current_timestamp AS last_updated_date
FROM TOKEN_USAGE_5
;


/* =====================================================================
   SECTION B - TTS VOICE USAGE (Read Aloud / AWS Polly)
   Targets: nb_read_aloud_voice_usage_detail_event (parsed detail)
            nb_read_aloud_voice_usage_event       (priced event)
   ===================================================================== */

/* Load base table */
--CREATE TABLE reporting_layer.ad_hoc.nb_read_aloud_voice_usage_detail_event AS
DELETE FROM reporting_layer.ad_hoc.nb_read_aloud_voice_usage_detail_event;

INSERT INTO reporting_layer.ad_hoc.nb_read_aloud_voice_usage_detail_event
SELECT 
sur_session_key_id,
event_id,
unique_id,
session_id,
user_id,
user_id_original,
is_user_id_populated,
subscription_id,
subscription_key_id,
user_agent,
device_category,
device_group_id,
device_brand_type,
device_model,
country_id,
country,
ip_location_city,
ip_location_region,
environment_id,
environment_name,
device_type,
is_tablet,
device_id,
screen_size,
current_url,
referrer_url,
event_name_id,
event_name,
event_label,
event_properties,
third_party_ids,
analytics_cookie_consent,
highlight_id,
book_id,
location_id,
selected_topics,
selected_subtopics,
highlighted_text,
is_success,
reference_style,
workspace_id,
location,
event_timestamp,
event_date,
is_event_page_view,
is_event_search_related,
system_click_id,
click_id,
sys_date_ingested,
is_source_events,
CASE WHEN user_id is not null then TRUE else FALSE END AS is_logged_in_flag,
coalesce(get_json_object(event_properties, '$.bookId'), get_json_object(event_properties, '$.bookid'), get_json_object(event_properties, '$.book_id')) AS extract_book_id,
get_json_object(event_properties, '$.paragraphId') AS chapter_paragraph_string,
get_json_object(event_properties, '$.chapterId') AS chapter_id,
split_part(get_json_object(event_properties, '$.paragraphId'),'__',2) AS paragraph_id,
get_json_object(event_properties, '$.pageId') AS page_id,
COALESCE(get_json_object(event_properties, '$.chapterId'), get_json_object(event_properties, '$.pageId')) AS chapter_or_page_id,
get_json_object(event_properties, '$.skippedContent') AS skipped_content,
get_json_object(event_properties, '$.voiceId') as voice_name,
CASE WHEN get_json_object(event_properties, '$.fileFromCache') = 'true' THEN TRUE WHEN get_json_object(event_properties, '$.fileFromCache') = 'false' then FALSE ELSE NULL end AS file_from_cache,
try_cast(get_json_object(event_properties, '$.characterCount') as bigint) AS character_count,
CASE WHEN event_properties = '[object Object]' OR event_properties IS NULL OR event_properties = '' then FALSE ELSE TRUE END is_event_properties_populated
FROM reporting_layer.prod.fct__events evt
WHERE event_date >= DATE'2026-02-04' -- when we started tracking the events
AND event_name in ('get audio for book type epub','get audio for book type pdf')
;



/* Load event table */
-- CREATE TABLE reporting_layer.ad_hoc.nb_read_aloud_voice_usage_event AS
DELETE FROM reporting_layer.ad_hoc.nb_read_aloud_voice_usage_event;

INSERT INTO reporting_layer.ad_hoc.nb_read_aloud_voice_usage_event
WITH VOICE_USAGE AS 
(
SELECT *
FROM reporting_layer.ad_hoc.nb_read_aloud_voice_usage_detail_event
WHERE is_event_properties_populated = TRUE
),



VOICE_USAGE_1 AS 
(
SELECT 
VOICE_USAGE.*, 
CASE WHEN file_from_cache = 'true' THEN TRUE WHEN file_from_cache = 'false' then FALSE ELSE NULL end AS is_file_from_cache,
lower(books.book_format) AS voice_book_format,
case when books.book_number_of_pages = '' then null else books.book_number_of_pages end AS book_number_of_pages
FROM VOICE_USAGE
LEFT JOIN reporting_layer.prod.dim__books books ON ( books.book_id = VOICE_USAGE.book_id)
),


book_character AS 
(
SELECT *
FROM (
SELECT
book_id, lower(format) as bk_format, book_character_count, book_chapter_number, book_chapter_character_count,
row_number() OVER (PARTITION BY book_id, book_chapter_number ORDER BY COALESCE(book_character_count,0) DESC) AS rnk
FROM (
SELECT 
    book_id,
    format,
    character_count AS book_character_count,
    chapter.key   AS book_chapter_number,
    chapter.value AS book_chapter_character_count
FROM data_platform.prod.gold_book_char_count
LATERAL VIEW EXPLODE(from_json(chapter_data, 'MAP<STRING, INT>')) chapter
WHERE lower(format) = 'epub'
)
WHERE book_id IS NOT NULL AND book_chapter_number IS NOT NULL AND format IS NOT NULL
) AS subquery WHERE rnk = 1
),



VOICE_USAGE_2 AS 
(
SELECT 
VOICE_USAGE_1.*,
book_character.book_character_count,
book_character.book_chapter_character_count
FROM VOICE_USAGE_1
LEFT JOIN book_character ON ( VOICE_USAGE_1.book_id = book_character.book_id AND VOICE_USAGE_1.chapter_id = book_character.book_chapter_number AND VOICE_USAGE_1.voice_book_format = book_character.bk_format )
),


VOICE_USAGE_3 AS 
(
SELECT VOICE_USAGE_2.*,
dim_voice.voice_category AS voice_name_category,
dim_voice.voice_language AS voice_name_language,
dim_voice.cost_per_million_character_usd
FROM VOICE_USAGE_2
LEFT JOIN reporting_layer.ad_hoc.read_aloud_voice_dimension dim_voice
 ON ( VOICE_USAGE_2.voice_name = dim_voice.voice_name
  AND VOICE_USAGE_2.voice_book_format = dim_voice.voice_book_format
      -- SCD2 date range join: pick the dimension row valid at the time of the event - to cater for the change that convered Matthew/epub/premium to  Matthew/epub/standard
    AND CAST(VOICE_USAGE_2.event_timestamp AS TIMESTAMP) >= dim_voice.valid_from
    AND CAST(VOICE_USAGE_2.event_timestamp AS TIMESTAMP) <  dim_voice.valid_to
  
  )
),


gbp_exchange_rate AS 
(
SELECT base,
    TO_DATE(extraction_date, 'yyyy-MM-dd') as extraction_date,
    FROM_UNIXTIME(extraction_epoch_timestamp) as extraction_timestamp,
    USD,
    row_number() OVER(PARTITION BY TO_DATE(extraction_date, 'yyyy-MM-dd')  ORDER BY TO_DATE(extraction_date, 'yyyy-MM-dd')  DESC) AS rnk
FROM data_platform.prod.gold_currency_exchange_rates
QUALIFY rnk  = 1
),


VOICE_USAGE_4 AS 
(
SELECT 
VOICE_USAGE_3.*,
VOICE_USAGE_3.cost_per_million_character_usd / gbp_exchange_rate.USD AS cost_per_million_character_gbp,
gbp_exchange_rate.USD as gbp_exchange_rate
FROM VOICE_USAGE_3
LEFT JOIN gbp_exchange_rate ON (VOICE_USAGE_3.event_date = gbp_exchange_rate.extraction_date)
),


VOICE_USAGE_5 AS 
(
SELECT VOICE_USAGE_4.*,
CASE 
WHEN is_file_from_cache = TRUE THEN 0.0
WHEN is_file_from_cache = FALSE THEN cost_per_million_character_gbp * (character_count/1000000) ELSE 0.0 END AS voice_cost_gbp,
CASE 
WHEN is_file_from_cache = TRUE THEN 0.0
WHEN is_file_from_cache = FALSE THEN cost_per_million_character_usd * (character_count/1000000) ELSE 0.0 END AS voice_cost_usd,
current_timestamp AS last_updated_date
FROM VOICE_USAGE_4
)



SELECT *
FROM VOICE_USAGE_5
;
