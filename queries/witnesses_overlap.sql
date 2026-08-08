-- Edges witnessed by ANY of a given language set (clone-family filtering).
-- Uses `witnesses && ARRAY[...]::int2[]`, served by wp_links_witnesses_gin.
--
-- Usage (language codes, resolved via the languages table):
--   psql -d algae -v langs="{eo,fi,hy}" -f queries/witnesses_overlap.sql
--
-- The codes are resolved to ids in a separate statement (\gset) so the main
-- query filters on a constant array — the planner can then estimate
-- selectivity and use the GIN index where appropriate.

SELECT COALESCE(array_agg(id), '{}')::int2[] AS lang_ids
FROM languages
WHERE code = ANY(:'langs'::text[]) \gset

SELECT src, dst, wp_count, witnesses
FROM wp_links
WHERE witnesses && :'lang_ids'::int2[]
ORDER BY wp_count DESC;
