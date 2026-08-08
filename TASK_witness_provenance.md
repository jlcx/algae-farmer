# Task: Per-language witness provenance for wp_links

Context: ALGAE currently aggregates cross-language links via `sort | uniq -c`
(spec §2.6), collapsing the set of witnessing languages into a scalar
`wp_count`. This task replaces the scalar with the actual language set,
end to end: aggregation → load format → schema → queries.

This spec records decisions already made (with rationale where the locally
obvious alternative was deliberately rejected). Treat the decisions as
constraints, not suggestions. Ask before deviating.

## Decisions (fixed)

1. **Persistent representation: `int2[]` array of language ids**, backed by
   an append-only `languages` dimension table. NOT a bitmap/bitstring
   column.
   - Rationale: bit positions would derive their meaning from ordering in
     `run/languages.json`, which is auto-regenerated on a staleness
     threshold (spec §1.1.1) with no ordering guarantee. Any regeneration
     that shifts ordinals silently corrupts all stored bitmaps, with no
     post-hoc detectability. Arrays of ids anchored to an append-only
     table have no ordinal dependency.
   - Sparsity: most edges have 1–2 witnesses out of ~340 languages;
     arrays cost proportional to actual witnesses.
2. **`wp_count` becomes a stored generated column**
   (`GENERATED ALWAYS AS (cardinality(witnesses)) STORED`) so every
   existing query, including WP-not-WD (spec §5.1), works unchanged.
3. **GIN index on the array column** for `@>` / `&&` queries.
4. **Bitmaps allowed only as transient in-memory structures** inside the
   Rust aggregator (fixed bitset over ~340 langs is fine; roaring
   unnecessary at this universe size). Never serialized to disk or DB.
5. **The `languages` table is append-only.** Ids are assigned once and
   never renumbered, independent of `run/languages.json` regeneration.
   Loader logic: insert codes that don't exist yet; never delete or
   update existing rows.

## Schema

```sql
CREATE TABLE languages (
    id   smallint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    code text UNIQUE NOT NULL
);

CREATE TABLE wp_links (
    src       varchar(11) NOT NULL,
    dst       varchar(11) NOT NULL,
    witnesses int2[]      NOT NULL,   -- sorted ascending, no duplicates
    wp_count  int GENERATED ALWAYS AS (cardinality(witnesses)) STORED,
    PRIMARY KEY (src, dst)
);
CREATE INDEX wp_links_witnesses_gin ON wp_links USING GIN (witnesses);
```

Migration may create `wp_links` fresh (drop/recreate) since it is fully
rebuilt from pipeline files anyway; preserve any dependent views.

## Aggregation rewrite (replaces spec §2.6 cross-language step)

Replace `sort *_links_converted_uniq.txt | uniq -c` with a Rust k-way
merge over the per-language sorted `{lang}_links_converted_uniq.txt`
files (each line `src_qid\tdst_qid`, already sorted and deduped
per-language):

- Open all per-language files as tagged streams (tag = language id from
  the `languages` table, resolving codes at startup).
- Standard heap-based k-way merge on `(src, dst)`; for each distinct
  pair, collect the set of tags that produced it.
- Emit one CSV row per pair for `\copy`:
  `src,dst,"{5,12,88}"` (Postgres array literal, ids sorted ascending).
- `uniq -c` was a merge that forgot which streams it merged; this is the
  same merge, remembering. Memory stays O(k) — do not buffer the pair
  universe.

Update the Makefile target chain (§8.1) accordingly:
`links_converted_uniq_combined.*` targets are replaced by the new
aggregator output; `convert2sv` is no longer needed for this path.
Keep per-language `_links_converted_uniq.txt` generation unchanged.

## Queries

1. Verify `queries/wp_not_wd.sql` runs unmodified against the new schema.
2. Add `queries/witnesses_overlap.sql`: edges witnessed by any of a given
   language set (`witnesses && ARRAY[...]::int2[]`), for clone-family
   filtering.
3. Add `queries/language_recall.sql`: for a given language id, count
   edges with wp_count >= N that it does / does not witness
   (uses `witnesses @> ARRAY[id]::int2[]`).

## Acceptance criteria

Run with a small `languages_override.json` (e.g. `["eo","fi","hy","simple"]`).

1. **Count equivalence:** for every pair, `wp_count` equals the count the
   old `sort | uniq -c` path produces on the same inputs. Test by running
   both paths on the override subset and diffing `(src, dst, count)`.
2. **Witness correctness:** for a sample of pairs, the id set maps back
   (via `languages`) to exactly the set of per-language files containing
   the pair. Include pairs with 1 witness and with all witnesses.
3. **Array round-trip:** `\copy` load then `SELECT` returns identical
   sorted arrays; empty arrays must not occur (every row has >= 1
   witness by construction — enforce with a CHECK if cheap).
4. **Registry-regeneration safety:** delete and regenerate
   `run/languages.json` (or shuffle its order), re-run the loader; the
   `languages` table must gain no changed rows for existing codes, and
   previously loaded `wp_links` rows must be byte-identical.
5. **Index usage:** `EXPLAIN` shows the GIN index used for `&&` and `@>`
   query shapes above.
6. WP-not-WD query returns identical results before/after on the subset.

## Non-goals (explicitly out of scope for this task)

- Per-witness resolution provenance / obstruction tables (best-guess,
  conv-failed as typed records) — separate follow-up task.
- Knowledge-sheaf embeddings, property prediction, microscope changes.
- Any change to per-language extraction/conversion stages (§2.4–2.5).
