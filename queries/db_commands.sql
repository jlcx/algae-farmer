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

-- Cross-language Wikipedia link consensus
CREATE TABLE IF NOT EXISTS wp_links (
    src VARCHAR(11),    -- source QID
    dst VARCHAR(11),    -- destination QID
    wp_count INT,       -- number of Wikipedia languages with this link
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

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_wp_links_src ON wp_links (src);
CREATE INDEX IF NOT EXISTS idx_wp_links_dst ON wp_links (dst);
CREATE INDEX IF NOT EXISTS idx_wp_links_count ON wp_links (wp_count DESC);
CREATE INDEX IF NOT EXISTS idx_wd_links_src ON wd_links (src);
CREATE INDEX IF NOT EXISTS idx_wd_links_dst ON wd_links (dst);
CREATE INDEX IF NOT EXISTS idx_wd_dates_qid ON wd_dates (qid);
CREATE INDEX IF NOT EXISTS idx_wd_entities_qid ON wd_entities (qid);
CREATE INDEX IF NOT EXISTS idx_wd_labels_qid ON wd_labels (qid);
