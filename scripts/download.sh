#!/bin/bash
# Download Wikimedia and DBpedia dump files into data/.
#
# Usage:
#   ./scripts/download.sh                 # download everything
#   ./scripts/download.sh wikipedia       # just Wikipedia dumps
#   ./scripts/download.sh wiktionary      # just Wiktionary dumps
#   ./scripts/download.sh wikidata        # Wikidata entity + lexeme dumps
#   ./scripts/download.sh commons         # Commons file-title list
#   ./scripts/download.sh abstractwiki    # Abstract Wikipedia dump
#   ./scripts/download.sh wikifunctions   # Wikifunctions dump
#   ./scripts/download.sh dbpedia         # DBpedia mapping files
#
# Wiki content comes from the MediaWiki Content File Exports:
#   https://wikitech.wikimedia.org/wiki/MediaWiki_Content_File_Exports
# These replace the retired `{wiki}-latest-pages-articles-multistream.xml.bz2`
# files. Each wiki is exported monthly (on the 1st) as a *set* of bz2-compressed
# MediaWiki XML documents split by page-id range:
#
#   other/mediawiki_content_current/{wiki}/{YYYY-MM-DD}/xml/bzip2/
#       SHA256SUMS
#       _SUCCESS
#       {wiki}-{YYYY-MM-DD}-p{first}p{last}.xml.bz2
#       ...
#
# SHA256SUMS only appears once an export has completed, so it doubles as the
# "this date is usable" marker. Shards land in
# data/content/{wiki}/{date}/ and the list of shard paths is written to
# data/content/{wiki}.manifest, which is what the Makefile depends on.
#
# Reads language lists from run/languages.json (with languages_override.json
# filtering if present). Falls back to a minimal set if the registry doesn't
# exist yet.

set -euo pipefail

LANG_FILE="run/languages.json"
OVERRIDE_FILE="languages_override.json"
DATA_DIR="${DATA_DIR:-data}"
CONTENT_DIR="$DATA_DIR/content"
DBP_VERSION="${DBP_VERSION:-2021.09.01}"

CONTENT_BASE="https://dumps.wikimedia.org/other/mediawiki_content_current"
MEDIATITLES_BASE="https://dumps.wikimedia.org/other/mediatitles"
WIKIBASE_BASE="https://dumps.wikimedia.org/other/wikibase/wikidatawiki"

# Delay between requests in seconds (respect Wikimedia rate limits)
DELAY="${DOWNLOAD_DELAY:-1}"
# Max retries on failure (including 429s)
MAX_RETRIES="${DOWNLOAD_RETRIES:-3}"
# Remove superseded export dates once a newer one has been fetched. Content
# exports are large (English Wikipedia is ~45 GB per month), so keeping every
# month around is rarely what you want. Set to 0 to keep them.
PRUNE_OLD_EXPORTS="${PRUNE_OLD_EXPORTS:-1}"

mkdir -p "$DATA_DIR" "$DATA_DIR/dbpedia" "$CONTENT_DIR"

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

# Fetch a URL to an exact path (atomically, via a .part file).
fetch_to() {
    local url="$1"
    local dest="$2"
    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        if wget --limit-rate=10m -O "$dest.part" "$url" < /dev/null; then
            mv "$dest.part" "$dest"
            sleep "$DELAY"
            return 0
        fi
        rm -f "$dest.part"
        local wait_time=$((attempt * 5))
        echo "  Retry $attempt/$MAX_RETRIES after ${wait_time}s..." >&2
        sleep "$wait_time"
        attempt=$((attempt + 1))
    done
    return 1
}

# Fetch a URL to stdout (used for directory listings).
fetch_text() {
    local url="$1"
    local attempt=1
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        if wget -q -O - "$url"; then
            return 0
        fi
        sleep $((attempt * 5))
        attempt=$((attempt + 1))
    done
    return 1
}

url_exists() {
    wget -q --spider "$1"
}

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
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

# ============================================================
# MediaWiki Content File Exports
# ============================================================

# Print the newest completed export date (YYYY-MM-DD) for a wiki.
# Exports appear on the 1st of the month but take days to finish for the big
# wikis, so the newest date directory is not necessarily usable yet.
#
# Exit 2 distinguishes "this wiki has no export at all" from a transient
# failure: the index has a directory for every wiki the exporter knows about,
# including closed ones (crwiki, klwiki) that are never exported and wikis
# created since the last export run. discover_languages keeps those out of
# run/languages.json, so hitting this here means the registry is stale.
latest_export_date() {
    local wiki="$1"
    local listing dates d
    listing=$(fetch_text "$CONTENT_BASE/$wiki/") || return 1
    dates=$(printf '%s' "$listing" \
        | grep -o 'href="[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/"' \
        | sed 's/href="//; s|/"$||' \
        | sort -r)
    [ -n "$dates" ] || return 2
    for d in $dates; do
        if url_exists "$CONTENT_BASE/$wiki/$d/xml/bzip2/SHA256SUMS"; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 2
}

# True if the manifest already describes a complete local copy of $dest.
manifest_is_current() {
    local manifest="$1"
    local dest="$2"
    local line
    [ -s "$manifest" ] || return 1
    while read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "$dest"/*) ;;
            *) return 1 ;;
        esac
        [ -f "$line" ] || return 1
    done < "$manifest"
    return 0
}

# Delete export dates for a wiki other than the one just downloaded.
prune_old_exports() {
    local wiki="$1"
    local keep="$2"
    local dir base
    [ "$PRUNE_OLD_EXPORTS" = "1" ] || return 0
    for dir in "$CONTENT_DIR/$wiki"/*/; do
        [ -d "$dir" ] || continue
        base=$(basename "$dir")
        case "$base" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
            *) continue ;;
        esac
        [ "$base" = "$keep" ] && continue
        echo "  [$wiki] removing superseded export $base"
        rm -rf "$dir"
    done
}

# Download every shard of the newest completed content export for one wiki,
# verify checksums, and write data/content/{wiki}.manifest.
download_content_export() {
    local wiki="$1"
    local date rc dest manifest base expected name

    date=$(latest_export_date "$wiki") || {
        rc=$?
        if [ "$rc" = 2 ]; then
            echo "Error: $wiki has no content export at all (closed wiki, or created" >&2
            echo "       since the last export run). Refresh the registry with" >&2
            echo "       'rm run/languages.json && make run/languages.json' to drop it." >&2
        else
            echo "Error: could not read the export index for $wiki" >&2
        fi
        return 1
    }

    dest="$CONTENT_DIR/$wiki/$date"
    manifest="$CONTENT_DIR/$wiki.manifest"

    if manifest_is_current "$manifest" "$dest"; then
        echo "  [$wiki] up to date ($date)"
        return 0
    fi

    echo "  [$wiki] export $date"
    mkdir -p "$dest"
    base="$CONTENT_BASE/$wiki/$date/xml/bzip2"
    fetch_to "$base/SHA256SUMS" "$dest/SHA256SUMS" || {
        echo "Error: failed to fetch SHA256SUMS for $wiki $date" >&2
        return 1
    }

    while read -r expected name; do
        [ -n "$name" ] || continue
        if [ -f "$dest/$name" ] && [ "$(sha256_of "$dest/$name")" = "$expected" ]; then
            continue
        fi
        echo "    $name"
        fetch_to "$base/$name" "$dest/$name" || {
            echo "Error: failed to download $name" >&2
            return 1
        }
        if [ "$(sha256_of "$dest/$name")" != "$expected" ]; then
            echo "Error: checksum mismatch for $name" >&2
            rm -f "$dest/$name"
            return 1
        fi
    done < "$dest/SHA256SUMS"

    awk -v d="$dest" 'NF >= 2 {print d "/" $2}' "$dest/SHA256SUMS" | sort > "$manifest"
    prune_old_exports "$wiki" "$date"
}

# ============================================================
# Per-source downloads
# ============================================================

download_wikidata() {
    echo "=== Downloading Wikidata entity dump ==="
    polite_wget "$WIKIBASE_BASE/latest-all.json.gz" "$DATA_DIR"

    echo "=== Downloading Wikidata lexeme dump ==="
    polite_wget "$WIKIBASE_BASE/latest-lexemes.json.bz2" "$DATA_DIR"
}

# Commons file titles. The multistream index this used to come from went away
# with the XML dumps; other/mediatitles publishes the namespace-6 title list
# daily, which is what commons_files.txt actually needs.
download_commons() {
    echo "=== Downloading Commons file titles ==="
    local listing date found=""
    listing=$(fetch_text "$MEDIATITLES_BASE/") || return 1
    for date in $(printf '%s' "$listing" \
            | grep -o 'href="[0-9]\{8\}/"' \
            | sed 's/href="//; s|/"$||' \
            | sort -r); do
        if url_exists "$MEDIATITLES_BASE/$date/commonswiki-$date-all-titles-in-ns-6.gz"; then
            found="$date"
            break
        fi
    done
    if [ -z "$found" ]; then
        echo "Error: no Commons title list found under $MEDIATITLES_BASE" >&2
        return 1
    fi

    local dest="$DATA_DIR/commonswiki-all-titles-in-ns-6.gz"
    local stamp="$dest.date"
    if [ -f "$dest" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$found" ]; then
        echo "  up to date ($found)"
        return 0
    fi
    echo "  [$found]"
    fetch_to "$MEDIATITLES_BASE/$found/commonswiki-$found-all-titles-in-ns-6.gz" "$dest" || return 1
    printf '%s\n' "$found" > "$stamp"
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
    echo "=== Downloading Wikipedia content exports for $count languages ==="
    for lang in $langs; do
        download_content_export "${lang}wiki" \
            || echo "  Warning: failed to download ${lang}wiki export" >&2
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
    echo "=== Downloading Wiktionary content exports for $count languages ==="
    for lang in $langs; do
        download_content_export "${lang}wiktionary" \
            || echo "  Warning: failed to download ${lang}wiktionary export" >&2
    done
}

download_abstractwiki() {
    echo "=== Downloading Abstract Wikipedia content export ==="
    download_content_export abstractwiki
}

download_wikifunctions() {
    echo "=== Downloading Wikifunctions content export ==="
    download_content_export wikifunctionswiki
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

# Download a single Wikipedia language export
download_wikipedia_single() {
    local lang="$1"
    echo "  [wikipedia/$lang]"
    download_content_export "${lang}wiki" \
        || { echo "Error: failed to download ${lang}wiki export" >&2; return 1; }
}

# Download a single Wiktionary language export
download_wiktionary_single() {
    local lang="$1"
    echo "  [wiktionary/$lang]"
    download_content_export "${lang}wiktionary" \
        || { echo "Error: failed to download ${lang}wiktionary export" >&2; return 1; }
}

# Main
TARGET="${1:-all}"

case "$TARGET" in
    all)
        download_wikidata
        download_commons
        download_wikipedia
        download_wiktionary
        download_abstractwiki
        download_wikifunctions
        download_dbpedia
        ;;
    wikidata)           download_wikidata ;;
    commons)            download_commons ;;
    wikipedia)          download_wikipedia ;;
    wiktionary)         download_wiktionary ;;
    abstractwiki)       download_abstractwiki ;;
    wikifunctions)      download_wikifunctions ;;
    dbpedia)            download_dbpedia ;;
    wikipedia-single)   download_wikipedia_single "${2:?language code required}" ;;
    wiktionary-single)  download_wiktionary_single "${2:?language code required}" ;;
    *)
        echo "Unknown target: $TARGET" >&2
        echo "Usage: $0 [all|wikidata|commons|wikipedia|wiktionary|abstractwiki|wikifunctions|dbpedia|wikipedia-single <lang>|wiktionary-single <lang>]" >&2
        exit 1
        ;;
esac

echo "=== Done ==="
