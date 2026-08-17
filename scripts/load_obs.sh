#!/usr/bin/env bash
# Load wp_convert's per-language diagnostic files into the obstruction tables
# (TASK_obstruction_records.md): conversion failures, unconnected source
# pages, redirect anomalies, and the degraded-resolution side-channel.
#
# The per-language files stay the pipeline interchange format; this script is
# the only bridge to the database. Each input file is structurally validated
# (column count, QID shape) in awk, staged with \copy, then inserted with the
# language's id from the append-only `languages` table (codes not present yet
# are inserted, never updated or deleted). Rows over the obs_* length cap are
# rejected in SQL so the count matches the CHECK constraint exactly; malformed
# and rejected counts are logged per language.
#
# Follows the Makefile *_loaded pattern: drop PK/indexes, TRUNCATE, load all
# languages, rebuild. The language code is recovered from each filename by
# stripping the table's uniq-file suffix.
#
# Usage:  scripts/load_obs.sh <table> <uniq-file>...
#         <table>: conv_failures | src_not_found | redirect_anomalies | witness_methods
#         DBNAME=other scripts/load_obs.sh conv_failures run/eo_conv_failed_uniq.txt ...
set -euo pipefail

cd "$(dirname "$0")/.."

DBNAME="${DBNAME:-algae}"
TABLE="${1:?Usage: load_obs.sh <table> <uniq-file>...}"
shift
if [[ $# -eq 0 ]]; then
    echo "load_obs.sh: no input files given" >&2
    exit 1
fi

PSQL=(psql -d "$DBNAME" -v ON_ERROR_STOP=1 --no-psqlrc)

# Per-table wiring:
#   suffix    - uniq-file suffix stripped to recover the language code
#   awk_prog  - structural filter: valid rows to stdout, malformed count to stderr
#   stage_ddl - staging table (session-local, no lang_id column)
#   insert    - INSERT from stage; :lang_id and :'lang' are set by psql -v
case "$TABLE" in
    conv_failures)
        suffix="_conv_failed_uniq.txt"
        # 3 fields (src, target, original; target == original since emit),
        # keep (src, target); adjacent dedup since cutting a sorted file's
        # prefix fields can create duplicates.
        awk_prog='BEGIN { FS = OFS = "\t" }
            NF == 3 && $1 ~ /^Q[0-9]+$/ && length($1) <= 11 {
                line = $1 OFS $2
                if (line != prev) print line
                prev = line
                next
            }
            { bad++ }
            END { if (bad) printf "    %s: %d malformed rows skipped\n", lang, bad > "/dev/stderr" }'
        stage_ddl="CREATE TEMP TABLE stage (src varchar(11), target text);"
        insert="INSERT INTO obs_conv_failures (lang_id, src, target)
                SELECT :lang_id, src, target FROM stage
                WHERE length(target) <= 384"
        ;;
    src_not_found)
        suffix="_src_not_found_uniq.txt"
        awk_prog='BEGIN { FS = "\t" }
            NF == 1 && $0 != "" { print; next }
            { bad++ }
            END { if (bad) printf "    %s: %d malformed rows skipped\n", lang, bad > "/dev/stderr" }'
        stage_ddl="CREATE TEMP TABLE stage (title text);"
        insert="INSERT INTO obs_src_not_found (lang_id, title)
                SELECT :lang_id, title FROM stage
                WHERE length(title) <= 384"
        ;;
    redirect_anomalies)
        suffix="_redirect_chain_exceeded_uniq.txt"
        awk_prog='BEGIN { FS = "\t" }
            NF == 2 && ($2 == "depth_exceeded" || $2 == "cycle") { print; next }
            { bad++ }
            END { if (bad) printf "    %s: %d malformed rows skipped\n", lang, bad > "/dev/stderr" }'
        stage_ddl="CREATE TEMP TABLE stage (title text, kind text);"
        insert="INSERT INTO obs_redirect_anomalies (lang_id, title, kind)
                SELECT :lang_id, title, kind FROM stage"
        ;;
    witness_methods)
        suffix="_witness_methods_uniq.txt"
        awk_prog='BEGIN { FS = "\t" }
            NF == 3 && $1 ~ /^Q[0-9]+$/ && $2 ~ /^Q[0-9]+$/ \
                && length($1) <= 11 && length($2) <= 11 && $3 ~ /^[0-9]+$/ { print; next }
            { bad++ }
            END { if (bad) printf "    %s: %d malformed rows skipped\n", lang, bad > "/dev/stderr" }'
        stage_ddl="CREATE TEMP TABLE stage (src varchar(11), dst varchar(11), method int2);"
        insert="INSERT INTO wp_witness_methods (lang_id, src, dst, method)
                SELECT :lang_id, src, dst, method FROM stage"
        ;;
    *)
        echo "load_obs.sh: unknown table '$TABLE'" >&2
        exit 1
        ;;
esac

case "$TABLE" in
    conv_failures)
        table_name="obs_conv_failures"
        pre_sql="DROP INDEX IF EXISTS obs_cf_target;
                 ALTER TABLE obs_conv_failures DROP CONSTRAINT IF EXISTS obs_conv_failures_pkey;"
        post_sql="ALTER TABLE obs_conv_failures ADD PRIMARY KEY (lang_id, src, target);
                  CREATE INDEX obs_cf_target ON obs_conv_failures (target);"
        ;;
    src_not_found)
        table_name="obs_src_not_found"
        pre_sql="ALTER TABLE obs_src_not_found DROP CONSTRAINT IF EXISTS obs_src_not_found_pkey;"
        post_sql="ALTER TABLE obs_src_not_found ADD PRIMARY KEY (lang_id, title);"
        ;;
    redirect_anomalies)
        table_name="obs_redirect_anomalies"
        pre_sql="ALTER TABLE obs_redirect_anomalies DROP CONSTRAINT IF EXISTS obs_redirect_anomalies_pkey;"
        post_sql="ALTER TABLE obs_redirect_anomalies ADD PRIMARY KEY (lang_id, title);"
        ;;
    witness_methods)
        table_name="wp_witness_methods"
        pre_sql="ALTER TABLE wp_witness_methods DROP CONSTRAINT IF EXISTS wp_witness_methods_pkey;"
        post_sql="ALTER TABLE wp_witness_methods ADD PRIMARY KEY (lang_id, src, dst, method);"
        ;;
esac

"${PSQL[@]}" -q -c "$pre_sql TRUNCATE $table_name;"

for file in "$@"; do
    base="$(basename "$file")"
    lang="${base%"$suffix"}"
    if [[ "$lang" == "$base" ]]; then
        echo "load_obs.sh: $file does not end in $suffix" >&2
        exit 1
    fi

    tmp="${file}.load.tmp"
    trap 'rm -f "$tmp"' EXIT
    LC_ALL=C awk -v lang="$lang" "$awk_prog" "$file" > "$tmp"

    "${PSQL[@]}" -q -v lang="$lang" <<SQL
INSERT INTO languages (code)
SELECT :'lang'
WHERE NOT EXISTS (SELECT 1 FROM languages WHERE code = :'lang')
ON CONFLICT (code) DO NOTHING;
SELECT id AS lang_id FROM languages WHERE code = :'lang' \\gset
$stage_ddl
\\copy stage FROM '$tmp' WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b')
WITH ins AS ($insert RETURNING 1)
SELECT format('    %s: staged=%s inserted=%s len_rejected=%s',
              :'lang',
              (SELECT count(*) FROM stage),
              count(*),
              (SELECT count(*) FROM stage) - count(*)) AS report
FROM ins \\gset
\\echo :report
SQL
    rm -f "$tmp"
    trap - EXIT
done

"${PSQL[@]}" -q -c "SET maintenance_work_mem = '4GB'; $post_sql"
echo "load_obs.sh: $table_name loaded from $# language file(s)"
