# Task: Conversion obstructions as first-class database objects

Context: wp_convert (spec §2.5) resolves per-language wikilinks into QID
pairs. Resolutions that fail or degrade are currently written to
per-language diagnostic files (`_best_guesses`, `_conv_failed`,
`_src_not_found`, `_redirect_chain_exceeded`) and never queried. This
task loads them into PostgreSQL as typed, cross-language-queryable
records, and adds a small side-channel to wp_convert so that degraded
*successful* resolutions (cross-language strategies) are recorded too.

Motivation (short version): these records are the places where a
language's local link structure fails to glue onto the shared QID
graph. Queryable, they become detectors — for missing articles and
sitelinks, merged-article (one-article-covers-two-concepts) cases, and
witnesses in wp_links whose language has no article on the target.

Depends on: TASK_witness_provenance.md (uses the `languages` dimension
table and its int2 ids). Do that task first.

## Decisions (fixed)

1. **Per-language files remain the pipeline interchange format.** Tables
   are loaded from them via `\copy`, consistent with spec decision #6.
   No stage writes directly to the database.
2. **All language references use `languages.id` (int2)**, never text
   codes, for the reasons recorded in TASK_witness_provenance.md.
3. **Best-guess links get the same shape as wp_links** (aggregated,
   witness array), because they are structurally the same object — a
   candidate edge stalk — just untrusted. They stay in a separate table
   rather than a flag column on wp_links so no existing query can
   accidentally treat them as consensus.
4. **Conversion failures are stored per-language (long form), not
   aggregated**, because the source QID matters (which entities want
   the missing target) and because cross-language aggregation of raw
   title strings is only meaningful for titles identical across
   languages — provide that as a view, not as the storage format.
5. **wp_convert gains a side-channel output for degraded successful
   resolutions**: methods crosslang_qid (strategy f), crosslang_title
   (strategy g), and redirect chains of depth >= 2. Direct, capfirst,
   whitespace, and depth-1 redirect resolutions are NOT recorded
   (routine MediaWiki mechanics; recording them would be per-witness
   provenance for nearly every link, which is out of scope on volume
   grounds).
   - crosslang methods matter because they produce wp_links witnesses
     whose language lacks an article on dst (coverage violations).
   - Deep redirect chains matter as a title-drift signal.
6. **Method enum stored as smallint** with a `resolution_methods`
   lookup table (append-only, same discipline as `languages`).

## Schema

```sql
CREATE TABLE resolution_methods (
    id   smallint PRIMARY KEY,
    name text UNIQUE NOT NULL
);
INSERT INTO resolution_methods VALUES
 (1,'redirect_deep'), (2,'crosslang_qid'), (3,'crosslang_title');

-- Strategy (h): edges resolved only via the 'best' label fallback.
CREATE TABLE obs_best_guess_links (
    src       varchar(11) NOT NULL,
    dst       varchar(11) NOT NULL,
    witnesses int2[]      NOT NULL,
    n         int GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);
CREATE INDEX obs_bgl_witnesses_gin ON obs_best_guess_links
    USING GIN (witnesses);

-- Strategy (j): unresolvable link targets.
CREATE TABLE obs_conv_failures (
    lang_id int2 NOT NULL REFERENCES languages(id),
    src     varchar(11) NOT NULL,
    target  text NOT NULL CHECK (length(target) <= 384),
    PRIMARY KEY (lang_id, src, target)
);
CREATE INDEX obs_cf_target ON obs_conv_failures (target);

-- Source articles with no QID mapping (unconnected pages).
CREATE TABLE obs_src_not_found (
    lang_id int2 NOT NULL REFERENCES languages(id),
    title   text NOT NULL CHECK (length(title) <= 384),
    PRIMARY KEY (lang_id, title)
);

-- Redirect chains exceeding depth limit, and cycles.
CREATE TABLE obs_redirect_anomalies (
    lang_id int2 NOT NULL REFERENCES languages(id),
    title   text NOT NULL,
    kind    text NOT NULL CHECK (kind IN ('depth_exceeded','cycle')),
    PRIMARY KEY (lang_id, title)
);

-- Side-channel: degraded successful resolutions present in wp_links.
CREATE TABLE wp_witness_methods (
    lang_id int2 NOT NULL REFERENCES languages(id),
    src     varchar(11) NOT NULL,
    dst     varchar(11) NOT NULL,
    method  int2 NOT NULL REFERENCES resolution_methods(id),
    PRIMARY KEY (lang_id, src, dst, method)
);

-- Cross-language failed-target aggregation (replaces
-- dsts_failed_uniq_combined.txt as the queryable artifact).
CREATE MATERIALIZED VIEW obs_failed_targets AS
SELECT target,
       count(DISTINCT lang_id) AS n_langs,
       count(*)                AS n_pairs
FROM obs_conv_failures
GROUP BY target;
CREATE INDEX obs_ft_nlangs ON obs_failed_targets (n_langs DESC);
```

## Pipeline changes

1. **wp_convert side-channel**: emit `{lang}_witness_methods.txt`
   (TSV: `src\tdst\tmethod_id`) for the methods in decision 5. No
   change to existing output files or resolution logic. Length-filter
   and tab/quote-sanitize `target`/`title` fields at emit time for the
   failure files if not already safe for `\copy`.
2. **Loaders + Makefile targets** for each table, following the
   existing `*_loaded` sentinel pattern (§8.1). obs_best_guess_links
   is produced by the same k-way merge aggregator as wp_links, run
   over `{lang}_best_guesses_uniq.txt` inputs (reuse the code; do not
   fork it).
3. `REFRESH MATERIALIZED VIEW obs_failed_targets` as a Make target
   depending on the conv_failures load.

## Queries to add

1. `queries/missing_targets.sql`: top rows of obs_failed_targets by
   n_langs — recurring unresolvable targets (missing articles /
   sitelinks; note identical-string matching means proper nouns
   dominate, by design).
2. `queries/promotable_best_guesses.sql`: obs_best_guess_links rows
   with n >= threshold, LEFT JOIN wp_links and wd_links to show
   whether trusted evidence already exists — candidate merged-article
   or missing-sitelink cases.
3. `queries/coverage_violations.sql`: wp_witness_methods rows with
   method IN (2,3) joined to wp_links — witnesses counted in wp_count
   whose language has no article on dst. Reports per-edge violation
   fraction (violating witnesses / wp_count) so heavily-affected edges
   can be down-weighted downstream.
4. `queries/unconnected_hubs.sql`: obs_src_not_found titles that also
   appear as targets in obs_conv_failures within the same language —
   pages that exist, are linked to, but have no Wikidata item.

## Acceptance criteria

Run with the same small `languages_override.json` as the previous task.

1. **Load fidelity**: row counts per (table, lang) equal line counts of
   the corresponding uniq'd files, minus rows rejected by the length
   filter (rejected rows logged with counts).
2. **Side-channel consistency**: every (lang, src, dst) in
   wp_witness_methods appears in that language's
   `_links_converted_uniq.txt`; spot-check that method labels match
   the resolution path on a hand-verified sample (>= 10 links spanning
   all three methods).
3. **Separation invariant**: no (src, dst) pair in obs_best_guess_links
   contributes to wp_links witnesses (best guesses remain excluded
   from consensus), verified by an anti-join over the subset run.
4. **Query smoke tests**: all four queries run and return plausible
   non-empty results on the subset (eo/fi/hy/simple should produce
   conv failures and best guesses in practice).
5. **Materialized view refresh** is idempotent and wired into Make.

## Non-goals

- Any change to which strategies wp_convert attempts or their order.
- Down-weighting/removing coverage-violating witnesses from wp_links
  (query 3 measures the phenomenon; acting on it is a later decision).
- Commons link records (`_commons` files) — separate concern, not an
  obstruction.
- Wiktionary/DBpedia obstruction records.
