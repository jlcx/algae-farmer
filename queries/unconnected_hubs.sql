-- Unconnected hubs: titles that failed source lookup (the page exists but
-- maps to no QID) and are also link targets other pages in the same language
-- failed to resolve. Pages that exist, are linked to, and have no Wikidata
-- item — prime candidates for item creation or sitelink repair, ranked by
-- how many distinct source entities want them.
--
-- Usage:
--   psql -d algae -v limit=100 -f queries/unconnected_hubs.sql

SELECT lg.code       AS lang,
       s.title,
       count(*)      AS inbound_failed
FROM obs_src_not_found s
JOIN obs_conv_failures f
  ON f.lang_id = s.lang_id
 AND f.target  = s.title
JOIN languages lg ON lg.id = s.lang_id
GROUP BY lg.code, s.title
ORDER BY inbound_failed DESC, lang, s.title
LIMIT :limit;
