# ALGAE Farmer

ALGAE (Aggregated Link Graph Available to Everyone) builds a unified, weighted link graph across Wikimedia projects and loads it into PostgreSQL for querying and analysis. Its core insight is that cross-language Wikipedia link consensus is a strong signal for which relationships should exist in Wikidata's structured data.

This pipeline processes Wikidata, Wikipedia, Wiktionary, Commons, and DBpedia dumps to produce a set of tables that enable queries like "which entity pairs are linked by 100+ Wikipedia languages but have no Wikidata statement?"

The code in this repository was largely created by Anthropic Claude Opus 4.6 from SPEC.md, which in turn was distilled by Opus 4.6 from an older Python codebase of mine. Many iterations of improvement and debugging with Opus 4.6-4.7 have followed.

## Getting Started

### 1. Set up the database

```
createdb algae
make db_setup
```

### 2. Download source data

Download all dump files (uses `run/languages.json` for the language list):

```
make download
```

Or download selectively:

```
make download-wikidata     # Wikidata entity + lexeme dumps
make download-commons      # Commons file-title list
make download-wikipedia    # Per-language Wikipedia content exports
make download-wiktionary   # Per-language Wiktionary content exports
make download-dbpedia      # DBpedia mapping files
```

Wiki content comes from the [MediaWiki Content File
Exports](https://wikitech.wikimedia.org/wiki/MediaWiki_Content_File_Exports),
which replaced the old `pages-articles-multistream` XML dumps. Each wiki is
exported monthly as a set of bz2-compressed XML shards; the downloader picks the
newest completed export (the one with a `SHA256SUMS`), verifies every shard, and
records the shard list in `data/content/<wiki>.manifest`. Older exports of the
same wiki are deleted once a newer one is in place — set `PRUNE_OLD_EXPORTS=0`
to keep them. Note that these exports include all namespaces, so they are
roughly twice the size of the dumps they replace (English Wikipedia is ~45 GB).

Missing data files are also downloaded on demand when `make` needs them. If you already have dump files elsewhere, you can symlink them:

```
ln -s /path/to/your/existing/data data
```

### 3. Run the pipeline

```
make all
```

This automatically builds the Rust binaries, discovers languages, and runs all processing steps sequentially. Each step uses internal parallelism (parallel sorts, multithreaded preprocessors, etc.) to saturate available cores.

Optionally, create a `languages_override.json` in the project root to restrict processing to a subset:

```json
{
  "wikipedia": ["en", "simple"],
  "wiktionary": ["en"],
  "dbpedia": ["en"]
}
```

If interrupted, re-running `make all` will pick up where it left off.
