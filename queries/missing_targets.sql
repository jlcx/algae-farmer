-- Recurring unresolvable link targets: top rows of obs_failed_targets by the
-- number of languages that independently failed to resolve the same string.
-- High n_langs means many wikis link a title that maps to no QID anywhere —
-- a missing article, or an article missing its sitelink/Wikidata item.
--
-- Identical-string matching across languages means proper nouns dominate,
-- by design: a name spelled the same way in many wikis is exactly the case
-- where cross-language aggregation of raw titles is meaningful.
--
-- Usage:
--   psql -d algae -v limit=100 -f queries/missing_targets.sql
-- (Requires `make obs_failed_targets_refreshed` after loading conv failures.)

SELECT target,
       n_langs,
       n_pairs
FROM obs_failed_targets
ORDER BY n_langs DESC, n_pairs DESC, target
LIMIT :limit;
