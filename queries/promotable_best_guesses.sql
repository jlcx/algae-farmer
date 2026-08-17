-- Best-guess edges with enough independent witnesses to be worth a look,
-- with the trusted evidence (if any) alongside: wp_links says whether some
-- language resolved the same pair through a trusted strategy, wd_links
-- whether Wikidata itself relates the two entities.
--
-- Reading the join results:
--   wp_count IS NULL AND wd_props IS NULL: the pair exists only as label
--     matches — candidate merged-article (one article covering two concepts)
--     or missing-sitelink cases.
--   trusted evidence present: the best-guess witnesses corroborate an edge
--     the graph already has; promotion would add witness languages, not edges.
--
-- Usage:
--   psql -d algae -v threshold=3 -f queries/promotable_best_guesses.sql

SELECT b.src,
       b.dst,
       b.n              AS bg_witnesses,
       w.wp_count,
       wd.props         AS wd_props
FROM obs_best_guess_links b
LEFT JOIN wp_links w ON w.src = b.src AND w.dst = b.dst
LEFT JOIN LATERAL (
    SELECT array_agg(prop ORDER BY prop) AS props
    FROM wd_links
    WHERE src = b.src AND dst = b.dst
) wd ON true
WHERE b.n >= :threshold
ORDER BY b.n DESC, b.src, b.dst;
