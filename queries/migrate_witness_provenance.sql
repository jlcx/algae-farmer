-- Migration: per-language witness provenance for wp_links.
--
-- Replaces the scalar wp_count with a witnesses int2[] column backed by the
-- append-only languages dimension table; wp_count becomes a stored generated
-- column so existing queries work unchanged.
--
-- wp_links is dropped and recreated (it is fully rebuilt from pipeline files).
-- Reload afterwards with:  make wp_links_loaded
-- (No views depended on wp_links at migration time; if any exist, recreate
-- them after this script.)

BEGIN;

CREATE TABLE IF NOT EXISTS languages (
    id   SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code TEXT UNIQUE NOT NULL
);

DROP TABLE IF EXISTS wp_links;

CREATE TABLE wp_links (
    src       VARCHAR(11) NOT NULL,
    dst       VARCHAR(11) NOT NULL,
    witnesses INT2[]      NOT NULL CHECK (witnesses <> '{}'),
    wp_count  INT GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);

CREATE INDEX idx_wp_links_src  ON wp_links (src);
CREATE INDEX idx_wp_links_dst  ON wp_links (dst);
CREATE INDEX idx_wp_links_count ON wp_links (wp_count DESC);
CREATE INDEX wp_links_witnesses_gin ON wp_links USING GIN (witnesses);

COMMIT;
