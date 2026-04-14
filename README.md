# ALGAE Farmer

ALGAE (Aggregated Link Graph Available to Everyone) builds a unified, weighted link graph across Wikimedia projects and loads it into PostgreSQL for querying and analysis. Its core insight is that cross-language Wikipedia link consensus is a strong signal for which relationships should exist in Wikidata's structured data.

This pipeline processes Wikidata, Wikipedia, Wiktionary, Commons, and DBpedia dumps to produce a set of tables that enable queries like "which entity pairs are linked by 100+ Wikipedia languages but have no Wikidata statement?"

The code in this repository was largely created by Anthropic Claude Opus 4.6 from SPEC.md, which in turn was distilled by Opus 4.6 from an older Python codebase of mine.

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
make download-commons      # Commons multistream index
make download-wikipedia    # Per-language Wikipedia XML dumps
make download-wiktionary   # Per-language Wiktionary XML dumps
make download-dbpedia      # DBpedia mapping files
```

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
