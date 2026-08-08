-- Language recall: for a given language id, how many high-consensus edges
-- (wp_count >= min_count) does it witness vs. not witness?
-- The witnessed side uses `witnesses @> ARRAY[:lang_id]::int2[]`, served by
-- wp_links_witnesses_gin.
--
-- Usage:
--   psql -d algae -v lang_id=5 -v min_count=10 -f queries/language_recall.sql
-- (Find an id with: SELECT id FROM languages WHERE code = 'eo';)

WITH witnessed AS (
    SELECT count(*) AS n
    FROM wp_links
    WHERE wp_count >= :min_count
      AND witnesses @> ARRAY[:lang_id]::int2[]
),
total AS (
    SELECT count(*) AS n
    FROM wp_links
    WHERE wp_count >= :min_count
)
SELECT
    :lang_id                AS lang_id,
    :min_count              AS min_count,
    witnessed.n             AS witnessed,
    total.n - witnessed.n   AS not_witnessed
FROM witnessed, total;
