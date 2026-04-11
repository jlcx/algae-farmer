#!/bin/bash
# Helper script for Makefile: reads languages.json and optional override,
# emits per-language target lists for Make's $(shell ...) expansion.
#
# Usage: ./make_lang_targets.sh <project> <variable_name>
# Example: ./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ
#
# Output: space-separated list of targets

set -euo pipefail

PROJECT="${1:?Usage: make_lang_targets.sh <project> <variable_name>}"
VARNAME="${2:?Usage: make_lang_targets.sh <project> <variable_name>}"

LANG_FILE="run/languages.json"
OVERRIDE_FILE="languages_override.json"

if [ ! -f "$LANG_FILE" ]; then
    echo "" >&2
    exit 0
fi

# Extract language list for the project
LANGS=$(python3 -c "
import json, sys, os

with open('$LANG_FILE') as f:
    registry = json.load(f)
langs = set(registry.get('$PROJECT', []))

if os.path.exists('$OVERRIDE_FILE'):
    with open('$OVERRIDE_FILE') as f:
        overrides = json.load(f)
    override_set = set(overrides.get('$PROJECT', []))
    langs = langs & override_set

for l in sorted(langs):
    print(l)
" 2>/dev/null || echo "")

case "$VARNAME" in
    ALL_LANG_CONVERTED_UNIQ)
        for lang in $LANGS; do
            echo -n "run/${lang}_links_converted_uniq.txt "
        done
        ;;
    ALL_WKT_LINKS)
        for lang in $LANGS; do
            echo -n "run/wkt/${lang}_wikilinks.txt "
        done
        ;;
    ALL_DBP_MAPPINGS)
        for lang in $LANGS; do
            echo -n "run/dbp/dbp_mappings_${lang}.tsv "
        done
        ;;
    *)
        echo "Unknown variable: $VARNAME" >&2
        exit 1
        ;;
esac
