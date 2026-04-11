-- Common item type query: joins frequently-linked items against P31 (instance of)
-- to determine the types of commonly-linked entities.

SELECT e.qid, e.best_label, e.wp_count AS entity_wp_count,
       type_link.dst AS type_qid,
       type_entity.best_label AS type_label,
       link_stats.total_links,
       link_stats.avg_wp_count
FROM wd_entities e
JOIN (
    SELECT src AS qid, COUNT(*) AS total_links, AVG(wp_count) AS avg_wp_count
    FROM wp_links
    WHERE wp_count > 10
    GROUP BY src
    HAVING COUNT(*) > 5
) link_stats ON link_stats.qid = e.qid
LEFT JOIN wd_links type_link ON type_link.src = e.qid AND type_link.prop = 'P31'
LEFT JOIN wd_entities type_entity ON type_entity.qid = type_link.dst
ORDER BY link_stats.avg_wp_count DESC
LIMIT 500;
