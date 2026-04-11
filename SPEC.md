# ALGAE Specification

**ALGAE** (originally standing for Aggregated Link Graph Available to Everyone) builds a unified, weighted link graph across Wikimedia projects and loads it into PostgreSQL for querying and analysis. Its central insight is that cross-language Wikipedia link consensus is a strong signal for which relationships should exist in Wikidata's structured data.

This spec covers the offline data pipeline, database schema, and query patterns.

---

## 1. Data Sources

All source data comes from Wikimedia dump files and the DBpedia project.

| Source | Format | Typical size | Dump URL pattern |
|---|---|---|---|
| Wikidata entities | JSON (gzipped/bz2), one entity per line, wrapped in `[...]` | ~100 GB compressed | `dumps.wikimedia.org/wikidatawiki/entities/latest-all.json.gz` |
| Wikidata lexemes | Same JSON format as entities | Much smaller | Same dump or separate lexeme dump |
| Wikipedia (per language) | MediaWiki XML export (bz2) | Varies; English ~22 GB compressed | `dumps.wikimedia.org/{lang}wiki/latest/{lang}wiki-latest-pages-articles-multistream.xml.bz2` |
| Wiktionary (per language) | MediaWiki XML export (bz2) | Varies | `dumps.wikimedia.org/{lang}wiktionary/latest/{lang}wiktionary-latest-pages-articles-multistream.xml.bz2` |
| Wikimedia Commons | Multistream index (bz2) | ~400 MB compressed | `commonswiki-latest-pages-articles-multistream-index.txt.bz2` |
| DBpedia | Turtle (.ttl) files per language | Varies | `downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/{version}/mappingbased-objects_lang={lang}.ttl.bz2` |

### 1.1 Language discovery and registry

Rather than maintaining hardcoded language lists in individual scripts, the pipeline uses a single auto-generated registry file (`run/languages.json`) as its canonical source of truth for which language editions to process.

#### 1.1.1 Discovery step (`discover_languages`)

Runs as the first step of the pipeline, before any processing begins. Queries Wikimedia and DBpedia dump indexes to enumerate every language edition with a current dump available:

- **Wikipedia:** Enumerates `dumps.wikimedia.org/backup-index.html` (or directory listings) for all `{lang}wiki` editions that have a completed `pages-articles-multistream` dump.
- **Wiktionary:** Same approach, scanning for `{lang}wiktionary` editions.
- **DBpedia:** Enumerates `downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/` for all available `lang=` directories.

**Output:** `run/languages.json` with the following structure:

```json
{
  "discovered_at": "2026-04-10T12:00:00Z",
  "wikipedia": ["en", "de", "fr", "es", ...],
  "wiktionary": ["en", "de", "fr", "es", ...],
  "dbpedia": ["en", "de", "fr", "es", ...]
}
```

The lists include every language edition with an available dump — no manual curation. The `discovered_at` timestamp allows Make to detect when re-discovery is needed (e.g., if the registry is older than the configured staleness threshold, default 7 days).

#### 1.1.2 Override mechanism

An optional `languages_override.json` file, placed in the pipeline root, restricts processing to a specified subset. Format:

```json
{
  "wikipedia": ["eo", "fi", "hy", "simple"],
  "wiktionary": ["eo", "fi"],
  "dbpedia": ["en", "de"]
}
```

If present, the pipeline intersects the override lists with the discovered lists (so an override entry for a language with no available dump is silently ignored). If absent, all discovered languages are processed.

#### 1.1.3 Consumption

All pipeline scripts and tools read from `run/languages.json` (filtered by `languages_override.json` if present) rather than maintaining their own language lists. A shared helper function/module loads the resolved list for a given project (`wikipedia`, `wiktionary`, or `dbpedia`). The `wd_preproc` label language chain is also derived from the Wikipedia list in the registry, plus the synthetic entries `mul`, `doi`, and `best`.

---

## 2. Pipeline Stages

The pipeline is orchestrated via a `Makefile`. All intermediate and output files are written into a `run/` subdirectory. Make's built-in dependency tracking and timestamp-based invalidation ensure that only out-of-date targets are rebuilt, and `make -jN` enables parallel execution of independent targets.

### 2.1 Commons preprocessing (`commons_preproc`)

**Input:** Commons multistream index, streamed from bz2 via stdin.

**Processing:** Each line of the index has the format `offset:page_id:title`. The script extracts the title (third colon-separated field).

**Output:** `commons_files.txt` -- one filename per line. Used later by `wp_convert` to identify links that point to Commons files rather than Wikipedia articles.

### 2.2 Wikidata entity preprocessing (`wd_preproc`)

**Input:** Complete Wikidata JSON dump, streamed via stdin (one JSON object per line, with leading/trailing `[`, `]` and commas between lines).

**Processing per entity:**

1. **Parse JSON** -- strip trailing comma and newline, then parse as JSON.
2. **Extract labels** -- For each language in the label language chain (derived from the Wikipedia list in `run/languages.json`, plus `mul`, `doi`, and `best`):
   - If the entity has a sitelink for `{lang}wiki`, use that article title as the label for that language.
   - The first label found along the chain becomes the `best` label.
   - If no sitelink label is found for a language but a Wikidata label exists, use that for `best` (if `best` is still unset).
   - If the entity has a P356 (DOI) claim, extract its value as the `doi` label.
   - Fallback: if no label found at all, `best` = the entity's QID.
3. **Extract relationships** -- For every claim on the entity (items, properties, and lexemes), if the mainsnak datatype is `wikibase-item` or `wikibase-property`:
   - Record `(entity_id, target_id, property_id)`.
   - Also traverse qualifiers on each claim, extracting the same tuple shape for qualifier values of allowed datatypes.
4. **Extract date claims** -- For claims whose property is in `all_times` (a set of ~80 time-related properties), extract `(property, time_value, precision)`. Also check claims in `times_plus_nested` for date qualifiers nested inside non-date claims (e.g., P580 "start time" as a qualifier on P108 "employer").
5. **Extract Wikipedia language coverage** -- Collect the set of sitelinks ending in `wiki` (excluding e.g. `wikiquote`), derive language codes.

**Output files:**

| File | Format | Content |
|---|---|---|
| `items.csv` | CSV (quoted) | `qid, best_label, wp_count` (wp_count = number of Wikipedia sitelinks) |
| `links.csv` | CSV (unquoted) | `src_qid, dst_qid, property_id` -- all entity-to-entity relationships |
| `wd_labels.tsv` | TSV | `lang\tlabel\tqid` -- one row per language per entity, including `best` and `doi` |
| `date_claims.csv` | CSV | `qid, property, time_value, precision, source_property, source_target` -- top-level date claims have empty source_property and source_target; nested qualifiers include the parent claim's property and target |

**Post-processing:** `sort links.csv | uniq > links_uniq.csv`

### 2.3 Wikidata lexeme preprocessing (`lex_preproc`)

**Input:** Wikidata lexeme JSON dump, streamed via stdin (same format as entity dump).

**Processing per lexeme:**

1. **Lemmas** -- For each lemma on the lexeme, record `(language, value, lexeme_id)`.
2. **Lexeme claims** -- Extract relationships based on property category:
   - **Lexeme-to-lexeme** (L2L): Properties P5191 (derived from lexeme), P5238 (combines lexemes), P6571 (collective noun for animals). Record `(src_lid, dst_lid, property)`.
   - **Lexeme-to-item** (L2Q): Properties P6684 (first attested from), P5137 (item for this sense). Record `(lid, qid, property)`.
3. **Forms** -- For each form's representations, record `(language, form_value, lexeme_id)`.
4. **Senses** -- For each sense's claims:
   - **Sense-to-item** (S2Q): Properties P5137, P6684, P9970. Record `(lid, sense_id, target_qid, property)`.
   - **Sense-to-sense** (S2S): Properties P5972 (translation), P5973 (synonym), P5974 (antonym), P5975 (troponym), P6593 (hyperonym), P8471 (pertainym), P12410 (semantic derivation). Record `(src_lid, src_sid, dst_lid, dst_sid, property)`.

**Output files:**

| File | Format | Content |
|---|---|---|
| `from_lemmas.tsv` | TSV | `lang\tlemma\tlid` |
| `from_forms.tsv` | TSV | `lang\tform_value\tlid` |
| `l2l.tsv` | TSV | `src_lid\tdst_lid\tproperty` |
| `l2q.tsv` | TSV | `lid\tqid\tproperty` |
| `s2q.tsv` | TSV | `lid\tsense_id\tqid\tproperty` |
| `s2s.tsv` | TSV | `lid\tsense_id\tdst_lid\tdst_sense_id\tproperty` |

**Post-processing:** Each file is sorted and deduped (e.g., `sort from_forms.tsv | uniq > from_forms_uniq.tsv`).

### 2.4 Wikipedia link extraction (`wp_preproc`)

**Input:** A single Wikipedia language XML dump, streamed via stdin. The language code is passed as a command-line argument.

**Processing:**

1. **Streaming XML parse** using an event-driven parser with start/end events. The MediaWiki export namespace is `http://www.mediawiki.org/xml/export-0.11/`.
2. For each `<page>` element:
   - Determine if it is an **article** (namespace 0) or **category** (namespace 14).
   - If it is a **redirect**, write `title\tredirect_target` to the redirects file and skip further processing.
   - Otherwise, extract the page's wikitext from `<revision><text>`.
   - Extract all wikilinks via regex: `\[\[([^\[\]]*)\]\]`. For each match, strip brackets; if a pipe `|` is present, take only the part before the pipe (the link target, not the display text). Links with namespace prefixes (e.g., `Category:`, `File:`, `Wikipedia:`) are excluded at this stage. Links containing nested brackets (template syntax) are skipped.
   - Write each link as `source_title\tlink_target`.
3. **Memory management:** Release each parsed page element after processing to prevent unbounded memory growth during streaming parse.

**Output files (per language):**

| File | Content |
|---|---|
| `{lang}_wikilinks.txt` | TSV: `source_article_title\tlink_target_title` |
| `{lang}_redirects.txt` | TSV: `redirect_title\ttarget_title` |

### 2.5 Wikipedia link conversion (`wp_convert`)

This is the core step that bridges the Wikipedia and Wikidata worlds.

**Input:** Reads `wd_labels.tsv` (from stage 2.2) to build a lookup dictionary: `qid_dict[lang][article_title] -> QID`. Also reads `commons_files.txt` (from stage 2.1).

**Memory management:** The full `wd_labels.tsv` dictionary for all discovered languages can exceed available RAM on smaller machines. The loader should:
1. Attempt to load the full dictionary into memory.
2. If memory is insufficient (detected via allocation failure or exceeding a configurable memory ceiling, default 80% of available RAM), fall back to a two-tier strategy:
   - **Tier 1 (in-memory):** Load only the languages currently being processed plus the `best` labels.
   - **Tier 2 (on-disk):** Use a memory-mapped key-value store (e.g., SQLite, LMDB, or dbm) for remaining languages, populated during a one-time indexing pass over `wd_labels.tsv`.
3. Log which strategy was used and the approximate memory footprint at startup.

**Processing per language:**

For each Wikipedia language in `run/languages.json`, open `{lang}_wikilinks.txt` and `{lang}_redirects.txt`, then attempt to convert each `(source_title, link_target)` pair into `(source_QID, target_QID)`:

1. **Source lookup:** Look up `source_title` in `qid_dict[lang]`. If not found, write to `{lang}_src_not_found.txt` and skip.
2. **Target resolution** -- try these strategies in order, stopping at the first success:
   a. Direct lookup: `link_target` in `qid_dict[lang]`.
   b. Capitalized first letter: `capfirst(link_target)` in `qid_dict[lang]`.
   c. Redirect resolution: `link_target` (or `capfirst`) found in redirects dict; follow the redirect chain iteratively (up to a configurable max depth, default 5) until a non-redirect title is found or the limit is reached. If the final resolved title is found in `qid_dict[lang]`, use it. Chains exceeding the depth limit or containing cycles are logged to `{lang}_redirect_chain_exceeded.txt`.
   d. Whitespace normalization: replace `&nbsp;` with space, or `_` with space.
   e. Commons detection: if the target has a prefix and the unprefixed part (with or without `File:`) is in `commons_files`, write to `{lang}_commons.txt` instead.
   f. Cross-language QID link: if the target has a language prefix (e.g., `de:Berlin`) and the suffix is a direct QID (e.g., `d:Q42`), use it directly.
   g. Cross-language title lookup: if the target has a language prefix and the suffix exists in `qid_dict[that_language]`, resolve it.
   h. Best-label fallback: look up in `qid_dict['best']`. Write to `{lang}_best_guesses.txt`.
   i. Wiktionary link: if prefix is `Wikt`, count it separately (no output).
   j. Failure: write to `{lang}_conv_failed.txt` as `src_qid\tlink_target\toriginal_link`.

**Title normalization (`capfirst`):** Capitalizes only the first character of the title (or the first character after a known language-code prefix), leaving all other characters unchanged.

**QID detection (`is_qid`):** A string is a QID if it starts with `Q` (case-insensitive) followed by digits.

**Output files (per language):**

| File | Format | Content |
|---|---|---|
| `{lang}_links_converted.txt` | TSV | `src_qid\tdst_qid` |
| `{lang}_conv_failed.txt` | TSV | `src_qid\tlink_target\toriginal_link` |
| `{lang}_commons.txt` | TSV | `src_qid\tcommons_filename` |
| `{lang}_best_guesses.txt` | TSV | `src_qid\tdst_qid` |
| `{lang}_src_not_found.txt` | Plain text | One title per line |

### 2.6 Post-conversion aggregation

Per language:
```
sort {lang}_links_converted.txt | uniq > {lang}_links_converted_uniq.txt
sort {lang}_conv_failed.txt | uniq > {lang}_conv_failed_uniq.txt
sort {lang}_commons.txt | uniq > {lang}_commons_uniq.txt
sort {lang}_best_guesses.txt | uniq > {lang}_best_guesses_uniq.txt
cut -f2 {lang}_conv_failed_uniq.txt | sort | uniq > {lang}_dsts_failed_uniq.txt
```

Cross-language combination (counting how many languages share each link):
```
sort *_links_converted_uniq.txt | uniq -c | sort -rn > links_converted_uniq_combined.txt
sort *_conv_failed_uniq.txt | uniq -c | sort -rn > conv_failed_uniq_combined.txt
sort *_commons_uniq.txt | uniq -c | sort -rn > commons_uniq_combined.txt
sort *_best_guesses_uniq.txt | uniq -c | sort -rn > best_guesses_uniq_combined.txt
sort *_dsts_failed_uniq.txt | uniq -c | sort -rn > dsts_failed_uniq_combined.txt
```

The `uniq -c` count becomes the **wp_count** -- the number of Wikipedia language editions that independently link two concepts. This is the core metric of ALGAE.

### 2.7 Format conversion (`convert2sv`)

Converts the `uniq -c` output into CSV suitable for PostgreSQL `\copy`. For 3-column input (format: `count\tsrc\tdst` from `uniq -c`), outputs `src,dst,count` — note the column reorder to match the `(src, dst, wp_count)` table schema. For 2-column input (no count), outputs `src,dst` unchanged. The column mapping is validated against the target table schema at the top of the script.

**Input:** A `.txt` file passed as command-line argument.

**Output:** Same filename with `.csv` extension.

### 2.8 Wiktionary link extraction and aggregation (`wiktionary/`)

#### 2.8.1 Link extraction (`wkt_preproc`)

Nearly identical to `wp_preproc`. Parses Wiktionary XML dumps, extracts wikilinks and redirects. Same streaming XML approach, same regex for wikilink extraction. One difference: link source and target are stripped of leading/trailing whitespace before writing.

**Output:** `{lang}_wikilinks.txt`, `{lang}_redirects.txt` (same format as Wikipedia).

#### 2.8.2 Aggregation

Per language: `sort {lang}_wikilinks.txt | uniq > {lang}_links_uniq.txt`

Cross-language: `sort *_links_uniq.txt | uniq -c > links_uniq_combined.txt`, then sorted by count descending.

#### 2.8.3 Conversion (`convert_wkt2sv`)

Converts the combined Wiktionary link file into TSV and a word list. Filters out lines containing colons (namespace prefixes), double quotes, or lines longer than 384 characters.

**Output:**
- `links_uniq_combined.tsv` -- `src\tdst\tcount`
- `entries.tsv` -- unique set of all node values (words/titles) appearing in links
- `wkt_links_rejected.txt` -- lines that failed the filter
- `wkt_links_bad.txt` -- lines that caused exceptions

#### 2.8.4 Database loading (`db_load_code`)

Loads `entries_uniq.tsv` into the `wkt_entries` table and `links_uniq_combined.tsv` into the `wkt_links` table via PostgreSQL `\copy`, consistent with all other table loading.

### 2.9 DBpedia link conversion (`dbpedia/dbp_convert`)

**Input:** DBpedia Turtle (.ttl) mapping files per language, plus `wd_labels.tsv` from the main pipeline.

**Processing:** For each language's `mappingbased-objects_lang={lang}.ttl`:
1. Parse each line into subject, predicate, object (space-separated, 4 fields including trailing `.`).
2. Extract the resource name from the URI (last path segment), replace underscores with spaces.
3. Look up both source and destination in `qid_dict[lang]`.
4. If both resolve, write `src_qid\tdst_qid\tpredicate_uri`.

**Output:** `dbp_mappings_{lang}.tsv` per language, then combined into `dbp_mappings_combined.txt` (with `uniq -c` counts) and `combined_mappings.tsv`.

---

## 3. Constants and Configuration (`wd_constants`)

### 3.1 Relationship properties (`cg_rels`)

A dictionary of ~70 Wikidata properties considered "causal graph" relationships. These are directional relationships representing influence, creation, succession, participation, and similar concepts. Key categories:

- **Influence/derivation:** P737 (influenced by), P941 (inspired by), P144 (based on), P5191 (derived from)
- **Causation:** P828 (has cause), P1542 (cause of), P1478/P1536 (immediate cause), P1479/P1537 (contributing factor)
- **Kinship:** P22 (father), P25 (mother), P40 (child), P3448 (stepparent)
- **Mentorship:** P184 (doctoral advisor), P185 (doctoral student), P1066 (student of), P802 (student)
- **Creation:** P112 (founded by), P170 (creator), P50 (author), P61 (discoverer/inventor), P86 (composer), P178 (developer), P287 (designed by)
- **Succession:** P155/P156 (follows/followed by), P1365/P1366 (replaces/replaced by), P167 (structure replaced by)
- **Film/media production:** P57 (director), P58 (screenwriter), P161 (cast member), P162 (producer), P272 (production company), P344 (director of photography), P1040 (film editor), P1431 (executive producer), P2515 (costume designer), P2554 (production designer), P3092 (film crew member), P6338 (colorist)
- **Other:** P138 (named after), P800 (notable work), P710/P1344 (participant/participant of), P279 (subclass of), P175 (performer), P176 (manufacturer)

### 3.2 Time properties

- **`starts`** (12 properties): P580 (start time), P571 (inception), P569 (date of birth), P575 (time of discovery), P577 (publication date), etc.
- **`ends`** (9 properties): P582 (end time), P576 (dissolved/abolished), P570 (date of death), P2669 (discontinued date), etc.
- **`others`**: P585 (point in time), P1317 (floruit).
- **`all_times`** (~80 properties): Comprehensive set of all date/time properties in Wikidata.
- **`times_plus_nested`**: Union of starts, ends, others, and `nested_time_rels` -- properties that may carry date qualifiers (P348 software version, P106 occupation, P108 employer, P69 educated at, P26 spouse, P449 original network, P793 significant event, P1891 signatory).

### 3.3 Inverse relationships

Two maps are defined:

- **`original_inverses`**: Pairs that Wikidata already defines as inverses (e.g., P22 father <-> P40 child).
- **`combined_inverses`**: Extended map that includes synthetic inverses (suffixed with `i`, e.g., P50 "author" <-> P50i "authored") for properties where Wikidata has no official inverse.

### 3.4 Other constants

- **`likely_nonspecific`**: Properties (P828, P1542, P1478, P1536, P1479, P1537) where a dateless statement is probably a generic/non-specific causal claim rather than a concrete historical event.
- **`lang_order`**: Short fallback chain for human-readable labels: `(en, de, fr, es, it, pl, pt, nl, sv, no, fi, ro)`.

---

## 4. Database Schema

PostgreSQL. Tables are created via `db_commands.sql` and populated with `\copy` from the pipeline output files.

### 4.1 Wikidata tables

```sql
-- All entity-to-entity relationships from Wikidata
CREATE TABLE wd_links (
    src VARCHAR(11),    -- source QID (e.g., 'Q42')
    dst VARCHAR(11),    -- destination QID
    prop VARCHAR(7),    -- property ID (e.g., 'P31')
    PRIMARY KEY (src, dst, prop)
);
-- Loaded from: links_uniq.csv (CSV)

-- Date claims per entity
CREATE TABLE wd_dates (
    qid VARCHAR(11),            -- entity QID
    property VARCHAR(7),        -- date property (e.g., P569 = date of birth)
    time_value VARCHAR(32),     -- ISO 8601 time string from Wikidata
    precision SMALLINT,         -- Wikidata time precision (0=billion years .. 14=seconds)
    source_property VARCHAR(7), -- if nested: the parent claim's property (e.g., P108); NULL if top-level
    source_target VARCHAR(11),  -- if nested: the parent claim's target QID; NULL if top-level
    PRIMARY KEY (qid, property, time_value, COALESCE(source_property, ''), COALESCE(source_target, ''))
);
-- Loaded from: date_claims.csv (CSV)
-- Top-level date claims have source_property and source_target as NULL.
-- Nested date qualifiers (e.g., P580 "start time" as a qualifier on P108 "employer" -> Q1234)
-- store the parent property and target to preserve context.

-- Entity list with labels and Wikipedia coverage
CREATE TABLE wd_entities (
    qid VARCHAR(11),
    best_label VARCHAR,
    wp_count INT,
    PRIMARY KEY (qid)
);
-- Loaded from: items.csv (CSV) via \copy
```

### 4.2 Wikipedia link table

```sql
-- Cross-language Wikipedia link consensus
CREATE TABLE wp_links (
    src VARCHAR(11),    -- source QID
    dst VARCHAR(11),    -- destination QID
    wp_count INT,       -- number of Wikipedia languages with this link
    PRIMARY KEY (src, dst)
);
-- Loaded from: links_converted_uniq_combined.csv (CSV)
```

This is the core ALGAE table. A row `(Q42, Q1, 150)` means that 150 Wikipedia language editions have a link from the article about Q42 (Douglas Adams) to the article about Q1 (Universe).

### 4.3 Lexeme tables

```sql
-- Lemma-to-lexeme mapping
CREATE TABLE lemma_lexeme (
    lang VARCHAR,
    lemma VARCHAR,
    lid VARCHAR,
    PRIMARY KEY (lang, lemma)
);
-- Loaded from: from_lemmas.tsv (TSV)

-- Form-to-lexeme mapping
CREATE TABLE form_lexeme (
    lang VARCHAR,
    lemma VARCHAR,
    lid VARCHAR,
    PRIMARY KEY (lang, lemma, lid)
);
-- Loaded from: from_forms_uniq.tsv (TSV)

-- Lexeme-to-lexeme relationships
CREATE TABLE lexeme_lexeme (
    src VARCHAR,
    dst VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src, dst, prop)
);
-- Loaded from: l2l_uniq.tsv (TSV)

-- Sense-to-item relationships
CREATE TABLE sense_item (
    src_lid VARCHAR,
    src_sid VARCHAR,
    dst VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src_lid, src_sid, dst, prop)
);
-- Loaded from: s2q_uniq.tsv (TSV)

-- Sense-to-sense relationships
CREATE TABLE sense_sense (
    src_lid VARCHAR,
    src_sid VARCHAR,
    dst_lid VARCHAR,
    dst_sid VARCHAR,
    prop VARCHAR,
    PRIMARY KEY (src_lid, src_sid, dst_lid, dst_sid, prop)
);
-- Loaded from: s2s_uniq.tsv (TSV)
```

### 4.4 Wiktionary tables

```sql
-- Wiktionary entry words
CREATE TABLE wkt_entries (
    entry VARCHAR,
    PRIMARY KEY (entry)
);
-- Loaded from: entries_uniq.tsv (TSV) via \copy

-- Wiktionary cross-language links
CREATE TABLE wkt_links (
    src VARCHAR,
    dst VARCHAR,
    wkt_count INT,
    PRIMARY KEY (src, dst)
);
-- Loaded from: links_uniq_combined.tsv (TSV) via \copy
```

---

## 5. Queries

### 5.1 WP-not-WD query (`queries/wp_not_wd.sql`)

The signature ALGAE query: find pairs of entities that are heavily linked across Wikipedias but have no corresponding Wikidata statement.

```sql
SELECT * FROM wp_links
WHERE wp_count > 100
AND NOT EXISTS (
    SELECT 1 FROM wd_links
    WHERE (wd_links.src = wp_links.src AND wd_links.dst = wp_links.dst)
       OR (wd_links.src = wp_links.dst AND wd_links.dst = wp_links.src)
)
ORDER BY wp_count DESC
LIMIT 1000;
```

The bidirectional check ensures that a Wikidata statement linking B→A is not flagged as missing when Wikipedia links A→B. This avoids false positives caused by directional inverses (e.g., P22 "father" vs. P40 "child").

### 5.2 Common item type query (`queries/common_item_type_query.sql`)

Joins a set of common link items against a P31 (instance of) table to determine the types of frequently-linked entities.

---

## 6. Microscope (`microscope`)

An interactive exploration tool for examining the neighborhood of a Wikidata entity in the ALGAE graph.

### 6.1 `get_neighbors(qid) -> (items, wp_links, wd_links)`

Queries both `wp_links` and `wd_links` for all rows where the given QID appears as either source or destination. Returns:
- `items`: the union of all QIDs appearing in any returned link.
- `wp_links`: list of `(src, dst, wp_count)` tuples, ordered by wp_count descending.
- `wd_links`: list of `(src, dst, prop)` tuples.

### 6.2 `get_entities(query_ids) -> dict`

Fetches full entity JSON from the Wikidata API (`wbgetentities`) for a set of QIDs (pipe-separated). Returns the `entities` dict from the API response. Uses a custom User-Agent header.

### 6.3 `get_article_wikitext(lang, title) -> str`

Fetches the raw wikitext of a Wikipedia article via `https://{lang}.wikipedia.org/w/index.php?title={title}&action=raw`.

### 6.4 Default behavior

When run standalone with a QID argument (default: Q42), it:
1. Gets neighbors from the database.
2. Fetches entity JSON from the Wikidata API.
3. For each entity's sitelinks, fetches the article wikitext.

---

## 7. Featured content retrieval (`get_featured`)

Fetches the day's featured content from the Wikimedia REST API (`api.wikimedia.org/feed/v1/wikipedia/{lang}/featured/{date}`). Currently only fetches English. Intended future use: compare featured/news items across languages, connect to Wikidata, and visualize relationships.

---

## 8. Pipeline Orchestration (`Makefile`)

The pipeline is orchestrated by a top-level `Makefile`. Make's dependency graph naturally encodes the data flow: each target declares its prerequisites, and Make rebuilds only what is out of date based on file timestamps. This replaces the need for manual checkpointing or sentinel files.

### 8.1 Target structure

The `Makefile` defines the following primary targets and their dependency chains:

```makefile
# Top-level targets
all: wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

# Language discovery (prerequisite for all per-language work)
run/languages.json:
	discover_languages > $@

# Commons preprocessing
run/commons_files.txt: data/commonswiki-latest-*.bz2
	bzcat $< | commons_preproc > $@

# Wikidata entity preprocessing
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv: data/latest-all.json.gz
	zcat $< | wd_preproc    # produces all four outputs

run/links_uniq.csv: run/links.csv
	sort $< | uniq > $@

# Per-language Wikipedia extraction (one target per language)
# Generated dynamically from run/languages.json
run/%_wikilinks.txt run/%_redirects.txt: data/%wiki-latest-*.xml.bz2
	bzcat $< | wp_preproc $*

# Wikipedia link conversion (depends on all per-language extractions + labels)
run/%_links_converted.txt: run/%_wikilinks.txt run/%_redirects.txt run/wd_labels.tsv run/commons_files.txt
	wp_convert $*

# Per-language sort/dedup and CSV conversion
run/%_links_converted_uniq.txt: run/%_links_converted.txt
	sort $< | uniq > $@

run/%_links_converted.csv: run/%_links_converted_uniq.txt
	convert2sv $<

# Cross-language combination
run/links_converted_uniq_combined.txt: $(ALL_LANG_CONVERTED_UNIQ)
	sort $^ | uniq -c | sort -rn > $@

run/links_converted_uniq_combined.csv: run/links_converted_uniq_combined.txt
	convert2sv $<

# Wiktionary targets (per-language extraction, combination, conversion)
run/wkt/%_wikilinks.txt: data/%wiktionary-latest-*.xml.bz2
	bzcat $< | wkt_preproc $*

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv: $(ALL_WKT_LINKS)
	sort $^ | uniq -c | sort -rn | convert_wkt2sv

# DBpedia targets (per-language conversion, combination)
run/dbp/dbp_mappings_%.tsv: data/dbpedia/mappingbased-objects_lang=%.ttl.bz2 run/wd_labels.tsv
	bzcat $< | dbp_convert $*

run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	sort $^ | uniq -c | sort -rn > $@

# Database loading targets
wp_links_loaded: run/links_converted_uniq_combined.csv
	psql -c "\copy wp_links FROM '$<' CSV" && touch $@

wd_links_loaded: run/links_uniq.csv
	psql -c "\copy wd_links FROM '$<' CSV" && touch $@
# (similar for wkt_loaded, dbp_loaded, wd_entities, wd_dates)
```

Note: The above is a simplified illustration of the target structure. The actual `Makefile` uses `$(eval)` and `$(foreach)` to dynamically generate per-language targets from the language lists in `run/languages.json`. A helper script (`make_lang_targets.sh`) is invoked via `$(shell ...)` to read the JSON and emit the per-language target lists (`ALL_LANG_CONVERTED_UNIQ`, `ALL_WKT_LINKS`, `ALL_DBP_MAPPINGS`).

### 8.2 Parallelism

Per-language targets are independent of each other, so `make -jN` parallelizes them automatically. The recommended invocation is:

```
make -j$(nproc) all
```

For I/O-bound workloads (large decompression and sort steps), a lower parallelism level may be appropriate. The Makefile provides a convenience variable:

```
make JOBS=8 all    # equivalent to make -j8 all
```

### 8.3 Incremental rebuilds and resumption

Make's timestamp-based dependency tracking provides checkpointing for free:

- If the pipeline is interrupted, re-running `make` rebuilds only targets whose prerequisites are newer than their outputs (or whose outputs don't exist).
- If a source dump is updated, only the downstream targets that depend on it are rebuilt.
- Individual languages can be rebuilt with `make run/de_links_converted.csv`.

To force a full rebuild: `make clean all`.

### 8.4 Test runs

For testing, place a `languages_override.json` in the pipeline root (see section 1.1.2). The Makefile reads this file when generating per-language targets, restricting processing to the specified subset.

### 8.5 Wiktionary and DBpedia sub-pipelines

The Wiktionary and DBpedia pipelines are integrated into the same `Makefile` as separate target trees (prefixed `run/wkt/` and `run/dbp/` respectively), sharing the same dependency and parallelism infrastructure. They can be built independently with `make wkt_loaded` or `make dbp_loaded`.

---

## 9. Data Flow Diagram

```
                    Wikidata JSON dump
                           |
                      wd_preproc
                           |
              +------------+-------------+
              |            |             |
         items.csv    links.csv    wd_labels.tsv    date_claims.csv
              |            |             |
              |       sort | uniq        |
              |            |             |
              |     links_uniq.csv       |
              |            |             +---------------------------+
              |            |             |                           |
              |         \copy         Used by                    Used by
              |            |        wp_convert             dbp_convert
              |            v             |                           |
              |       [wd_links]         |                           |
              |                          |                           |
   Wikipedia XML dumps (per lang)           |         DBpedia .ttl (per lang)
          |                              |                   |
     wp_preproc (per lang)            |            dbp_convert
          |                              |                   |
   {lang}_wikilinks.txt                  |         dbp_mappings_{lang}.tsv
   {lang}_redirects.txt                  |
          |                              |
          +------> wp_convert <-------+
                        |
         +--------------+--------------+
         |              |              |
  {lang}_links     {lang}_conv    {lang}_commons
  _converted.txt   _failed.txt        .txt
         |
    sort | uniq (per lang)
         |
    uniq -c (cross-lang)
         |
  links_converted_uniq_combined.txt
         |
    convert2sv
         |
  links_converted_uniq_combined.csv
         |
      \copy
         |
      [wp_links]


   Commons index                Wiktionary XML dumps (x170)
        |                              |
   commons_preproc            wkt_preproc (per lang)
        |                              |
   commons_files.txt             {lang}_wikilinks.txt
   (used by wp_convert)             |
                                  sort | uniq -c
                                       |
                                 convert_wkt2sv
                                       |
                                  entries.tsv + links.tsv
                                       |
                                 db_load_code
                                       |
                                  [wkt_entries]


   Wikidata lexeme dump
          |
     lex_preproc
          |
   +------+------+------+------+
   |      |      |      |      |
  from   from   l2l   s2q    s2s
  lemmas forms  .tsv  .tsv   .tsv
  .tsv   .tsv    |      |      |
   |      |   sort|uniq  |      |
   |      |      |      |      |
   v      v      v      v      v
  [lemma [form  [lex   [sense [sense
  _lex]  _lex]  _lex]  _item] _sense]
```

---

## 10. Key Design Decisions and Constraints

1. **Streaming processing.** All dump processors read from stdin and write to files, never loading an entire dump into memory. Wikipedia XML parsing uses an event-driven streaming parser with per-page memory release. Wikidata JSON parsing processes one line at a time.

2. **Title-based linking.** The Wikipedia-to-Wikidata bridge relies on exact title matching via `wd_labels.tsv`. This means conversion quality depends on the completeness of Wikidata sitelinks and on title normalization handling (capitalization, redirects, whitespace, `&nbsp;`, underscores).

3. **wp_count as a signal.** The number of Wikipedia languages independently linking two concepts is treated as a measure of relationship strength. This is used both for discovery (WP-not-WD query) and for anomaly detection (flagging removal of high-wp_count statements).

4. **Sort/uniq deduplication.** Rather than deduplicating in memory, the pipeline relies on Unix `sort | uniq` for deduplication and `uniq -c` for counting. This keeps memory usage low but requires disk space for intermediate sorted files.

5. **All languages.** The pipeline automatically discovers and processes every available Wikipedia, Wiktionary, and DBpedia language edition via the language discovery step (section 1.1). This maximizes the wp_count signal -- small Wikipedias still contribute independent evidence of a relationship. An override mechanism allows restricting to a subset for testing or when a dump is known-broken.

6. **PostgreSQL with \copy.** The database is loaded via `\copy` from flat files rather than through an ORM or programmatic inserts. This is fast for bulk loading but means the pipeline produces files in specific formats that match the table schemas.

7. **QID size limits.** `VARCHAR(11)` for all QID columns, `VARCHAR(7)` for property IDs. Current Wikidata QIDs go up to ~Q130M (8 chars); property IDs up to ~P12410 (6 chars). These limits should be monitored as Wikidata grows.

8. **Redirect resolution depth.** Redirects are resolved iteratively up to a configurable maximum depth (default: 5). The resolver follows redirect chains (A -> B -> C) until it reaches a non-redirect page or hits the depth limit. Chains that exceed the depth limit are logged to `{lang}_redirect_chain_exceeded.txt` for diagnostic purposes. Circular redirect chains are detected and broken.

---

## 11. External Dependencies

| Dependency | Used by | Purpose |
|---|---|---|
| XML streaming parser library | `wp_preproc`, `wkt_preproc` | Streaming XML parsing |
| PostgreSQL client library | `microscope`, `db_load_code` | PostgreSQL access |
| HTTP client library | `get_featured`, `discover_languages` | HTTP requests |
| PostgreSQL | Database | Storage and querying |
| `sort`, `uniq`, `cut` (coreutils) | Makefile recipes | Deduplication and counting |
| `bzcat`, `zcat` | Makefile recipes | Decompression of dump files |
| `wget` | Makefile recipes | Downloading dump files |
| `make` (GNU Make) | Pipeline orchestration | Dependency tracking, parallelism, incremental rebuilds |
