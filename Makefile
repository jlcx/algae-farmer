SHELL := /bin/bash
.SUFFIXES:

# Allow overriding parallelism: make JOBS=8 all
JOBS ?= $(shell nproc)

# Binaries (built via cargo)
BIN_DIR := target/release
DISCOVER   := $(BIN_DIR)/discover_languages
COMMONS    := $(BIN_DIR)/commons_preproc
WD_PREPROC := $(BIN_DIR)/wd_preproc
LEX_PREPROC:= $(BIN_DIR)/lex_preproc
WP_PREPROC := $(BIN_DIR)/wp_preproc
WP_CONVERT := $(BIN_DIR)/wp_convert
CONVERT2SV := $(BIN_DIR)/convert2sv
WKT_PREPROC:= $(BIN_DIR)/wkt_preproc
CONVERT_WKT:= $(BIN_DIR)/convert_wkt2sv
DBP_CONVERT:= $(BIN_DIR)/dbp_convert
DB_LOAD    := $(BIN_DIR)/db_load

DBNAME ?= algae

# Language target lists (dynamically generated from run/languages.json)
ALL_LANG_CONVERTED_UNIQ := $(shell ./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ 2>/dev/null)
ALL_WKT_LINKS           := $(shell ./make_lang_targets.sh wiktionary ALL_WKT_LINKS 2>/dev/null)
ALL_DBP_MAPPINGS        := $(shell ./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS 2>/dev/null)

# ============================================================
# Top-level targets
# ============================================================

.PHONY: all clean build download download-wikidata download-commons download-wikipedia download-wiktionary download-dbpedia wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

all: wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

build:
	cargo build --release

# ============================================================
# Downloads
# ============================================================

download: run/languages.json
	./scripts/download.sh all

download-wikidata:
	./scripts/download.sh wikidata

download-commons:
	./scripts/download.sh commons

download-wikipedia: run/languages.json
	./scripts/download.sh wikipedia

download-wiktionary: run/languages.json
	./scripts/download.sh wiktionary

download-dbpedia: run/languages.json
	./scripts/download.sh dbpedia

# Data file rules: download on demand if missing.
# All downloads are serialized through a single lock file so that
# make -jN never issues concurrent requests to Wikimedia.
DOWNLOAD_LOCK := .download.lock

data/latest-all.json.gz:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wikidata

data/latest-lexemes.json.bz2:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wikidata

data/commonswiki-latest-pages-articles-multistream-index.txt.bz2:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh commons

data/%wiki-latest-pages-articles-multistream.xml.bz2:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wikipedia-single $*

data/%wiktionary-latest-pages-articles-multistream.xml.bz2:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wiktionary-single $*

# ============================================================
# Language discovery
# ============================================================

run/languages.json: | build
	@mkdir -p run
	$(DISCOVER) > $@

# ============================================================
# Commons preprocessing
# ============================================================

run/commons_files.txt: data/commonswiki-latest-pages-articles-multistream-index.txt.bz2 | build
	pv $< | lbzip2 -dc | $(COMMONS) > $@

# ============================================================
# Wikidata entity preprocessing
# ============================================================

# wd_preproc produces all four outputs in one pass
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv &: data/latest-all.json.gz run/languages.json | build
	@mkdir -p run
	pv $< | zcat | $(WD_PREPROC)

run/links_uniq.csv: run/links.csv
	sort $< | uniq > $@

# ============================================================
# Wikidata lexeme preprocessing
# ============================================================

run/from_lemmas.tsv run/from_forms.tsv run/l2l.tsv run/l2q.tsv run/s2q.tsv run/s2s.tsv &: data/latest-lexemes.json.bz2 | build
	@mkdir -p run
	pv $< | lbzip2 -dc | $(LEX_PREPROC)

run/from_lemmas_uniq.tsv: run/from_lemmas.tsv
	sort $< | uniq > $@

run/from_forms_uniq.tsv: run/from_forms.tsv
	sort $< | uniq > $@

run/l2l_uniq.tsv: run/l2l.tsv
	sort $< | uniq > $@

run/s2q_uniq.tsv: run/s2q.tsv
	sort $< | uniq > $@

run/s2s_uniq.tsv: run/s2s.tsv
	sort $< | uniq > $@

# ============================================================
# Per-language Wikipedia extraction
# ============================================================

# Serialized via lock: wp_preproc is internally parallel, so only one at a time
WP_PREPROC_LOCK := .wp_preproc.lock
# Also wait for wd_preproc to finish so two CPU-saturating jobs don't overlap
run/%_wikilinks.txt run/%_redirects.txt &: data/%wiki-latest-pages-articles-multistream.xml.bz2 run/items.csv | build
	@flock $(WP_PREPROC_LOCK) sh -c "pv $< | lbzip2 -dc | $(WP_PREPROC) $*"

# ============================================================
# Wikipedia link conversion (per language)
# ============================================================

run/%_links_converted.txt: run/%_wikilinks.txt run/%_redirects.txt run/wd_labels.tsv run/commons_files.txt | build
	$(WP_CONVERT) $*

# Per-language sort/dedup
run/%_links_converted_uniq.txt: run/%_links_converted.txt
	sort $< | uniq > $@

run/%_conv_failed_uniq.txt: run/%_conv_failed.txt
	sort $< | uniq > $@

run/%_commons_uniq.txt: run/%_commons.txt
	sort $< | uniq > $@

run/%_best_guesses_uniq.txt: run/%_best_guesses.txt
	sort $< | uniq > $@

run/%_dsts_failed_uniq.txt: run/%_conv_failed_uniq.txt
	cut -f2 $< | sort | uniq > $@

# ============================================================
# Cross-language combination
# ============================================================

run/links_converted_uniq_combined.txt: $(ALL_LANG_CONVERTED_UNIQ)
	@FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ); \
	if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

run/conv_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_conv_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	@FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed 's/_links_converted_uniq\.txt/_conv_failed_uniq.txt/g'); \
	if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

run/commons_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_commons_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	@FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed 's/_links_converted_uniq\.txt/_commons_uniq.txt/g'); \
	if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

run/best_guesses_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_best_guesses_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	@FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed 's/_links_converted_uniq\.txt/_best_guesses_uniq.txt/g'); \
	if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

run/dsts_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_dsts_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	@FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed 's/_links_converted_uniq\.txt/_dsts_failed_uniq.txt/g'); \
	if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

# ============================================================
# Format conversion to CSV
# ============================================================

run/links_converted_uniq_combined.csv: run/links_converted_uniq_combined.txt | build
	$(CONVERT2SV) $<

run/items_loaded.csv: run/items.csv
	cp $< $@

# ============================================================
# Wiktionary pipeline
# ============================================================

run/wkt/%_wikilinks.txt run/wkt/%_redirects.txt &: data/%wiktionary-latest-pages-articles-multistream.xml.bz2 | build
	@mkdir -p run/wkt
	pv $< | lbzip2 -dc | $(WKT_PREPROC) $*

run/wkt/%_links_uniq.txt: run/wkt/%_wikilinks.txt
	sort $< | uniq > $@

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv &: $(ALL_WKT_LINKS) | build
	@mkdir -p run/wkt
	@FILES=$$(./make_lang_targets.sh wiktionary ALL_WKT_LINKS); \
	if [ -z "$$FILES" ]; then echo "Error: no wiktionary files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn | $(CONVERT_WKT)

run/wkt/entries_uniq.tsv: run/wkt/entries.tsv
	sort $< | uniq > $@

# ============================================================
# DBpedia pipeline
# ============================================================

# DBpedia per-language rule uses a shell recipe to sidestep the = in the filename
run/dbp/dbp_mappings_%.tsv: run/wd_labels.tsv | build
	@mkdir -p run/dbp
	pv "data/dbpedia/mappingbased-objects_lang=$*.ttl.bz2" | lbzip2 -dc | $(DBP_CONVERT) $*

run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	@mkdir -p run/dbp
	@FILES=$$(./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS); \
	if [ -z "$$FILES" ]; then echo "Error: no dbpedia files found" >&2; exit 1; fi; \
	sort $$FILES | uniq -c | sort -rn > $@

# ============================================================
# Database loading
# ============================================================

wp_links_loaded: run/links_converted_uniq_combined.csv
	psql -d $(DBNAME) -c "\copy wp_links FROM '$<' CSV" && touch $@

wd_links_loaded: run/links_uniq.csv
	psql -d $(DBNAME) -c "\copy wd_links FROM '$<' CSV" && touch $@

wd_entities_loaded: run/items.csv
	psql -d $(DBNAME) -c "\copy wd_entities FROM '$<' CSV" && touch $@

wd_dates_loaded: run/date_claims.csv
	psql -d $(DBNAME) -c "\copy wd_dates FROM '$<' CSV" && touch $@

lemma_loaded: run/from_lemmas_uniq.tsv
	psql -d $(DBNAME) -c "\copy lemma_lexeme FROM '$<' DELIMITER E'\t'" && touch $@

form_loaded: run/from_forms_uniq.tsv
	psql -d $(DBNAME) -c "\copy form_lexeme FROM '$<' DELIMITER E'\t'" && touch $@

lexeme_loaded: run/l2l_uniq.tsv
	psql -d $(DBNAME) -c "\copy lexeme_lexeme FROM '$<' DELIMITER E'\t'" && touch $@

sense_item_loaded: run/s2q_uniq.tsv
	psql -d $(DBNAME) -c "\copy sense_item FROM '$<' DELIMITER E'\t'" && touch $@

sense_sense_loaded: run/s2s_uniq.tsv
	psql -d $(DBNAME) -c "\copy sense_sense FROM '$<' DELIMITER E'\t'" && touch $@

wkt_loaded: run/wkt/entries_uniq.tsv run/wkt/links_uniq_combined.tsv
	psql -d $(DBNAME) -c "\copy wkt_entries FROM 'run/wkt/entries_uniq.tsv' DELIMITER E'\t'" && \
	psql -d $(DBNAME) -c "\copy wkt_links FROM 'run/wkt/links_uniq_combined.tsv' DELIMITER E'\t'" && \
	touch $@

dbp_loaded: run/dbp/combined_mappings.tsv
	psql -d $(DBNAME) -c "\copy wp_links FROM '$<' DELIMITER E'\t'" && touch $@

# ============================================================
# Schema setup
# ============================================================

.PHONY: db_setup
db_setup:
	psql -d $(DBNAME) -f queries/db_commands.sql

# ============================================================
# Clean
# ============================================================

clean:
	rm -rf run/
	rm -f wp_links_loaded wd_links_loaded wd_entities_loaded wd_dates_loaded
	rm -f lemma_loaded form_loaded lexeme_loaded sense_item_loaded sense_sense_loaded
	rm -f wkt_loaded dbp_loaded
