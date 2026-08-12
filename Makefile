SHELL := /bin/bash
# Recipes are decompression pipelines (pv | lbzip2 -dc | preproc). Without
# pipefail the exit status is the preprocessor's, so a shard that fails to
# decompress mid-stream looks like success and make records a truncated output
# as complete. With DELETE_ON_ERROR the partial file is removed instead of
# being cached as up to date on the next run.
.SHELLFLAGS := -o pipefail -c
.DELETE_ON_ERROR:
.SUFFIXES:

# Allow overriding parallelism: make JOBS=8 all
JOBS ?= $(shell nproc)

# Parallel sort. Recipes run concurrently under -j and each sort holds its
# buffer resident, so the per-sort budget is what bounds peak memory, not the
# single-sort figure. A 4G buffer times a dozen concurrent sorts alongside
# wp_convert (~50GB for the label and Commons tables) exceeds RAM on a machine
# with no swap, which takes the whole box down rather than failing one recipe.
# Keep the buffer modest and let sort spill to disk; these inputs exceed any
# plausible buffer anyway, so the merge is happening regardless.
SORT_BUFFER   ?= 1G
SORT_PARALLEL ?= 4
SORT := LC_ALL=C sort --parallel=$(SORT_PARALLEL) --buffer-size=$(SORT_BUFFER)

# STEP: announce a step (no timing — for steps with pv or other progress)
# TIMED: announce, run command, print elapsed time
STEP = @echo
TIMED = @./scripts/timed.sh

# Binaries (built via cargo)
BIN_DIR := target/release
DISCOVER   := $(BIN_DIR)/discover_languages
COMMONS    := $(BIN_DIR)/commons_preproc
WD_PREPROC := $(BIN_DIR)/wd_preproc
LEX_PREPROC:= $(BIN_DIR)/lex_preproc
WP_PREPROC := $(BIN_DIR)/wp_preproc
WP_CONVERT := $(BIN_DIR)/wp_convert
WP_AGG     := $(BIN_DIR)/wp_aggregate
WKT_PREPROC:= $(BIN_DIR)/wkt_preproc
CONVERT_WKT:= $(BIN_DIR)/convert_wkt2sv
AW_PREPROC := $(BIN_DIR)/aw_preproc
WF_PREPROC := $(BIN_DIR)/wf_preproc
DBP_CONVERT:= $(BIN_DIR)/dbp_convert

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

.PHONY: all clean build download check-downloads download-wikidata download-commons download-wikipedia download-wiktionary download-abstractwiki download-wikifunctions download-dbpedia wp_links_loaded wd_links_loaded wd_entities_loaded wd_labels_loaded wd_dates_loaded wd_coords_loaded lemma_loaded form_loaded lexeme_loaded sense_item_loaded sense_sense_loaded wkt_loaded aw_loaded wf_loaded dbp_loaded

all:
	@$(MAKE) --no-print-directory -j1 run/languages.json
	@$(MAKE) --no-print-directory -j1 wp_links_loaded wd_links_loaded wd_entities_loaded wd_labels_loaded wd_dates_loaded wd_coords_loaded lemma_loaded form_loaded lexeme_loaded sense_item_loaded sense_sense_loaded wkt_loaded aw_loaded wf_loaded dbp_loaded

build:
	$(TIMED) "cargo build --release" -- env RUSTFLAGS="-C target-cpu=native" cargo build --release

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

download-abstractwiki:
	./scripts/download.sh abstractwiki

download-wikifunctions:
	./scripts/download.sh wikifunctions

download-dbpedia: run/languages.json
	./scripts/download.sh dbpedia

# Re-check all downloads. Content exports are fetched when a newer completed
# export date is published; the manifest is rewritten only then, so downstream
# targets rebuild exactly when the underlying data actually changed.
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

data/commonswiki-all-titles-in-ns-6.gz:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh commons

# Wiki content comes from the MediaWiki Content File Exports, which ship one
# wiki as a set of page-id-ranged XML shards. download.sh writes the shard
# paths to data/content/<wiki>.manifest once every shard has been fetched and
# checksummed, so the manifest is the dependency Make tracks.
data/content/abstractwiki.manifest:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh abstractwiki

data/content/wikifunctionswiki.manifest:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wikifunctions

data/content/%wiki.manifest:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wikipedia-single $*

data/content/%wiktionary.manifest:
	@flock $(DOWNLOAD_LOCK) ./scripts/download.sh wiktionary-single $*

# Targets built by a pattern rule are intermediate by default, which means Make
# deletes them once the things depending on them are up to date. A manifest is
# the receipt for a multi-gigabyte download, so keep it.
.PRECIOUS: data/content/%wiki.manifest data/content/%wiktionary.manifest

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

run/commons_files.txt: data/commonswiki-all-titles-in-ns-6.gz | build
	$(STEP) "commons_preproc"
	@pv -N commons $< | gzip -dc | $(COMMONS) > $@

# ============================================================
# Wikidata entity preprocessing
# ============================================================

# wd_preproc produces all five outputs in one pass
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv run/coords.csv &: data/latest-all.json.gz run/languages.json | build
	$(STEP) "wd_preproc"
	@mkdir -p run
	@pv -N wikidata $< | zcat | $(WD_PREPROC)

run/links_uniq.csv: run/links.csv
	$(TIMED) "sort/uniq links.csv" -- sh -c '$(SORT) $< | uniq > $@'

run/date_claims_uniq.csv: run/date_claims.csv
	$(TIMED) "sort/uniq date_claims.csv" -- sh -c '$(SORT) $< | uniq > $@'

run/coords_uniq.csv: run/coords.csv
	$(TIMED) "sort/uniq coords.csv" -- sh -c '$(SORT) -t, -k1,1 -k2,2 -k3,3 -k6,6 -u $< > $@'

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
run/%_wikilinks.txt run/%_redirects.txt &: data/content/%wiki.manifest run/items.csv | build
	$(STEP) "wp_preproc $*"
	@flock $(XML_PREPROC_LOCK) bash -o pipefail -c 'pv -N "$*wiki" $$(cat $<) | lbzip2 -dc | $(WP_PREPROC) $*'

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

# Hits on Wikidata's language-neutral `mul` label, split by whether the name is
# claimed by one entity or several. Diagnostic streams like best_guesses: they
# do not feed wp_links.
run/%_mul_guesses_uniq.txt: run/%_mul_guesses.txt
	$(TIMED) "sort/uniq $*_mul_guesses" -- sh -c '$(SORT) $< | uniq > $@'

run/%_mul_ambiguous_uniq.txt: run/%_mul_ambiguous.txt
	$(TIMED) "sort/uniq $*_mul_ambiguous" -- sh -c '$(SORT) $< | uniq > $@'

run/%_dsts_failed_uniq.txt: run/%_conv_failed_uniq.txt
	$(TIMED) "sort/uniq $*_dsts_failed" -- sh -c 'cut -f2 $< | $(SORT) | uniq > $@'

# ============================================================
# Cross-language combination
# ============================================================

# K-way merge with witness provenance: tags each per-language stream with its
# id from the append-only `languages` table (inserting new codes first) and
# emits src,dst,"{id,...}" rows for \copy. Replaces sort | uniq -c | convert2sv.
run/wp_links_witnesses.csv: $(ALL_LANG_CONVERTED_UNIQ) | build
	$(TIMED) "wp_aggregate (all languages)" -- $(WP_AGG) --db-url "host=localhost dbname=$(DBNAME)" --output $@

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

run/mul_guesses_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_mul_guesses_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine mul_guesses" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_mul_guesses_uniq.txt/g'"'"'); \
		if [ -z "$$FILES" ]; then echo "Error: no language files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(SORT) -rn > $@'

run/mul_ambiguous_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_mul_ambiguous_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	$(TIMED) "combine mul_ambiguous" -- sh -c '\
		FILES=$$(./make_lang_targets.sh wikipedia ALL_LANG_CONVERTED_UNIQ | sed '"'"'s/_links_converted_uniq\.txt/_mul_ambiguous_uniq.txt/g'"'"'); \
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

run/items_loaded.csv: run/items.csv
	cp $< $@

# ============================================================
# Wiktionary pipeline
# ============================================================

# Serialized via shared lock: wkt_preproc is internally parallel
run/wkt/%_wikilinks.txt run/wkt/%_redirects.txt &: data/content/%wiktionary.manifest | build
	$(STEP) "wkt_preproc $*"
	@mkdir -p run/wkt
	@flock $(XML_PREPROC_LOCK) bash -o pipefail -c 'pv -N "$*wiktionary" $$(cat $<) | lbzip2 -dc | $(WKT_PREPROC) $*'

run/wkt/%_links_uniq.txt: run/wkt/%_wikilinks.txt
	$(TIMED) "sort/uniq wkt/$*" -- sh -c '$(SORT) $< | uniq > $@'

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv &: $(ALL_WKT_LINKS) | build
	$(TIMED) "convert_wkt2sv" -- sh -c '\
		mkdir -p run/wkt; \
		FILES=$$(./make_lang_targets.sh wiktionary ALL_WKT_LINKS); \
		if [ -z "$$FILES" ]; then echo "Error: no wiktionary files found" >&2; exit 1; fi; \
		$(SORT) $$FILES | uniq -c | $(CONVERT_WKT)'

run/wkt/entries_uniq.tsv: run/wkt/entries.tsv
	$(TIMED) "sort/uniq wkt/entries" -- sh -c '$(SORT) $< | uniq > $@'

# ============================================================
# Abstract Wikipedia pipeline
# ============================================================

run/aw/entries.tsv run/aw/refs.tsv &: data/content/abstractwiki.manifest | build
	$(STEP) "aw_preproc"
	@mkdir -p run/aw
	@pv -N abstractwiki $$(cat $<) | lbzip2 -dc | $(AW_PREPROC)

run/aw/entries_uniq.tsv: run/aw/entries.tsv
	$(TIMED) "sort/uniq aw/entries" -- sh -c '$(SORT) -u $< > $@'

run/aw/refs_uniq.tsv: run/aw/refs.tsv
	$(TIMED) "sort/uniq aw/refs" -- sh -c '$(SORT) -u $< > $@'

# ============================================================
# Wikifunctions pipeline
# ============================================================

run/wf/objects.tsv run/wf/labels.tsv &: data/content/wikifunctionswiki.manifest | build
	$(STEP) "wf_preproc"
	@mkdir -p run/wf
	@pv -N wikifunctions $$(cat $<) | lbzip2 -dc | $(WF_PREPROC)

run/wf/objects_uniq.tsv: run/wf/objects.tsv
	$(TIMED) "sort/uniq wf/objects" -- sh -c '$(SORT) -u $< > $@'

run/wf/labels_uniq.tsv: run/wf/labels.tsv
	$(TIMED) "sort/uniq wf/labels" -- sh -c '$(SORT) -u $< > $@'

# ============================================================
# DBpedia pipeline
# ============================================================

# DBpedia per-language rule uses a shell recipe to sidestep the = in the filename
run/dbp/dbp_mappings_%.tsv: run/wd_labels.tsv | build
	$(STEP) "dbp_convert $*"
	@mkdir -p run/dbp
	@pv -N 'dbpedia-$*' "data/dbpedia/mappingbased-objects_lang=$*.ttl.bz2" | lbzip2 -dc | $(DBP_CONVERT) $*

# Multilingual variant (as used for Wikipedia) would be:
#   $(SORT) $$FILES | uniq -c | $(SORT) -rn > $@
run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	$(TIMED) "combine dbpedia" -- sh -c '\
		mkdir -p run/dbp; \
		FILES=$$(./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS); \
		if [ -z "$$FILES" ]; then echo "Error: no dbpedia files found" >&2; exit 1; fi; \
		$(SORT) -u $$FILES > $@'

# ============================================================
# Database loading
# ============================================================
# Pattern: drop indexes -> truncate -> COPY -> rebuild indexes
# maintenance_work_mem=4GB speeds up index creation on large tables

PSQL := psql -d $(DBNAME)

wp_links_loaded: run/wp_links_witnesses.csv
	$(TIMED) "load wp_links" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wp_links_src; \
			DROP INDEX IF EXISTS idx_wp_links_dst; \
			DROP INDEX IF EXISTS idx_wp_links_count; \
			DROP INDEX IF EXISTS wp_links_witnesses_gin; \
			ALTER TABLE wp_links DROP CONSTRAINT IF EXISTS wp_links_pkey; \
			TRUNCATE wp_links; \
			" && \
		$(PSQL) -c "\copy wp_links (src, dst, witnesses) FROM '"'"'$<'"'"' CSV" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wp_links ADD PRIMARY KEY (src, dst); \
			CREATE INDEX idx_wp_links_src ON wp_links (src); \
			CREATE INDEX idx_wp_links_dst ON wp_links (dst); \
			CREATE INDEX idx_wp_links_count ON wp_links (wp_count DESC); \
			CREATE INDEX wp_links_witnesses_gin ON wp_links USING GIN (witnesses); \
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

wd_labels_loaded: run/wd_labels.tsv
	$(TIMED) "load wd_labels" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_labels_qid; \
			ALTER TABLE wd_labels DROP CONSTRAINT IF EXISTS wd_labels_pkey; \
			TRUNCATE wd_labels; \
			" && \
		$(PSQL) -c "\copy wd_labels FROM '"'"'$<'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"', QUOTE E'"'"'\b'"'"')" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_labels ADD PRIMARY KEY (lang, label, qid); \
			CREATE INDEX idx_wd_labels_qid ON wd_labels (qid); \
			" && touch $@'

wd_dates_loaded: run/date_claims_uniq.csv
	$(TIMED) "load wd_dates" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_dates_qid; \
			ALTER TABLE wd_dates DROP CONSTRAINT IF EXISTS wd_dates_pkey; \
			TRUNCATE wd_dates; \
			" && \
		$(PSQL) -c "\copy wd_dates FROM '"'"'$<'"'"' WITH (FORMAT csv, FORCE_NOT_NULL (source_property, source_target))" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_dates ADD PRIMARY KEY (qid, property, time_value, precision, source_property, source_target); \
			CREATE INDEX idx_wd_dates_qid ON wd_dates (qid); \
			" && touch $@'

wd_coords_loaded: run/coords_uniq.csv
	$(TIMED) "load wd_coords" -- sh -c '\
		$(PSQL) -c " \
			DROP INDEX IF EXISTS idx_wd_coords_qid; \
			ALTER TABLE wd_coords DROP CONSTRAINT IF EXISTS wd_coords_pkey; \
			TRUNCATE wd_coords; \
			" && \
		$(PSQL) -c "\copy wd_coords FROM '"'"'$<'"'"' WITH (FORMAT csv, FORCE_NOT_NULL (globe))" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wd_coords ADD PRIMARY KEY (qid, latitude, longitude, globe); \
			CREATE INDEX idx_wd_coords_qid ON wd_coords (qid); \
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
			ALTER TABLE lemma_lexeme ADD PRIMARY KEY (lang, lemma, lid); \
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

aw_loaded: run/aw/entries_uniq.tsv run/aw/refs_uniq.tsv
	$(TIMED) "load aw_entries + aw_refs" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE aw_entries DROP CONSTRAINT IF EXISTS aw_entries_pkey; \
			ALTER TABLE aw_refs DROP CONSTRAINT IF EXISTS aw_refs_pkey; \
			TRUNCATE aw_entries; \
			TRUNCATE aw_refs; \
			" && \
		$(PSQL) -c "\copy aw_entries FROM '"'"'run/aw/entries_uniq.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c "\copy aw_refs FROM '"'"'run/aw/refs_uniq.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE aw_entries ADD PRIMARY KEY (qid); \
			ALTER TABLE aw_refs ADD PRIMARY KEY (src_qid, ref); \
			" && touch $@'

wf_loaded: run/wf/objects_uniq.tsv run/wf/labels_uniq.tsv
	$(TIMED) "load wf_objects + wf_labels" -- sh -c '\
		$(PSQL) -c " \
			ALTER TABLE wf_objects DROP CONSTRAINT IF EXISTS wf_objects_pkey; \
			ALTER TABLE wf_labels DROP CONSTRAINT IF EXISTS wf_labels_pkey; \
			TRUNCATE wf_objects; \
			TRUNCATE wf_labels; \
			" && \
		$(PSQL) -c "\copy wf_objects FROM '"'"'run/wf/objects_uniq.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c "\copy wf_labels FROM '"'"'run/wf/labels_uniq.tsv'"'"' WITH (FORMAT csv, DELIMITER E'"'"'\t'"'"')" && \
		$(PSQL) -c " \
			SET maintenance_work_mem = '"'"'4GB'"'"'; \
			ALTER TABLE wf_objects ADD PRIMARY KEY (zid); \
			ALTER TABLE wf_labels ADD PRIMARY KEY (zid, lang, kind, label); \
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
	rm -f wp_links_loaded wd_links_loaded wd_entities_loaded wd_labels_loaded wd_dates_loaded wd_coords_loaded wkt_loaded aw_loaded wf_loaded dbp_loaded lemma_loaded form_loaded lexeme_loaded sense_item_loaded sense_sense_loaded
	rm -f lemma_loaded form_loaded lexeme_loaded sense_item_loaded sense_sense_loaded
	rm -f wkt_loaded dbp_loaded
