#!/bin/bash
# Download Wikimedia and DBpedia dump files into data/.
#
# Usage:
#   ./scripts/download.sh                 # download everything
#   ./scripts/download.sh wikipedia       # just Wikipedia dumps
#   ./scripts/download.sh wiktionary      # just Wiktionary dumps
#   ./scripts/download.sh wikidata        # Wikidata entity + lexeme dumps
#   ./scripts/download.sh commons         # Commons multistream index
#   ./scripts/download.sh dbpedia         # DBpedia mapping files
#
# Reads language lists from run/languages.json (with languages_override.json
# filtering if present). Falls back to a minimal set if the registry doesn't
# exist yet.

set -euo pipefail

LANG_FILE="run/languages.json"
OVERRIDE_FILE="languages_override.json"
DATA_DIR="data"
DBP_VERSION="${DBP_VERSION:-2021.09.01}"

# Delay between requests in seconds (respect Wikimedia rate limits)
DELAY="${DOWNLOAD_DELAY:-1}"
# Max retries on failure (including 429s)
MAX_RETRIES="${DOWNLOAD_RETRIES:-3}"

mkdir -p "$DATA_DIR" "$DATA_DIR/dbpedia"

# wget wrapper with rate limiting and retry with backoff
polite_wget() {
    local url="$1"
    local dest_dir="$2"
    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        if wget --no-if-modified-since -N -P "$dest_dir" \
                --wait=1 --limit-rate=10m \
                "$url"; then
            sleep "$DELAY"
            return 0
        fi
        local wait_time=$((attempt * 5))
        echo "  Retry $attempt/$MAX_RETRIES after ${wait_time}s..." >&2
        sleep "$wait_time"
        attempt=$((attempt + 1))
    done
    return 1
}

# Read language list for a project from the registry
get_langs() {
    local project="$1"
    if [ ! -f "$LANG_FILE" ]; then
        echo "Warning: $LANG_FILE not found, run discover_languages first" >&2
        return
    fi
    python3 -c "
import json, os
with open('$LANG_FILE') as f:
    registry = json.load(f)
langs = set(registry.get('$project', []))
if os.path.exists('$OVERRIDE_FILE'):
    with open('$OVERRIDE_FILE') as f:
        overrides = json.load(f)
    override_set = set(overrides.get('$project', []))
    langs = langs & override_set
for l in sorted(langs):
    print(l)
"
}

download_wikidata() {
    echo "=== Downloading Wikidata entity dump ==="
    polite_wget \
        "https://dumps.wikimedia.org/wikidatawiki/entities/latest-all.json.gz" \
        "$DATA_DIR"

    echo "=== Downloading Wikidata lexeme dump ==="
    polite_wget \
        "https://dumps.wikimedia.org/wikidatawiki/entities/latest-lexemes.json.bz2" \
        "$DATA_DIR"
}

download_commons() {
    echo "=== Downloading Commons multistream index ==="
    polite_wget \
        "https://dumps.wikimedia.org/commonswiki/latest/commonswiki-latest-pages-articles-multistream-index.txt.bz2" \
        "$DATA_DIR"
}

download_wikipedia() {
    local langs
    langs=$(get_langs wikipedia)
    if [ -z "$langs" ]; then
        echo "No Wikipedia languages found" >&2
        return 1
    fi
    local count
    count=$(echo "$langs" | wc -l)
    echo "=== Downloading Wikipedia dumps for $count languages ==="
    for lang in $langs; do
        echo "  [$lang]"
        polite_wget \
            "https://dumps.wikimedia.org/${lang}wiki/latest/${lang}wiki-latest-pages-articles-multistream.xml.bz2" \
            "$DATA_DIR" \
            || echo "  Warning: failed to download ${lang}wiki dump" >&2
    done
}

download_wiktionary() {
    local langs
    langs=$(get_langs wiktionary)
    if [ -z "$langs" ]; then
        echo "No Wiktionary languages found" >&2
        return 1
    fi
    local count
    count=$(echo "$langs" | wc -l)
    echo "=== Downloading Wiktionary dumps for $count languages ==="
    for lang in $langs; do
        echo "  [$lang]"
        polite_wget \
            "https://dumps.wikimedia.org/${lang}wiktionary/latest/${lang}wiktionary-latest-pages-articles-multistream.xml.bz2" \
            "$DATA_DIR" \
            || echo "  Warning: failed to download ${lang}wiktionary dump" >&2
    done
}

download_dbpedia() {
    local langs
    langs=$(get_langs dbpedia)
    if [ -z "$langs" ]; then
        echo "No DBpedia languages found" >&2
        return 1
    fi
    local count
    count=$(echo "$langs" | wc -l)
    echo "=== Downloading DBpedia mappings (version $DBP_VERSION) for $count languages ==="
    for lang in $langs; do
        echo "  [$lang]"
        polite_wget \
            "https://downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/${DBP_VERSION}/mappingbased-objects_lang=${lang}.ttl.bz2" \
            "$DATA_DIR/dbpedia" \
            || echo "  Warning: failed to download DBpedia ${lang} mapping" >&2
    done
}

# Download a single Wikipedia language dump
download_wikipedia_single() {
    local lang="$1"
    echo "  [wikipedia/$lang]"
    polite_wget \
        "https://dumps.wikimedia.org/${lang}wiki/latest/${lang}wiki-latest-pages-articles-multistream.xml.bz2" \
        "$DATA_DIR" \
        || { echo "Error: failed to download ${lang}wiki dump" >&2; return 1; }
}

# Download a single Wiktionary language dump
download_wiktionary_single() {
    local lang="$1"
    echo "  [wiktionary/$lang]"
    polite_wget \
        "https://dumps.wikimedia.org/${lang}wiktionary/latest/${lang}wiktionary-latest-pages-articles-multistream.xml.bz2" \
        "$DATA_DIR" \
        || { echo "Error: failed to download ${lang}wiktionary dump" >&2; return 1; }
}

# Main
TARGET="${1:-all}"

case "$TARGET" in
    all)
        download_wikidata
        download_commons
        download_wikipedia
        download_wiktionary
        download_dbpedia
        ;;
    wikidata)           download_wikidata ;;
    commons)            download_commons ;;
    wikipedia)          download_wikipedia ;;
    wiktionary)         download_wiktionary ;;
    dbpedia)            download_dbpedia ;;
    wikipedia-single)   download_wikipedia_single "${2:?language code required}" ;;
    wiktionary-single)  download_wiktionary_single "${2:?language code required}" ;;
    *)
        echo "Unknown target: $TARGET" >&2
        echo "Usage: $0 [all|wikidata|commons|wikipedia|wiktionary|dbpedia|wikipedia-single <lang>|wiktionary-single <lang>]" >&2
        exit 1
        ;;
esac

echo "=== Done ==="
