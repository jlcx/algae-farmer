#!/usr/bin/env bash
# Load preprocessed files from run/ into the algae Postgres database.
#
# Use this when the run/ directory was produced elsewhere (e.g. copied from
# another machine) so you don't want `make` to try to regenerate anything from
# the original Wikimedia dumps.
#
# For each input file that exists, this drops indexes / PK, TRUNCATEs the
# table, \copies the data in, then rebuilds indexes — mirroring the *_loaded
# recipes in the Makefile. Missing files are skipped with a warning.
#
# Usage:  scripts/load_from_run.sh          # loads everything present
#         DBNAME=other scripts/load_from_run.sh
set -euo pipefail

cd "$(dirname "$0")/.."

DBNAME="${DBNAME:-algae}"
PSQL=(psql -d "$DBNAME" -v ON_ERROR_STOP=1)

# load_table <file> <table> <copy_options> <pre_sql> <post_sql>
#   pre_sql  runs before TRUNCATE (drop indexes / PK)
#   post_sql runs after COPY     (add PK, create indexes)
load_table() {
    local file="$1" table="$2" copy_opts="$3" pre_sql="$4" post_sql="$5"

    if [[ ! -f "$file" ]]; then
        echo ">>> SKIP $table: $file not found"
        return
    fi

    echo ">>> LOAD $table  (<-  $file)"
    local start=$SECONDS

    "${PSQL[@]}" -c "$pre_sql TRUNCATE $table;"
    "${PSQL[@]}" -c "\copy $table FROM '$file' $copy_opts"
    "${PSQL[@]}" -c "SET maintenance_work_mem = '4GB'; $post_sql"

    printf "    done in %ds\n" $((SECONDS - start))
}

# ---- Wikidata ---------------------------------------------------------------

load_table run/items.csv wd_entities "CSV" \
    "DROP INDEX IF EXISTS idx_wd_entities_qid;
     ALTER TABLE wd_entities DROP CONSTRAINT IF EXISTS wd_entities_pkey;" \
    "ALTER TABLE wd_entities ADD PRIMARY KEY (qid);
     CREATE INDEX idx_wd_entities_qid ON wd_entities (qid);"

load_table run/links_uniq.csv wd_links "CSV" \
    "DROP INDEX IF EXISTS idx_wd_links_src;
     DROP INDEX IF EXISTS idx_wd_links_dst;
     ALTER TABLE wd_links DROP CONSTRAINT IF EXISTS wd_links_pkey;" \
    "ALTER TABLE wd_links ADD PRIMARY KEY (src, dst, prop);
     CREATE INDEX idx_wd_links_src ON wd_links (src);
     CREATE INDEX idx_wd_links_dst ON wd_links (dst);"

load_table run/wd_labels.tsv wd_labels \
    "WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b')" \
    "DROP INDEX IF EXISTS idx_wd_labels_qid;
     ALTER TABLE wd_labels DROP CONSTRAINT IF EXISTS wd_labels_pkey;" \
    "ALTER TABLE wd_labels ADD PRIMARY KEY (lang, label, qid);
     CREATE INDEX idx_wd_labels_qid ON wd_labels (qid);"

load_table run/date_claims_uniq.csv wd_dates \
    "WITH (FORMAT csv, FORCE_NOT_NULL (source_property, source_target))" \
    "DROP INDEX IF EXISTS idx_wd_dates_qid;
     ALTER TABLE wd_dates DROP CONSTRAINT IF EXISTS wd_dates_pkey;" \
    "ALTER TABLE wd_dates ADD PRIMARY KEY (qid, property, time_value, precision, source_property, source_target);
     CREATE INDEX idx_wd_dates_qid ON wd_dates (qid);"

load_table run/coords_uniq.csv wd_coords \
    "WITH (FORMAT csv, FORCE_NOT_NULL (globe))" \
    "DROP INDEX IF EXISTS idx_wd_coords_qid;
     ALTER TABLE wd_coords DROP CONSTRAINT IF EXISTS wd_coords_pkey;" \
    "ALTER TABLE wd_coords ADD PRIMARY KEY (qid, latitude, longitude, globe);
     CREATE INDEX idx_wd_coords_qid ON wd_coords (qid);"

# ---- Wikidata lexemes -------------------------------------------------------

load_table run/from_lemmas_uniq.tsv lemma_lexeme "DELIMITER E'\t'" \
    "ALTER TABLE lemma_lexeme DROP CONSTRAINT IF EXISTS lemma_lexeme_pkey;" \
    "ALTER TABLE lemma_lexeme ADD PRIMARY KEY (lang, lemma, lid);"

load_table run/from_forms_uniq.tsv form_lexeme "DELIMITER E'\t'" \
    "ALTER TABLE form_lexeme DROP CONSTRAINT IF EXISTS form_lexeme_pkey;" \
    "ALTER TABLE form_lexeme ADD PRIMARY KEY (lang, lemma, lid);"

load_table run/l2l_uniq.tsv lexeme_lexeme "DELIMITER E'\t'" \
    "ALTER TABLE lexeme_lexeme DROP CONSTRAINT IF EXISTS lexeme_lexeme_pkey;" \
    "ALTER TABLE lexeme_lexeme ADD PRIMARY KEY (src, dst, prop);"

load_table run/s2q_uniq.tsv sense_item "DELIMITER E'\t'" \
    "ALTER TABLE sense_item DROP CONSTRAINT IF EXISTS sense_item_pkey;" \
    "ALTER TABLE sense_item ADD PRIMARY KEY (src_lid, src_sid, dst, prop);"

load_table run/s2s_uniq.tsv sense_sense "DELIMITER E'\t'" \
    "ALTER TABLE sense_sense DROP CONSTRAINT IF EXISTS sense_sense_pkey;" \
    "ALTER TABLE sense_sense ADD PRIMARY KEY (src_lid, src_sid, dst_lid, dst_sid, prop);"

# ---- Wikipedia cross-language link graph ------------------------------------

load_table run/links_converted_uniq_combined.csv wp_links "CSV" \
    "DROP INDEX IF EXISTS idx_wp_links_src;
     DROP INDEX IF EXISTS idx_wp_links_dst;
     DROP INDEX IF EXISTS idx_wp_links_count;
     ALTER TABLE wp_links DROP CONSTRAINT IF EXISTS wp_links_pkey;" \
    "ALTER TABLE wp_links ADD PRIMARY KEY (src, dst);
     CREATE INDEX idx_wp_links_src ON wp_links (src);
     CREATE INDEX idx_wp_links_dst ON wp_links (dst);
     CREATE INDEX idx_wp_links_count ON wp_links (wp_count DESC);"

# ---- Wiktionary / Abstract Wikipedia / Wikifunctions / DBpedia --------------
# Loaded only if the corresponding subdirectory files were copied over.

load_table run/wkt/entries_uniq.tsv wkt_entries \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE wkt_entries DROP CONSTRAINT IF EXISTS wkt_entries_pkey;" \
    "ALTER TABLE wkt_entries ADD PRIMARY KEY (entry);"

load_table run/wkt/links_uniq_combined.tsv wkt_links \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE wkt_links DROP CONSTRAINT IF EXISTS wkt_links_pkey;" \
    "ALTER TABLE wkt_links ADD PRIMARY KEY (src, dst);"

load_table run/aw/entries_uniq.tsv aw_entries \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE aw_entries DROP CONSTRAINT IF EXISTS aw_entries_pkey;" \
    "ALTER TABLE aw_entries ADD PRIMARY KEY (qid);"

load_table run/aw/refs_uniq.tsv aw_refs \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE aw_refs DROP CONSTRAINT IF EXISTS aw_refs_pkey;" \
    "ALTER TABLE aw_refs ADD PRIMARY KEY (src_qid, ref);"

load_table run/wf/objects_uniq.tsv wf_objects \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE wf_objects DROP CONSTRAINT IF EXISTS wf_objects_pkey;" \
    "ALTER TABLE wf_objects ADD PRIMARY KEY (zid);"

load_table run/wf/labels_uniq.tsv wf_labels \
    "WITH (FORMAT csv, DELIMITER E'\t')" \
    "ALTER TABLE wf_labels DROP CONSTRAINT IF EXISTS wf_labels_pkey;" \
    "ALTER TABLE wf_labels ADD PRIMARY KEY (zid, lang, kind, label);"

load_table run/dbp/combined_mappings.tsv dbp_links "DELIMITER E'\t'" \
    "ALTER TABLE dbp_links DROP CONSTRAINT IF EXISTS dbp_links_pkey;" \
    "ALTER TABLE dbp_links ADD PRIMARY KEY (src, dst, predicate);"

echo
echo "All present files loaded."
