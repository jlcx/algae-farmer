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

.PHONY: all clean build wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

all: wp_links_loaded wd_links_loaded wkt_loaded dbp_loaded

build:
	cargo build --release

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
	bzcat $< | $(COMMONS) > $@

# ============================================================
# Wikidata entity preprocessing
# ============================================================

# wd_preproc produces all four outputs in one pass
run/items.csv run/links.csv run/wd_labels.tsv run/date_claims.csv &: data/latest-all.json.gz run/languages.json | build
	@mkdir -p run
	zcat $< | $(WD_PREPROC)

run/links_uniq.csv: run/links.csv
	sort $< | uniq > $@

# ============================================================
# Wikidata lexeme preprocessing
# ============================================================

run/from_lemmas.tsv run/from_forms.tsv run/l2l.tsv run/l2q.tsv run/s2q.tsv run/s2s.tsv &: data/latest-all.json.gz | build
	@mkdir -p run
	zcat $< | $(LEX_PREPROC)

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

run/%_wikilinks.txt run/%_redirects.txt &: data/%wiki-latest-pages-articles-multistream.xml.bz2 | build
	bzcat $< | $(WP_PREPROC) $*

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
	sort $^ | uniq -c | sort -rn > $@

run/conv_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_conv_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	sort $^ | uniq -c | sort -rn > $@

run/commons_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_commons_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	sort $^ | uniq -c | sort -rn > $@

run/best_guesses_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_best_guesses_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	sort $^ | uniq -c | sort -rn > $@

run/dsts_failed_uniq_combined.txt: $(patsubst %_links_converted_uniq.txt,%_dsts_failed_uniq.txt,$(ALL_LANG_CONVERTED_UNIQ))
	sort $^ | uniq -c | sort -rn > $@

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
	bzcat $< | $(WKT_PREPROC) $*

run/wkt/%_links_uniq.txt: run/wkt/%_wikilinks.txt
	sort $< | uniq > $@

run/wkt/links_uniq_combined.tsv run/wkt/entries.tsv &: $(ALL_WKT_LINKS) | build
	@mkdir -p run/wkt
	sort $^ | uniq -c | sort -rn | $(CONVERT_WKT)

run/wkt/entries_uniq.tsv: run/wkt/entries.tsv
	sort $< | uniq > $@

# ============================================================
# DBpedia pipeline
# ============================================================

DBP_SRC_PREFIX := data/dbpedia/mappingbased-objects_lang
define dbp_rule
run/dbp/dbp_mappings_$(1).tsv: $(DBP_SRC_PREFIX)$(EQ)$(1).ttl.bz2 run/wd_labels.tsv | build
	@mkdir -p run/dbp
	bzcat $$< | $$(DBP_CONVERT) $(1)
endef
EQ := =

# Generate DBpedia per-language rules dynamically
# (When languages are not yet discovered, this is a no-op)
DBP_LANGS := $(shell ./make_lang_targets.sh dbpedia ALL_DBP_MAPPINGS 2>/dev/null | sed 's|run/dbp/dbp_mappings_||g; s|\.tsv||g')
$(foreach lang,$(DBP_LANGS),$(eval $(call dbp_rule,$(lang))))

run/dbp/combined_mappings.tsv: $(ALL_DBP_MAPPINGS)
	@mkdir -p run/dbp
	sort $^ | uniq -c | sort -rn > $@

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
