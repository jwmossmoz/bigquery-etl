WITH kitsune_questions AS (
  SELECT
    question_id,
    DATE(
      created_date
    ) AS creation_date, -- TODO: timestamp to know the time between question and answer?
    creator_username AS content_creator,
    product,
    locale,
    topic,
    tier1_topic,
    tier2_topic,
    tier3_topic,
    title,
    question_content AS content
  FROM
    `moz-fx-data-shared-prod.sumo_syndicate.kitsune_questions_plus`
  WHERE
    is_spam = FALSE
    AND is_locked = FALSE
    AND DATE(
      created_date
    ) >= '2026-03-24' -- TODO: start date. This is temporarily the date of release for Firefox 149 major used for the POC.
),
kitsune_answers AS (
  SELECT
    answer_id,
    creator_username AS answer_creator,
    question_id,
    answer_content,
    created_date AS answer_creation_datetime,
    num_helpful_votes,
    num_unhelpful_votes
  FROM
    `moz-fx-data-shared-prod.sumo_syndicate.kitsune_answers_raw`
  WHERE
    is_spam = FALSE
    AND DATE(
      created_date
    ) >= '2026-03-24' -- TODO: start date. This one is the release for Firefox 149 major.
),
kitsune_joined AS (
  SELECT
    kitsune_questions.*,
    kitsune_answers.* EXCEPT (question_id)
  FROM
    kitsune_questions
  LEFT JOIN
    kitsune_answers
    USING (question_id)
),
kitsune_questions_distinct AS (
  SELECT DISTINCT
    question_id,
    title,
    content
  FROM
    kitsune_joined
),
kitsune_llm AS (
  SELECT
    question_id,
    AI.GENERATE(
      prompt => CONCAT(
        'You are analyzing a Mozilla Firefox support forum question. ',
        'Extract the following fields and return them as structured data. ',
        'summary_llm: maximum 8 words, clear, factual, in English. ',
        'category_llm: exactly 1 reusable classification label, preferably 1 word, maximum 2 words. ',
        'language_llm: BCP 47 language tag of the question text, including region, e.g. en-US. ',
        'entities_llm: array of up to 3 important normalized entities (e.g. product names, features, error codes), short, deduplicated. ',
        'topics_llm: array of up to 3 normalized topics, preferably 1 word, maximum 2 words each, ',
        'reusable across similar texts, suitable as classification labels. ',
        'sentiment_score: float from -1 to 1 where -1 is very negative, 0 is neutral, 1 is very positive. ',
        'Title: ',
        title,
        '\n',
        'Content: ',
        content
      ),
      endpoint => 'gemini-2.5-pro-001',
      output_schema => 'summary_llm STRING, category_llm STRING, language_llm STRING, entities_llm ARRAY<STRING>, topics_llm ARRAY<STRING>, sentiment_score FLOAT64'
    ) AS llm_result
  FROM
    kitsune_questions_distinct
),
kitsune_embedding AS (
  SELECT
    question_id,
    AI.EMBED(CONCAT(title, ' ', content), endpoint => 'gemini-embedding-001').result AS embedding
  FROM
    kitsune_questions_distinct
)
SELECT
  kitsune_joined.creation_date,
  question_id,
  answer_id,
  kitsune_joined.title,
  kitsune_joined.content,
  CASE
    product
    WHEN "firefox"
      THEN "Firefox Desktop"
    WHEN "mobile"
      THEN "Fenix" --  TODO: is this how it's setup in Kitsune? What happens when more mobile product are added? Should we create the correct lookup?
    WHEN "ios"
      THEN "Firefox iOS"
    WHEN "firefox-enterprise"
      THEN "Firefox Enterprise"
    ELSE "Non Firefox"
  END AS product,
  locale,
  topic,
  tier1_topic,
  tier2_topic,
  tier3_topic,
  answer_content,
  'question' AS type,
  IF(kitsune_joined.content_creator = answer_creator, TRUE, FALSE) AS is_self_answer,
  IF(
    product IN ('firefox-enterprise', 'ios', 'mobile', 'firefox'),
    TRUE,
    FALSE
  ) AS is_firefox_product,
  num_helpful_votes,
  num_unhelpful_votes,
  kitsune_llm.llm_result.summary_llm,
  kitsune_llm.llm_result.category_llm,
  kitsune_llm.llm_result.language_llm,
  kitsune_llm.llm_result.entities_llm,
  kitsune_llm.llm_result.topics_llm,
  kitsune_llm.llm_result.sentiment_score,
  EXP(
    -DATE_DIFF(CURRENT_DATE(), DATE(kitsune_joined.creation_date), DAY) / 7
  ) AS recency_score, -- TODO, define this number of days.
  embedding,
  STRUCT(
    ['title', 'content'] AS input_fields,
    LENGTH(CONCAT(kitsune_joined.title, ' ', kitsune_joined.content)) AS input_char_count,
    'gemini-2.5-pro-001' AS model_version,
    'gemini-embedding-001' AS embedding_version,
    'v1' AS prompt_version,
    CAST(CURRENT_TIMESTAMP() AS STRING) AS analysis_timestamp,
    CASE
      WHEN kitsune_llm.llm_result.category_llm IS NOT NULL
        AND LENGTH(TRIM(kitsune_llm.llm_result.category_llm)) > 0
        AND kitsune_llm.llm_result.language_llm IS NOT NULL
        AND LENGTH(TRIM(kitsune_llm.llm_result.language_llm)) > 0
        AND kitsune_llm.llm_result.sentiment_score IS NOT NULL
        AND kitsune_llm.llm_result.sentiment_score
        BETWEEN -1
        AND 1
        AND kitsune_llm.llm_result.entities_llm IS NOT NULL
        AND ARRAY_LENGTH(kitsune_llm.llm_result.entities_llm) > 0
        AND ARRAY_LENGTH(
          ARRAY(
            SELECT
              1
            FROM
              UNNEST(kitsune_llm.llm_result.entities_llm) t
            WHERE
              t IS NOT NULL
              AND LENGTH(TRIM(t)) > 0
          )
        ) = ARRAY_LENGTH(kitsune_llm.llm_result.entities_llm)
        AND kitsune_llm.llm_result.topics_llm IS NOT NULL
        AND ARRAY_LENGTH(kitsune_llm.llm_result.topics_llm) > 0
        AND ARRAY_LENGTH(
          ARRAY(
            SELECT
              1
            FROM
              UNNEST(kitsune_llm.llm_result.topics_llm) t
            WHERE
              t IS NOT NULL
              AND LENGTH(TRIM(t)) > 0
          )
        ) = ARRAY_LENGTH(kitsune_llm.llm_result.topics_llm)
        THEN 'SUCCESS'
      ELSE 'FAILED'
    END AS status
  ) AS metadata
FROM
  kitsune_joined
LEFT JOIN
  kitsune_llm
  USING (question_id)
LEFT JOIN
  kitsune_embedding
  USING (question_id)
