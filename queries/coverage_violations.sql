-- Coverage violations: witnesses counted in wp_count whose language resolved
-- the link cross-language (crosslang_qid / crosslang_title) — i.e. the
-- witnessing wiki has no article of its own on dst. Such a witness still
-- attests that the language's editors consider the concepts related, but it
-- is weaker evidence than a within-language link, so edges where a large
-- fraction of wp_count is cross-language can be down-weighted downstream.
--
-- The join to wp_links keeps only witnesses actually counted (the language
-- id present in the edge's witness array), served by wp_links_witnesses_gin.
--
-- Usage:
--   psql -d algae -v limit=100 -f queries/coverage_violations.sql

SELECT m.src,
       m.dst,
       w.wp_count,
       count(DISTINCT m.lang_id)                              AS violating,
       round(count(DISTINCT m.lang_id)::numeric / w.wp_count, 3) AS violation_fraction
FROM wp_witness_methods m
JOIN wp_links w
  ON w.src = m.src
 AND w.dst = m.dst
 AND w.witnesses @> ARRAY[m.lang_id]
WHERE m.method IN (2, 3)   -- crosslang_qid, crosslang_title
GROUP BY m.src, m.dst, w.wp_count
ORDER BY violation_fraction DESC, w.wp_count DESC, m.src, m.dst
LIMIT :limit;
