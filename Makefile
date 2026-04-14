SHELL := /bin/bash
.SUFFIXES:

# Allow overriding parallelism: make JOBS=8 all
JOBS ?= $(shell nproc)

# Parallel sort with large buffer for better performance
SORT := sort --parallel=$(JOBS) --buffer-size=4G

# Step counter for progress tracking
N_WP  := $(words $(ALL_LANG_WIKILINKS))
N_WKT := $(words $(ALL_WKT_LINKS))
N_DBP := $(words $(ALL_DBP_MAPPINGS))
# Fixed steps: build, languages, commons, wd_preproc, lex_preproc, 6 wd sorts,
#   wp_convert, 5 cross-lang combines, convert2sv, convert_wkt2sv, wkt entries_uniq,
#   dbp combined, 11 db loads = 32
# Per WP lang: wp_preproc + 5 sorts = 6; Per WKT lang: wkt_preproc + sort = 2; Per DBP lang: 1
TOTAL_STEPS := $(shell echo $$(( 32 + $(N_WP) * 6 + $(N_WKT) * 2 + $(N_DBP) )))
STEP_COUNTER := .step_counter
# STEP: announce a step (no timing — for steps with pv or other progress)
# TIMED: announce, run command, print elapsed time
STEP = @./scripts/step.sh $(STEP_COUNTER) $(TOTAL_STEPS)
TIMED = @./scripts/step.sh $(STEP_COUNTER) $(TOTAL_STEPS)

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
ALL_LANG_WIKILINKS      := $(shell ./make_lang_targets.sh wikipedia ALL_LANG_WIKILINKS 2>/dev/null)
ALL_LANG_CONVERTED      := $(shell ./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED 2>/dev/null)
ALL_LANG_CONVERTED_UNIQ := $(shell ./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ 2>/dev/null)
ALL_WKT_LINKS           := $(shell ./make_lang_targets.sh wiktionary ALL_WKT_LINKS 2>/dev/null)
ALL_DBP_MAPPINGS        := $(shell ./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS 2>/dev/null)

# ============================================================
# Top-level targets
# ============================================================

.PHONY: all clean build download check-downloads download-wikidata download-commons download-wikipedia download-wiktionary download-dbpedia wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

all: wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded
	@rm -f $(STEP_COUNTER)

build:
	@rm -f $(STEP_COUNTER)
	$(TIMED) "cargo build --release" -- cargo build --release

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

# Re-check all downloads (wget -N only fetches if remote is newer).
# Updated files get new mtimes, so downstream targets rebuild automatically.
# Usage: make check-downloads && make -j16 all
check-downloads: run/languages.json
	./scripts/download.sh all

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
	$(STEP) "discover languages"
	@mkdir -p run
	@$(DISCOVER) > $@

# ============================================================
# Commons preprocessing
# ============================================================

run/commons_files.txt: data/commonswiki-latest-pages-articles-multistream-index.txt.bz2 | build
	$(STEP) "commons_preproc"
	@pv -N commons $< | lbzip2 -dc | $(COMMONS) > $@

# ============================================================
# Wikidata entity preprocessing
# ============================================================

# wd_preproc produces all four outputs in one pass
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv &: data/latest-all.json.gz run/languages.json | build
	$(STEP) "wd_preproc"
	@mkdir -p run
	@pv -N wikidata $< | zcat | $(WD_PREPROC)

run/links_uniq.csv: run/links.csv
	$(TIMED) "sort/uniq links.csv" -- sh -c '$(SORT) $< | uniq > $@'

# ============================================================
# Wikidata lexeme preprocessing
# ============================================================

run/from_lemmas.tsv run/from_forms.tsv run/l2l.tsv run/l2q.tsv run/s2q.tsv run/s2s.tsv &: data/latest-lexemes.json.bz2 | build
	$(STEP) "lex_preproc"
	@mkdir -p run
	@pv -N lexemes $< | lbzip2 -dc | $(LEX_PREPROC)

run/from_lemmas_uniq.tsv: run/from_lemmas.tsv
	$(TIMED) "sort/uniq from_lemmas" -- sh -c '$(SORT) $< | uniq > $@'

run/from_forms_uniq.tsv: run/from_forms.tsv
	$(TIMED) "sort/uniq from_forms" -- sh -c '$(SORT) $< | uniq > $@'

run/l2l_uniq.tsv: run/l2l.tsv
	$(TIMED) "sort/uniq l2l" -- sh -c '$(SORT) $< | uniq > $@'

run/s2q_uniq.tsv: run/s2q.tsv
	$(TIMED) "sort/uniq s2q" -- sh -c '$(SORT) $< | uniq > $@'

run/s2s_uniq.tsv: run/s2s.tsv
	$(TIMED) "sort/uniq s2s" -- sh -c '$(SORT) $< | uniq > $@'

# ============================================================
# Per-language Wikipedia extraction
# ============================================================

# Serialized via lock: wp/wkt_preproc are internally parallel, so only one at a time
XML_PREPROC_LOCK := .xml_preproc.lock
# Also wait for wd_preproc to finish so two CPU-saturating jobs don't overlap
run/%_wikilinks.txt run/%_redirects.txt &: data/%wiki-latest-pages-articles-multistream.xml.bz2 run/items.csv | build
	$(STEP) "wp_preproc $*"
	@flock $(XML_PREPROC_LOCK) sh -c "pv -N '$*wiki' $< | lbzip2 -dc | $(WP_PREPROC) $*"

# ============================================================
# Wikipedia link conversion (single invocation for all languages)
# ============================================================

$(ALL_LANG_CONVERTED) &: $(ALL_LANG_WIKILINKS) run/wd_labels.tsv run/commons_files.txt | build
	$(TIMED) "wp_convert (all languages)" -- $(WP_CONVERT)

# Per-language sort/dedup
run/%_links_converted_uniq.txt: run/%_links_converted.txt
	$(TIMED) "sort/uniq $*_links_converted" -- sh -c '$(SORT) $< | uniq > $@'

run/%_conv_failed_uniq.txt: run/%_conv_failed.txt
	$(TIMED) "sort/uniq $*_conv_failed" -- sh -c '$(SORT) $< | uniq > $@'

run/%_commons_uniq.txt: run/%_commons.txt
	$(TIMED) "sort/uniq $*_commons" -- sh -c '$(SORT) $< | uniq > $@'

run/%_best_guesses_uniq.txt: run/%_best_guesses.txt
	$(TIMED) "sort/uniq $*_best_guesses" -- sh -c '$(SORT) $< | uniq > $@'

run/%_dsts_failed_uniq.txt: run/%_conv_failed_uniq.txt
	$(TIMED) "sort/uniq $*_dsts_failed" -- sh -c 'cut -f2 $< | $(SORT) | uniq > $@'

# ============================================================
# Cross-language combination
# ============================================================

run/links_converted_uniq_combined.txt: $(ALL_LANG_CONVERTED_UNIQ)
	$(TIMED) "combine links_converted" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

run/conv_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_conv_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine conv_failed" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_conv_failed_uniq.txt/g'"'"'); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

run/commons_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_commons_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine commons" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_commons_uniq.txt/g'"'"'); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

run/best_guesses_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_best_guesses_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine best_guesses" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_best_guesses_uniq.txt/g'"'"'); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

run/dsts_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_dsts_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine dsts_failed" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_dsts_failed_uniq.txt/g'"'"'); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

# ============================================================
# Format conversion to CSV
# ============================================================

run/links_converted_uniq_combined.csv: run/links_converted_uniq_combined.txt | build
	$(TIMED) "convert2sv" -- $(CONVERT2SV) $<

run/items_loaded.csv: run/items.csv
	cp $< $@

# ============================================================
# Wiktionary pipeline
# ============================================================

# Serialized via shared lock: wkt_preproc is internally parallel
run/wkt/%_wikilinks.txt run/wkt/%_redirects.txt &: data/%wiktionary-latest-pages-articles-multistream.xml.bz2 | build
	$(STEP) "wkt_preproc $*"
	@mkdir -p run/wkt
	@flock $(XML_PREPROC_LOCK) sh -c "pv -N '$*wiktionary' $< | lbzip2 -dc | $(WKT_PREPROC) $*"

run/wkt/%_links_uniq.txt: run/wkt/%_wikilinks.txt
	$(TIMED) "sort/uniq wkt/$*" -- sh -c '$(SORT) $< | uniq > $@'

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv &: $(ALL_WKT_LINKS) | build
	$(TIMED) "convert_wkt2sv" -- sh -c '\
		mkdir -p run/wkt; \
		FILES=$$(./make_lang_targets.sh wiktionary ALL_WKT_LINKS); \
		if [ -z "$$FILES" ]; then echo "Error: no wiktionary files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn | $(CONVERT_WKT)'

run/wkt/entries_uniq.tsv: run/wkt/entries.tsv
	$(TIMED) "sort/uniq wkt/entries" -- sh -c '$(SORT) $< | uniq > $@'

# ============================================================
# DBpedia pipeline
# ============================================================

# DBpedia per-language rule uses a shell recipe to sidestep the = in the filename
run/dbp/dbp_mappings_%.tsv: run/wd_labels.tsv | build
	$(STEP) "dbp_convert $*"
	@mkdir -p run/dbp
	@pv -N 'dbpedia-$*' "data/dbpedia/mappingbased-objects_lang=$*.ttl.bz2" | lbzip2 -dc | $(DBP_CONVERT) $*

run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	$(TIMED) "combine dbpedia" -- sh -c '\
		mkdir -p run/dbp; \
		FILES=$$(./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS); \
		if [ -z "$$FILES" ]; then echo "Error: no dbpedia files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

# ============================================================
# Database loading
# ============================================================
# Pattern: drop indexes -> truncate -> COPY -> rebuild indexes
# maintenance_work_mem=4GB speeds up index creation on large tables

PSQL := psql -d $(DBNAME)

wp_links_loaded: run/links_converted_uniq_combined.csv
	$(TIMED) "load wp_links" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wp_links_src; \
			DROP INDEX IF EXISTS idx_wp_links_dst; \
			DROP INDEX IF EXISTS idx_wp_links_count; \
			ALTER TABLE wp_links DROP CONSTRAINT IF EXISTS wp_links_pkey; \
			TRUNCATE wp_links; \
			" && \
		$(PSQL) -c "\copy wp_links FROM '"'"'$<'"'"' CSV" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wp_links ADD PRIMARY KEY (src, dst); \
			CREATE INDEX idx_wp_links_src ON wp_links (src); \
			CREATE INDEX idx_wp_links_dst ON wp_links (dst); \
			CREATE INDEX idx_wp_links_count ON wp_links (wp_count DESC); \
			" && touch $@'

wd_links_loaded: run/links_uniq.csv
	$(TIMED) "load wd_links" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_links_src; \
			DROP INDEX IF EXISTS idx_wd_links_dst; \
			ALTER TABLE wd_links DROP CONSTRAINT IF EXISTS wd_links_pkey; \
			TRUNCATE wd_links; \
			" && \
		$(PSQL) -c "\copy wd_links FROM '"'"'$<'"'"' CSV" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_links ADD PRIMARY KEY (src, dst, prop); \
			CREATE INDEX idx_wd_links_src ON wd_links (src); \
			CREATE INDEX idx_wd_links_dst ON wd_links (dst); \
			" && touch $@'

wd_entities_loaded: run/items.csv
	$(TIMED) "load wd_entities" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_entities_qid; \
			ALTER TABLE wd_entities DROP CONSTRAINT IF EXISTS wd_entities_pkey; \
			TRUNCATE wd_entities; \
			" && \
		$(PSQL) -c "\copy wd_entities FROM '"'"'$<'"'"' CSV" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_entities ADD PRIMARY KEY (qid); \
			CREATE INDEX idx_wd_entities_qid ON wd_entities (qid); \
			" && touch $@'

wd_dates_loaded: run/date_claims.csv
	$(TIMED) "load wd_dates" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_dates_qid; \
			ALTER TABLE wd_dates DROP CONSTRAINT IF EXISTS wd_dates_pkey; \
			TRUNCATE wd_dates; \
			" && \
		$(PSQL) -c "\copy wd_dates FROM '"'"'$<'"'"' CSV" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_dates ADD PRIMARY KEY (qid, property, time_value, source_property, source_target); \
			CREATE INDEX idx_wd_dates_qid ON wd_dates (qid); \
			" && touch $@'

lemma_loaded: run/from_lemmas_uniq.tsv
	$(TIMED) "load lemma_lexeme" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE lemma_lexeme DROP CONSTRAINT IF EXISTS lemma_lexeme_pkey; \
			TRUNCATE lemma_lexeme; \
			" && \
		$(PSQL) -c "\copy lemma_lexeme FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE lemma_lexeme ADD PRIMARY KEY (lang, lemma); \
			" && touch $@'

form_loaded: run/from_forms_uniq.tsv
	$(TIMED) "load form_lexeme" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE form_lexeme DROP CONSTRAINT IF EXISTS form_lexeme_pkey; \
			TRUNCATE form_lexeme; \
			" && \
		$(PSQL) -c "\copy form_lexeme FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE form_lexeme ADD PRIMARY KEY (lang, lemma, lid); \
			" && touch $@'

lexeme_loaded: run/l2l_uniq.tsv
	$(TIMED) "load lexeme_lexeme" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE lexeme_lexeme DROP CONSTRAINT IF EXISTS lexeme_lexeme_pkey; \
			TRUNCATE lexeme_lexeme; \
			" && \
		$(PSQL) -c "\copy lexeme_lexeme FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE lexeme_lexeme ADD PRIMARY KEY (src, dst, prop); \
			" && touch $@'

sense_item_loaded: run/s2q_uniq.tsv
	$(TIMED) "load sense_item" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE sense_item DROP CONSTRAINT IF EXISTS sense_item_pkey; \
			TRUNCATE sense_item; \
			" && \
		$(PSQL) -c "\copy sense_item FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE sense_item ADD PRIMARY KEY (src_lid, src_sid, dst, prop); \
			" && touch $@'

sense_sense_loaded: run/s2s_uniq.tsv
	$(TIMED) "load sense_sense" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE sense_sense DROP CONSTRAINT IF EXISTS sense_sense_pkey; \
			TRUNCATE sense_sense; \
			" && \
		$(PSQL) -c "\copy sense_sense FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE sense_sense ADD PRIMARY KEY (src_lid, src_sid, dst_lid, dst_sid, prop); \
			" && touch $@'

wkt_loaded: run/wkt/entries_uniq.tsv run/wkt/links_uniq_combined.tsv
	$(TIMED) "load wkt_entries + wkt_links" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE wkt_entries DROP CONSTRAINT IF EXISTS wkt_entries_pkey; \
			ALTER TABLE wkt_links DROP CONSTRAINT IF EXISTS wkt_links_pkey; \
			TRUNCATE wkt_entries; \
			TRUNCATE wkt_links; \
			" && \
		$(PSQL) -c "\copy wkt_entries FROM '"'"'run/wkt/entries_uniq.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c "\copy wkt_links FROM '"'"'run/wkt/links_uniq_combined.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wkt_entries ADD PRIMARY KEY (entry); \
			ALTER TABLE wkt_links ADD PRIMARY KEY (src, dst); \
			" && touch $@'

dbp_loaded: run/dbp/combined_mappings.tsv
	$(TIMED) "load dbp_links" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE dbp_links DROP CONSTRAINT IF EXISTS dbp_links_pkey; \
			TRUNCATE dbp_links; \
			" && \
		$(PSQL) -c "\copy dbp_links FROM '"'"'$<'"'"' DELIMITER E'"'"'\t'"'"'" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE dbp_links ADD PRIMARY KEY (src, dst, predicate); \
			" && touch $@'

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
