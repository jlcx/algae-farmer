-- WP-not-WD query: find pairs of entities heavily linked across Wikipedias
-- but with no corresponding Wikidata statement.
-- This is the signature ALGAE query.

SELECT * FROM wp_links
WHERE wp_count > 100
AND NOT EXISTS (
    SELECT 1 FROM wd_links
    WHERE (wd_links.src = wp_links.src AND wd_links.dst = wp_links.dst)
       OR (wd_links.src = wp_links.dst AND wd_links.dst = wp_links.src)
)
ORDER BY wp_count DESC
LIMIT 1000;
