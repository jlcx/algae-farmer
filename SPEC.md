# ALGAE Specification

**ALGAE** (originally standing for Aggregated Link Graph Available to Everyone) builds a unified, weighted link graph across Wikimedia projects and loads it into PostgreSQL for querying and analysis. Its central insight is that cross-language Wikipedia link consensus is a strong signal for which relationships should exist in Wikidata's structured data.

This spec covers the offline data pipeline, database schema, and query patterns.

---

## 1. Data Sources

All source data comes from Wikimedia dump files and the DBpedia project.

| Source | Format | Typical size | Dump URL pattern |
|---|---|---|---|
| Wikidata entities | JSON (gzipped/bz2), one entity per line, wrapped in `[...]` | ~100 GB compressed | `dumps.wikimedia.org/other/wikibase/wikidatawiki/latest-all.json.gz` |
| Wikidata lexemes | Same JSON format as entities | Much smaller | `dumps.wikimedia.org/other/wikibase/wikidatawiki/latest-lexemes.json.bz2` |
| Wikipedia (per language) | MediaWiki XML export (bz2), sharded | Varies; English ~45 GB compressed | `dumps.wikimedia.org/other/mediawiki_content_current/{lang}wiki/{date}/xml/bzip2/` |
| Wiktionary (per language) | MediaWiki XML export (bz2), sharded | Varies | `dumps.wikimedia.org/other/mediawiki_content_current/{lang}wiktionary/{date}/xml/bzip2/` |
| Wikimedia Commons | Namespace-6 title list (gz) | ~1.4 GB compressed | `dumps.wikimedia.org/other/mediatitles/{date}/commonswiki-{date}-all-titles-in-ns-6.gz` |
| DBpedia | Turtle (.ttl) files per language | Varies | `downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/{version}/mappingbased-objects_lang={lang}.ttl.bz2` |

### MediaWiki Content File Exports

Wiki content comes from the [MediaWiki Content File
Exports](https://wikitech.wikimedia.org/wiki/MediaWiki_Content_File_Exports),
which replaced the `{wiki}-latest-pages-articles-multistream.xml.bz2` dumps —
the infrastructure behind those could no longer reliably produce the larger
wikis, and it is no longer maintained.

What changed for this pipeline:

- **One wiki is a set of files, not one file.** Each export is split by page-id
  range: `{wiki}-{date}-p{first}p{last}.xml.bz2`, plus
  `p{first}r{first_rev}r{last_rev}` variants where a single page is too large.
  English Wikipedia is ~20 shards. Each shard is a self-contained MediaWiki
  XML document (schema 0.11, same shape `Special:Export` produces), so the
  shards of a wiki can simply be concatenated into one stream: the preprocessors
  read a sequence of `<mediawiki>` documents and only care about `<page>`
  elements.
- **Snapshots are dated, not "latest".** Exports are published monthly on the
  1st under `{wiki}/{YYYY-MM-DD}/xml/bzip2/`, and take days to complete for the
  big wikis. `SHA256SUMS` is written only once an export has finished, so it
  serves as both the completion marker and the integrity check. There is no
  `latest/` alias; the downloader picks the newest date that has a `SHA256SUMS`.
- **Every namespace is included.** The old `pages-articles` dumps omitted talk
  and user pages; these exports contain all of them, so the files are roughly
  twice the size for the same content. The preprocessors already filter on
  `<ns>`, so only download size and decompression time are affected.
- **No multistream index.** The Commons file list is now taken from
  `other/mediatitles`, which publishes the namespace-6 titles of each wiki daily
  — see §2.1.
- **Closed wikis are gone.** Wikis such as `aawiki` have no content export;
  language discovery (§1.1.1) reflects that automatically.

Shards are stored under `data/content/{wiki}/{date}/`. Once every shard is
downloaded and verified, `scripts/download.sh` writes the list of shard paths to
`data/content/{wiki}.manifest`; that manifest is what the Makefile depends on,
and superseded date directories are removed.

### 1.1 Language discovery and registry

Rather than maintaining hardcoded language lists in individual scripts, the pipeline uses a single auto-generated registry file (`run/languages.json`) as its canonical source of truth for which language editions to process.

#### 1.1.1 Discovery step (`discover_languages`)

Runs as the first step of the pipeline, before any processing begins. Queries Wikimedia and DBpedia dump indexes to enumerate every language edition with a current dump available:

- **Wikipedia:** Enumerates `dumps.wikimedia.org/other/mediawiki_content_current/` for all `{lang}wiki` editions that have a content export. This is the same index the downloader fetches from, so discovery cannot name a wiki that cannot be downloaded.
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

**Input:** Commons namespace-6 title list (`commonswiki-{date}-all-titles-in-ns-6.gz` from `other/mediatitles`), streamed from gz via stdin.

**Processing:** One title per line in database form -- underscores for spaces, no `File:` prefix -- behind a single `page_title` header line. The header is skipped and underscores are converted back to spaces, the form link targets take in wikitext.

**Output:** `commons_files.txt` -- one filename per line. Used later by `wp_convert` to identify links that point to Commons files rather than Wikipedia articles.

This list replaces the multistream index that used to supply it. The index covered every Commons namespace, so `[[commons:Category:...]]`-style links were also recognised; the title list is namespace 6 only, which is what "is this a Commons file?" actually asks. Bare `[[commons:Foo.jpg]]` links (no `File:` prefix) are now matched too, which the index only caught if Commons happened to have a mainspace page of that name.

### 2.2 Wikidata entity preprocessing (`wd_preproc`)

**Input:** Complete Wikidata JSON dump, streamed via stdin (one JSON object per line, with leading/trailing `[`, `]` and commas between lines).

**Processing per entity:**

1. **Parse JSON** -- strip trailing comma and newline, then parse as JSON.
2. **Extract labels** -- For each language in the label language chain (derived from the Wikipedia list in `run/languages.json`, plus `mul`, `doi`, and `best`):
   - If the entity has a sitelink for `{lang}wiki`, use that article title as the label for that language. These keys are page titles, which MediaWiki keeps unique within a wiki, so they are unambiguous -- this is the high-precision path `wp_convert` matches link targets against.
   - `mul`: Wikidata's language-neutral label (`labels.mul.value`), the canonical name that per-language labels are increasingly being consolidated into. Unlike the rows above this is a *name*, not a page title, so several entities can share one; see §2.5 for how collisions are handled.
   - If the entity has a P356 (DOI) claim, extract its value as the `doi` label.
   - `best` -- one readable label per entity, also the label column of `items.csv`. Resolved in order: the first sitelink title found scanning `LANG_ORDER` (deliberately the larger, mostly Latin-script editions); else the `mul` label; else the first Wikidata label along `LANG_ORDER`; else any Wikidata label; else the entity's QID.
     - `best` is scanned in `LANG_ORDER`, *not* in label-chain order. The chain is alphabetical by language code, which meant `best` was previously taken from whichever edition sorted earliest -- in practice `ar` and `arz` far more often than `en` (Q31's `best` was the Abkhaz "Бельгиа"). `LANG_ORDER` restores the original intent of preferring large, readable editions.
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
   c. Redirect resolution: `link_target` (or `capfirst`) found in redirects dict; follow the redirect chain iteratively (up to a configurable max depth, default 5) until a non-redirect title is found or the limit is reached. If the final resolved title is found in `qid_dict[lang]`, use it. Chains exceeding the depth limit or containing cycles are logged to `{lang}_redirect_chain_exceeded.txt` with the anomaly kind (`depth_exceeded` or `cycle`). Successful resolutions through chains of depth >= 2 are additionally recorded in the `{lang}_witness_methods.txt` side-channel (method `redirect_deep`) as a title-drift signal.
   d. Whitespace normalization: replace `&nbsp;` with space, or `_` with space.
   e. Commons detection: if the target has a prefix and the unprefixed part (with or without `File:`) is in `commons_files`, write to `{lang}_commons.txt` instead.
   f. Cross-language QID link: if the target has a language prefix (e.g., `de:Berlin`) and the suffix is a direct QID (e.g., `d:Q42`), use it directly. Recorded in the side-channel as `crosslang_qid`.
   g. Cross-language title lookup: if the target has a language prefix and the suffix exists in `qid_dict[that_language]`, resolve it. Recorded in the side-channel as `crosslang_title`.
   h. Language-neutral (`mul`) fallback: look up in `qid_dict['mul']`. Tried *ahead of* `best`, so `best` sees only what `mul` missed and the two volumes read directly as `mul`'s incremental value. Unambiguous hits go to `{lang}_mul_guesses.txt`; hits on a name claimed by more than one entity go to `{lang}_mul_ambiguous.txt`.
   i. Best-label fallback: look up in `qid_dict['best']`. Write to `{lang}_best_guesses.txt`.
   j. Wiktionary link: if prefix is `Wikt`, count it separately (no output).
   k. Failure: write to `{lang}_conv_failed.txt` as `src_qid\tlink_target\toriginal_link`.

**`mul` ambiguity.** A `mul` label is a name, so entities can collide on one ("H", "Groningen"). `load_qid_dict` keeps the first QID seen -- stable, since dump order is -- and records the colliding keys rather than letting a later duplicate silently relabel an entity. Hits on those keys are kept but segregated into `{lang}_mul_ambiguous.txt`, because which QID they resolve to is an artifact of dump order rather than evidence. The distinct/ambiguous counts are logged at startup.

**Degraded-resolution side-channel (`{lang}_witness_methods.txt`).** Successful resolutions that reached `{lang}_links_converted.txt` through a degraded strategy — `crosslang_qid` (f), `crosslang_title` (g), or a redirect chain of depth >= 2 — are also written to a side-channel file as `src_qid\tdst_qid\tmethod_id`, with method ids from the append-only `resolution_methods` table (1 = redirect_deep, 2 = crosslang_qid, 3 = crosslang_title; kept in sync with the `METHOD_*` constants in `wp_convert`). Direct, capfirst, whitespace, and depth-1 redirect resolutions are deliberately *not* recorded: they are routine MediaWiki mechanics, and recording them would amount to per-witness provenance for nearly every link. The crosslang methods matter because they produce `wp_links` witnesses whose language has no article on the destination (coverage violations, §5.7).

**Diagnostic field sanitization.** Title/target fields written to the failure-side files (`_conv_failed`, `_src_not_found`, `_redirect_chain_exceeded`) are sanitized at emit time so the files are safe for `\copy`: tab, newline, CR, and backspace (the disabled-quote byte in the load command) are replaced with spaces, and values longer than 384 characters — the obs_* tables' CHECK cap; real titles are <= 255 bytes — are dropped and counted (`len_rejected` in the per-language completion log line).

**Neither `mul` nor `best` enters the link graph.** Both are diagnostic streams, combined for inspection but never merged into `{lang}_links_converted.txt`, so they cannot become `wp_links` edges. Promoting either is a deliberate future decision, tracked in `TASK_mul_promotion.md` — which records the constraints already fixed and, importantly, why stream volume is *not* the criterion for it.

**Title normalization (`capfirst`):** Capitalizes only the first character of the title (or the first character after a known language-code prefix), leaving all other characters unchanged.

**QID detection (`is_qid`):** A string is a QID if it starts with `Q` (case-insensitive) followed by digits.

**Output files (per language):**

| File | Format | Content |
|---|---|---|
| `{lang}_links_converted.txt` | TSV | `src_qid\tdst_qid` |
| `{lang}_conv_failed.txt` | TSV | `src_qid\tlink_target\toriginal_link` |
| `{lang}_commons.txt` | TSV | `src_qid\tcommons_filename` |
| `{lang}_best_guesses.txt` | TSV | `src_qid\tdst_qid` |
| `{lang}_mul_guesses.txt` | TSV | `src_qid\tdst_qid` -- `mul` hits on a name claimed by exactly one entity |
| `{lang}_mul_ambiguous.txt` | TSV | `src_qid\tdst_qid` -- `mul` hits on a shared name; resolution is dump-order dependent |
| `{lang}_src_not_found.txt` | Plain text | One title per line |
| `{lang}_redirect_chain_exceeded.txt` | TSV | `title\tkind` -- kind is `depth_exceeded` or `cycle` |
| `{lang}_witness_methods.txt` | TSV | `src_qid\tdst_qid\tmethod_id` -- degraded successful resolutions (side-channel) |

### 2.6 Post-conversion aggregation

Per language:
```
sort {lang}_links_converted.txt | uniq > {lang}_links_converted_uniq.txt
sort {lang}_conv_failed.txt | uniq > {lang}_conv_failed_uniq.txt
sort {lang}_commons.txt | uniq > {lang}_commons_uniq.txt
sort {lang}_best_guesses.txt | uniq > {lang}_best_guesses_uniq.txt
sort {lang}_src_not_found.txt | uniq > {lang}_src_not_found_uniq.txt
sort {lang}_redirect_chain_exceeded.txt | uniq > {lang}_redirect_chain_exceeded_uniq.txt
sort {lang}_witness_methods.txt | uniq > {lang}_witness_methods_uniq.txt
cut -f2 {lang}_conv_failed_uniq.txt | sort | uniq > {lang}_dsts_failed_uniq.txt
```

Cross-language combination for the main link graph is done by `wp_aggregate`
(see below); the diagnostic streams still use `uniq -c`:
```
sort *_conv_failed_uniq.txt | uniq -c | sort -rn > conv_failed_uniq_combined.txt
sort *_commons_uniq.txt | uniq -c | sort -rn > commons_uniq_combined.txt
sort *_best_guesses_uniq.txt | uniq -c | sort -rn > best_guesses_uniq_combined.txt
sort *_dsts_failed_uniq.txt | uniq -c | sort -rn > dsts_failed_uniq_combined.txt
```

### 2.7 Cross-language aggregation with witness provenance (`wp_aggregate`)

Replaces the former `sort *_links_converted_uniq.txt | uniq -c | convert2sv`
path. A heap-based k-way merge over the per-language sorted
`{lang}_links_converted_uniq.txt` files that remembers *which* languages
witnessed each link, not just how many:

- At startup, resolves each language code to its id in the append-only
  `languages` DB table (inserting codes that don't exist yet; never updating
  or deleting existing rows), and opens each per-language file as a stream
  tagged with that id.
- Standard k-way merge on `(src, dst)`; for each distinct pair, collects the
  set of tags that produced it. Memory is O(k) — the pair universe is never
  buffered. Bitmaps/bitsets are permitted only as transient in-memory
  structures here, never serialized to disk or the database (bit positions
  would silently rot when `run/languages.json` is regenerated).
- Emits one CSV row per pair for `\copy`: `src,dst,"{5,12,88}"` (Postgres
  `int2[]` literal, ids sorted ascending).

The **wp_count** — the number of Wikipedia language editions that
independently link two concepts, the core metric of ALGAE — is now derived
in the database as `cardinality(witnesses)` (a stored generated column).

**Input:** `--run-dir` (default `run`) containing `languages.json` and the
per-language files; `--db-url` for the `languages` table.

**Output:** `run/wp_links_witnesses.csv`.

The same merge, pointed at a different per-language suffix via
`--input-suffix _best_guesses_uniq.txt`, produces
`run/obs_best_guess_witnesses.csv` for the `obs_best_guess_links` table
(§4.2.1): a best-guess edge is structurally the same object as a `wp_links`
row — a candidate edge stalk with witness provenance — just untrusted, so it
gets the same aggregation code (not a fork) and a separate table.

(`convert2sv` still exists for ad-hoc `uniq -c` output conversion but is no
longer part of the wp_links path.)

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

#### 2.8.4 Database loading

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

### 4.2 Wikipedia link tables

```sql
-- Append-only language dimension: ids are assigned once and never
-- renumbered, independent of run/languages.json regeneration. Loaders may
-- only insert codes that don't exist yet.
CREATE TABLE languages (
    id   SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code TEXT UNIQUE NOT NULL
);
-- Populated by: wp_aggregate at startup

-- Cross-language Wikipedia link consensus with witness provenance
CREATE TABLE wp_links (
    src       VARCHAR(11) NOT NULL,  -- source QID
    dst       VARCHAR(11) NOT NULL,  -- destination QID
    witnesses INT2[]      NOT NULL   -- languages.id set, sorted ascending
                          CHECK (witnesses <> '{}'),
    wp_count  INT GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);
CREATE INDEX wp_links_witnesses_gin ON wp_links USING GIN (witnesses);
-- Loaded from: wp_links_witnesses.csv (CSV, columns src, dst, witnesses)
```

This is the core ALGAE table. A row `(Q42, Q1, {5,12,88}, 3)` means the
Wikipedia language editions with ids 5, 12, and 88 in `languages` each have a
link from the article about Q42 (Douglas Adams) to the article about Q1
(Universe). `wp_count` is a stored generated column, so every query written
against the old scalar schema works unchanged. The GIN index serves
`witnesses && ...` (any-of) and `witnesses @> ...` (contains) filters.

#### 4.2.1 Conversion obstruction tables

The places where a language's local link structure fails to glue onto the
shared QID graph, loaded from `wp_convert`'s per-language diagnostic files
(the files remain the pipeline interchange format; no stage writes directly
to the database). All language references use `languages.id`, never text
codes. Failures are stored per-language (long form) because the source QID
matters; cross-language aggregation of raw title strings is only meaningful
for identical titles, so it is provided as a materialized view rather than
as the storage format.

```sql
-- Append-only method lookup, same discipline as `languages`
CREATE TABLE resolution_methods (
    id   SMALLINT PRIMARY KEY,   -- 1 redirect_deep, 2 crosslang_qid, 3 crosslang_title
    name TEXT UNIQUE NOT NULL
);

-- Edges resolved only via the 'best' label fallback: same shape as wp_links
-- (candidate edge stalk with witness provenance) but a separate table, so no
-- existing query can accidentally treat them as consensus.
CREATE TABLE obs_best_guess_links (
    src       VARCHAR(11) NOT NULL,
    dst       VARCHAR(11) NOT NULL,
    witnesses INT2[]      NOT NULL,
    n         INT GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);
-- Loaded from: obs_best_guess_witnesses.csv (wp_aggregate --input-suffix)

-- Unresolvable link targets (strategy k)
CREATE TABLE obs_conv_failures (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    src     VARCHAR(11) NOT NULL,
    target  TEXT NOT NULL CHECK (length(target) <= 384),
    PRIMARY KEY (lang_id, src, target)
);

-- Source articles with no QID mapping (unconnected pages)
CREATE TABLE obs_src_not_found (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    title   TEXT NOT NULL CHECK (length(title) <= 384),
    PRIMARY KEY (lang_id, title)
);

-- Redirect chains exceeding the depth limit, and cycles
CREATE TABLE obs_redirect_anomalies (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    title   TEXT NOT NULL,
    kind    TEXT NOT NULL CHECK (kind IN ('depth_exceeded', 'cycle')),
    PRIMARY KEY (lang_id, title)
);

-- Side-channel: degraded successful resolutions present in wp_links
CREATE TABLE wp_witness_methods (
    lang_id INT2 NOT NULL REFERENCES languages(id),
    src     VARCHAR(11) NOT NULL,
    dst     VARCHAR(11) NOT NULL,
    method  INT2 NOT NULL REFERENCES resolution_methods(id),
    PRIMARY KEY (lang_id, src, dst, method)
);

-- Cross-language failed-target aggregation (replaces
-- dsts_failed_uniq_combined.txt as the queryable artifact); refreshed by
-- the obs_failed_targets_refreshed Make target after conv_failures loads.
CREATE MATERIALIZED VIEW obs_failed_targets AS
SELECT target, count(DISTINCT lang_id) AS n_langs, count(*) AS n_pairs
FROM obs_conv_failures GROUP BY target;
```

The per-language tables are loaded by `scripts/load_obs.sh` (structural
validation in awk, `\copy` into a staging table, insert with the language's
id — inserting codes that don't exist yet, append-only — and the 384-char
length filter applied in SQL so it matches the CHECK exactly; malformed and
rejected counts are logged per language).

### 4.3 Lexeme tables

```sql
-- Lemma-to-lexeme mapping
CREATE TABLE lemma_lexeme (
    lang VARCHAR,
    lemma VARCHAR,
    lid VARCHAR,
    PRIMARY KEY (lang, lemma, lid)
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

### 5.3 Witness overlap query (`queries/witnesses_overlap.sql`)

Edges witnessed by *any* of a given language set (`witnesses && ARRAY[...]::int2[]`), for clone-family filtering. Language codes are resolved to ids via the `languages` table; the filter is served by `wp_links_witnesses_gin`.

```
psql -d algae -v langs="{eo,fi,hy}" -f queries/witnesses_overlap.sql
```

### 5.4 Language recall query (`queries/language_recall.sql`)

For a given language id, counts edges with `wp_count >= N` that it does / does not witness (`witnesses @> ARRAY[id]::int2[]`).

```
psql -d algae -v lang_id=5 -v min_count=10 -f queries/language_recall.sql
```

### 5.5 Missing targets query (`queries/missing_targets.sql`)

Top rows of `obs_failed_targets` by `n_langs`: link targets that many
languages independently failed to resolve — missing articles or missing
sitelinks. Identical-string matching means proper nouns dominate, by design.

```
psql -d algae -v limit=100 -f queries/missing_targets.sql
```

### 5.6 Promotable best guesses (`queries/promotable_best_guesses.sql`)

`obs_best_guess_links` rows with `n >= threshold`, LEFT JOINed to `wp_links`
and `wd_links` to show whether trusted evidence already exists — candidate
merged-article or missing-sitelink cases when it doesn't.

```
psql -d algae -v threshold=3 -f queries/promotable_best_guesses.sql
```

### 5.7 Coverage violations (`queries/coverage_violations.sql`)

`wp_witness_methods` rows with a crosslang method joined to `wp_links`:
witnesses counted in `wp_count` whose language has no article on the
destination. Reports the per-edge violation fraction (violating witnesses /
`wp_count`) so heavily-affected edges can be down-weighted downstream.

```
psql -d algae -v limit=100 -f queries/coverage_violations.sql
```

### 5.8 Unconnected hubs (`queries/unconnected_hubs.sql`)

`obs_src_not_found` titles that also appear as targets in
`obs_conv_failures` within the same language — pages that exist, are linked
to, but have no Wikidata item.

```
psql -d algae -v limit=100 -f queries/unconnected_hubs.sql
```

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
run/commons_files.txt: data/commonswiki-all-titles-in-ns-6.gz
	zcat $< | commons_preproc > $@

# Wikidata entity preprocessing
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv: data/latest-all.json.gz
	zcat $< | wd_preproc    # produces all four outputs

run/links_uniq.csv: run/links.csv
	sort $< | uniq > $@

# Per-language Wikipedia extraction (one target per language)
# Generated dynamically from run/languages.json. The manifest lists the export
# shards for that wiki; concatenating them yields one stream of XML documents.
run/%_wikilinks.txt run/%_redirects.txt: data/content/%wiki.manifest
	bzcat $$(cat $<) | wp_preproc $*

# Wikipedia link conversion -- single invocation processes all languages
# (loads wd_labels.tsv once, then loops over each language's wikilinks/redirects)
$(ALL_LANG_CONVERTED): $(ALL_LANG_WIKILINKS) run/wd_labels.tsv run/commons_files.txt
	wp_convert

# Per-language sort/dedup
run/%_links_converted_uniq.txt: run/%_links_converted.txt
	sort $< | uniq > $@

# Cross-language aggregation with witness provenance (k-way merge,
# language ids resolved against the append-only `languages` table)
run/wp_links_witnesses.csv: $(ALL_LANG_CONVERTED_UNIQ)
	wp_aggregate --output $@

# Obstruction records: best guesses reuse the same merge; the per-language
# tables load via scripts/load_obs.sh; the failed-target rollup is a
# materialized view refreshed after the conv_failures load
run/obs_best_guess_witnesses.csv: $(ALL_LANG_BEST_GUESSES_UNIQ)
	wp_aggregate --input-suffix _best_guesses_uniq.txt --output $@

obs_conv_failures_loaded: $(ALL_LANG_CONV_FAILED_UNIQ)
	scripts/load_obs.sh conv_failures $^ && touch $@
# (similar for obs_src_not_found, obs_redirect_anomalies, wp_witness_methods;
#  obs_loaded groups them all)

obs_failed_targets_refreshed: obs_conv_failures_loaded
	psql -c "REFRESH MATERIALIZED VIEW obs_failed_targets;" && touch $@

# Wiktionary targets (per-language extraction, combination, conversion)
run/wkt/%_wikilinks.txt: data/content/%wiktionary.manifest
	bzcat $$(cat $<) | wkt_preproc $*

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv: $(ALL_WKT_LINKS)
	sort $^ | uniq -c | sort -rn | convert_wkt2sv

# DBpedia targets (per-language conversion, combination)
run/dbp/dbp_mappings_%.tsv: data/dbpedia/mappingbased-objects_lang=%.ttl.bz2 run/wd_labels.tsv
	bzcat $< | dbp_convert $*

run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	sort $^ | uniq -c | sort -rn > $@

# Database loading targets
wp_links_loaded: run/wp_links_witnesses.csv
	psql -c "\copy wp_links (src, dst, witnesses) FROM '$<' CSV" && touch $@

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
   Wikipedia content exports (per lang)     |         DBpedia .ttl (per lang)
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
    wp_aggregate (k-way merge, cross-lang,
         |        tags from [languages])
  wp_links_witnesses.csv
         |
      \copy
         |
      [wp_links]


   Commons ns-6 titles        Wiktionary content exports (x172)
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
                                  psql \copy
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

3. **wp_count as a signal, witnesses as provenance.** The number of Wikipedia languages independently linking two concepts is treated as a measure of relationship strength. This is used both for discovery (WP-not-WD query) and for anomaly detection (flagging removal of high-wp_count statements). The `witnesses` array preserves *which* languages produced each link; `wp_count` is derived from it as a stored generated column. Witness ids are anchored to the append-only `languages` table rather than bit positions or ordinals, so regenerating `run/languages.json` (which has no ordering guarantee) can never silently corrupt stored provenance.

4. **Sort/uniq deduplication.** Rather than deduplicating in memory, the pipeline relies on Unix `sort | uniq` for per-language deduplication and `uniq -c` for counting on the diagnostic streams. The main link graph is combined by `wp_aggregate`, a k-way merge over the per-language sorted files with O(languages) memory — the same merge `sort -m | uniq -c` would do, but remembering which streams produced each pair. Disk is still required for intermediate sorted files.

5. **All languages.** The pipeline automatically discovers and processes every available Wikipedia, Wiktionary, and DBpedia language edition via the language discovery step (section 1.1). This maximizes the wp_count signal -- small Wikipedias still contribute independent evidence of a relationship. An override mechanism allows restricting to a subset for testing or when a dump is known-broken.

6. **PostgreSQL with \copy.** The database is loaded via `\copy` from flat files rather than through an ORM or programmatic inserts. This is fast for bulk loading but means the pipeline produces files in specific formats that match the table schemas.

7. **QID size limits.** `VARCHAR(11)` for all QID columns, `VARCHAR(7)` for property IDs. Current Wikidata QIDs go up to ~Q130M (8 chars); property IDs up to ~P12410 (6 chars). These limits should be monitored as Wikidata grows.

8. **Redirect resolution depth.** Redirects are resolved iteratively up to a configurable maximum depth (default: 5). The resolver follows redirect chains (A -> B -> C) until it reaches a non-redirect page or hits the depth limit. Chains that exceed the depth limit are logged to `{lang}_redirect_chain_exceeded.txt` for diagnostic purposes. Circular redirect chains are detected and broken.

---

## 11. External Dependencies

| Dependency | Used by | Purpose |
|---|---|---|
| XML streaming parser library | `wp_preproc`, `wkt_preproc` | Streaming XML parsing |
| PostgreSQL client library | `microscope`, `wp_aggregate` | PostgreSQL access |
| HTTP client library | `get_featured`, `discover_languages` | HTTP requests |
| PostgreSQL | Database | Storage and querying |
| `sort`, `uniq`, `cut` (coreutils) | Makefile recipes | Deduplication and counting |
| `bzcat`, `zcat` | Makefile recipes | Decompression of dump files |
| `wget` | Makefile recipes | Downloading dump files |
| `make` (GNU Make) | Pipeline orchestration | Dependency tracking, parallelism, incremental rebuilds |
