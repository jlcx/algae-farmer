-- ALGAE Database Schema
-- PostgreSQL tables for the ALGAE link graph pipeline

-- All entity-to-entity relationships from Wikidata
CREATE TABLE IF NOT EXISTS wd_links (
    src VARCHAR(11),    -- source QID (e.g., 'Q42')
    dst VARCHAR(11),    -- destination QID
    prop VARCHAR(7),    -- property ID (e.g., 'P31')
    PRIMARY KEY (src, dst, prop)
);

-- Date claims per entity
CREATE TABLE IF NOT EXISTS wd_dates (
    qid VARCHAR(11),            -- entity QID
    property VARCHAR(7),        -- date property (e.g., P569 = date of birth)
    time_value VARCHAR(32),     -- ISO 8601 time string from Wikidata
    precision SMALLINT,         -- Wikidata time precision (0=billion years .. 14=seconds)
    source_property VARCHAR(7) DEFAULT '', -- if nested: the parent claim's property; '' if top-level
    source_target VARCHAR(11) DEFAULT '',  -- if nested: the parent claim's target QID; '' if top-level
    PRIMARY KEY (qid, property, time_value, precision, source_property, source_target)
);

-- Entity list with labels and Wikipedia coverage
CREATE TABLE IF NOT EXISTS wd_entities (
    qid VARCHAR(11),
    best_label VARCHAR,
    wp_count INT,
    PRIMARY KEY (qid)
);

-- Per-language labels for Wikidata entities.
-- lang: language code from label_langs, or 'best' (chosen display label),
--       or 'doi' (P356 DOI value, first claim only)
CREATE TABLE IF NOT EXISTS wd_labels (
    lang VARCHAR,
    label VARCHAR,
    qid VARCHAR(11),
    PRIMARY KEY (lang, label, qid)
);

-- Coordinate location (P625) claims per entity
CREATE TABLE IF NOT EXISTS wd_coords (
    qid VARCHAR(11),                -- entity QID
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    altitude DOUBLE PRECISION,      -- nullable: altitude above reference globe
    precision DOUBLE PRECISION,     -- nullable: angular precision in degrees
    globe VARCHAR(11) DEFAULT '',   -- globe QID (e.g. Q2 = Earth); '' if unspecified
    PRIMARY KEY (qid, latitude, longitude, globe)
);

-- Append-only language dimension: ids are assigned once and never renumbered,
-- independent of run/languages.json regeneration. Loaders may only insert
-- codes that don't exist yet — never delete or update existing rows.
CREATE TABLE IF NOT EXISTS languages (
    id   SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code TEXT UNIQUE NOT NULL
);

-- Cross-language Wikipedia link consensus with per-language witness provenance
CREATE TABLE IF NOT EXISTS wp_links (
    src       VARCHAR(11) NOT NULL,  -- source QID
    dst       VARCHAR(11) NOT NULL,  -- destination QID
    witnesses INT2[]      NOT NULL   -- languages.id set, sorted ascending, no duplicates
                          CHECK (witnesses <> '{}'),
    wp_count  INT GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);

-- Lemma-to-lexeme mapping
CREATE TABLE IF NOT EXISTS lemma_lexeme (
    lang VARCHAR,
    lemma VARCHAR,
    lid VARCHAR,
    PRIMARY KEY (lang, lemma, lid)
);

-- Form-to-lexeme mapping
CREATE TABLE IF NOT EXISTS form_lexeme (
    lang VARCHAR,
    lemma VARCHAR,
    lid VARCHAR,
    PRIMARY KEY (lang, lemma, lid)
);

-- Lexeme-to-lexeme relationships
CREATE TABLE IF NOT EXISTS lexeme_lexeme (
    src VARCHAR,
    dst VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src, dst, prop)
);

-- Sense-to-item relationships
CREATE TABLE IF NOT EXISTS sense_item (
    src_lid VARCHAR,
    src_sid VARCHAR,
    dst VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src_lid, src_sid, dst, prop)
);

-- Sense-to-sense relationships
CREATE TABLE IF NOT EXISTS sense_sense (
    src_lid VARCHAR,
    src_sid VARCHAR,
    dst_lid VARCHAR,
    dst_sid VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src_lid, src_sid, dst_lid, dst_sid, prop)
);

-- Wiktionary entry words
CREATE TABLE IF NOT EXISTS wkt_entries (
    entry VARCHAR,
    PRIMARY KEY (entry)
);

-- Wiktionary cross-language links
CREATE TABLE IF NOT EXISTS wkt_links (
    src VARCHAR,
    dst VARCHAR,
    wkt_count INT,
    PRIMARY KEY (src, dst)
);

-- Abstract Wikipedia main-namespace pages (one row per QID)
CREATE TABLE IF NOT EXISTS aw_entries (
    qid VARCHAR(11),
    PRIMARY KEY (qid)
);

-- Q/Z-IDs referenced inside Abstract Wikipedia pages
-- (K-suffixes stripped: e.g. Z825K1 stored as Z825)
CREATE TABLE IF NOT EXISTS aw_refs (
    src_qid VARCHAR(11),
    ref     VARCHAR(16),
    PRIMARY KEY (src_qid, ref)
);

-- Wikifunctions Z-objects (one row per ZID)
CREATE TABLE IF NOT EXISTS wf_objects (
    zid VARCHAR(16),
    PRIMARY KEY (zid)
);

-- Wikifunctions multilingual labels and aliases
-- lang: Wikifunctions natural-language ZID (e.g. Z1002 = English)
-- kind: 'L' persistent label (Z2K3), 'A' alias (Z2K4)
CREATE TABLE IF NOT EXISTS wf_labels (
    zid   VARCHAR(16),
    lang  VARCHAR(16),
    kind  CHAR(1),
    label VARCHAR,
    PRIMARY KEY (zid, lang, kind, label)
);

-- DBpedia typed relationships (extracted from mappingbased-objects)
CREATE TABLE IF NOT EXISTS dbp_links (
    src VARCHAR(11),    -- source QID
    dst VARCHAR(11),    -- destination QID
    predicate VARCHAR,  -- DBpedia predicate URI
    PRIMARY KEY (src, dst, predicate)
);

-- ============================================================
-- Conversion obstruction records (TASK_obstruction_records.md)
-- ============================================================
-- Places where a language's local link structure fails to glue onto the
-- shared QID graph. Loaded from wp_convert's per-language diagnostic files;
-- language references use languages.id (append-only), never text codes.

-- Append-only lookup for wp_witness_methods.method, same discipline as
-- `languages`: ids are assigned once and never renumbered. Must stay in sync
-- with the METHOD_* constants in src/bin/wp_convert.rs.
CREATE TABLE IF NOT EXISTS resolution_methods (
    id   SMALLINT PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);
INSERT INTO resolution_methods VALUES
    (1, 'redirect_deep'),
    (2, 'crosslang_qid'),
    (3, 'crosslang_title')
ON CONFLICT (id) DO NOTHING;

-- Strategy (i): edges resolved only via the 'best' label fallback. Same shape
-- as wp_links (a candidate edge stalk, aggregated with witness provenance)
-- but kept in a separate table so no existing query can accidentally treat
-- them as consensus.
CREATE TABLE IF NOT EXISTS obs_best_guess_links (
    src       VARCHAR(11) NOT NULL,
    dst       VARCHAR(11) NOT NULL,
    witnesses INT2[]      NOT NULL,
    n         INT GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);

-- Strategy (k): unresolvable link targets. Stored per-language (long form):
-- the source QID matters (which entities want the missing target), and
-- cross-language aggregation of raw title strings is only meaningful for
-- identical titles — that is provided by the obs_failed_targets view below,
-- not by the storage format.
CREATE TABLE IF NOT EXISTS obs_conv_failures (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    src     VARCHAR(11) NOT NULL,
    target  TEXT NOT NULL CHECK (length(target) <= 384),
    PRIMARY KEY (lang_id, src, target)
);

-- Source articles with no QID mapping (unconnected pages).
CREATE TABLE IF NOT EXISTS obs_src_not_found (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    title   TEXT NOT NULL CHECK (length(title) <= 384),
    PRIMARY KEY (lang_id, title)
);

-- Redirect chains exceeding the depth limit, and cycles.
CREATE TABLE IF NOT EXISTS obs_redirect_anomalies (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    title   TEXT NOT NULL,
    kind    TEXT NOT NULL CHECK (kind IN ('depth_exceeded', 'cycle')),
    PRIMARY KEY (lang_id, title)
);

-- Side-channel: degraded successful resolutions present in wp_links
-- (crosslang strategies and redirect chains of depth >= 2; routine
-- direct/capfirst/whitespace/depth-1 resolutions are not recorded).
CREATE TABLE IF NOT EXISTS wp_witness_methods (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    src     VARCHAR(11) NOT NULL,
    dst     VARCHAR(11) NOT NULL,
    method  INT2 NOT NULL REFERENCES resolution_methods(id),
    PRIMARY KEY (lang_id, src, dst, method)
);

-- Cross-language failed-target aggregation (replaces
-- dsts_failed_uniq_combined.txt as the queryable artifact). Created WITH NO
-- DATA; populated by REFRESH (Makefile target obs_failed_targets_refreshed).
CREATE MATERIALIZED VIEW IF NOT EXISTS obs_failed_targets AS
SELECT target,
       count(DISTINCT lang_id) AS n_langs,
       count(*)                AS n_pairs
FROM obs_conv_failures
GROUP BY target
WITH NO DATA;

CREATE INDEX IF NOT EXISTS obs_bgl_witnesses_gin ON obs_best_guess_links USING GIN (witnesses);
CREATE INDEX IF NOT EXISTS obs_cf_target ON obs_conv_failures (target);
CREATE INDEX IF NOT EXISTS obs_ft_nlangs ON obs_failed_targets (n_langs DESC);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_wp_links_src ON wp_links (src);
CREATE INDEX IF NOT EXISTS idx_wp_links_dst ON wp_links (dst);
CREATE INDEX IF NOT EXISTS idx_wp_links_count ON wp_links (wp_count DESC);
CREATE INDEX IF NOT EXISTS wp_links_witnesses_gin ON wp_links USING GIN (witnesses);
CREATE INDEX IF NOT EXISTS idx_wd_links_src ON wd_links (src);
CREATE INDEX IF NOT EXISTS idx_wd_links_dst ON wd_links (dst);
CREATE INDEX IF NOT EXISTS idx_wd_dates_qid ON wd_dates (qid);
CREATE INDEX IF NOT EXISTS idx_wd_entities_qid ON wd_entities (qid);
CREATE INDEX IF NOT EXISTS idx_wd_labels_qid ON wd_labels (qid);
CREATE INDEX IF NOT EXISTS idx_wd_coords_qid ON wd_coords (qid);
