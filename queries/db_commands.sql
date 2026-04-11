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
    PRIMARY KEY (qid, property, time_value, source_property, source_target)
);

-- Entity list with labels and Wikipedia coverage
CREATE TABLE IF NOT EXISTS wd_entities (
    qid VARCHAR(11),
    best_label VARCHAR,
    wp_count INT,
    PRIMARY KEY (qid)
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
    PRIMARY KEY (lang, lemma)
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

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_wp_links_src ON wp_links (src);
CREATE INDEX IF NOT EXISTS idx_wp_links_dst ON wp_links (dst);
CREATE INDEX IF NOT EXISTS idx_wp_links_count ON wp_links (wp_count DESC);
CREATE INDEX IF NOT EXISTS idx_wd_links_src ON wd_links (src);
CREATE INDEX IF NOT EXISTS idx_wd_links_dst ON wd_links (dst);
CREATE INDEX IF NOT EXISTS idx_wd_dates_qid ON wd_dates (qid);
CREATE INDEX IF NOT EXISTS idx_wd_entities_qid ON wd_entities (qid);
