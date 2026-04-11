use anyhow::{Context, Result};
use chrono::Utc;
use algae_farmer::languages::LanguageRegistry;
use regex::Regex;
use std::collections::BTreeSet;

fn discover_wikipedia_languages(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"href="([a-z\-]+)wiki/""#).unwrap();
    let mut langs = BTreeSet::new();
    for cap in re.captures_iter(body) {
        let code = &cap[1];
        // Filter out non-language wikis
        if !code.contains("source")
            && !code.contains("quote")
            && !code.contains("books")
            && !code.contains("news")
            && !code.contains("versity")
            && !code.contains("voyage")
            && !code.contains("species")
            && !code.contains("data")
            && !code.contains("media")
            && !code.contains("commons")
            && !code.contains("meta")
            && code != "wiktionary"
        {
            langs.insert(code.to_string());
        }
    }
    langs
}

fn discover_wiktionary_languages(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"href="([a-z\-]+)wiktionary/""#).unwrap();
    let mut langs = BTreeSet::new();
    for cap in re.captures_iter(body) {
        langs.insert(cap[1].to_string());
    }
    langs
}

fn discover_dbpedia_languages(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"lang=([a-z\-]+)"#).unwrap();
    let mut langs = BTreeSet::new();
    for cap in re.captures_iter(body) {
        langs.insert(cap[1].to_string());
    }
    langs
}

fn main() -> Result<()> {
    env_logger::init();
    let client = reqwest::blocking::Client::builder()
        .user_agent("algae-farmer/0.1 (https://github.com/algae-farmer)")
        .build()?;

    log::info!("Discovering Wikipedia languages...");
    let wp_body = client
        .get("https://dumps.wikimedia.org/backup-index.html")
        .send()
        .context("fetching Wikipedia dump index")?
        .text()?;
    let wp_langs = discover_wikipedia_languages(&wp_body);

    log::info!("Discovering Wiktionary languages...");
    let wkt_body = client
        .get("https://dumps.wikimedia.org/backup-index.html")
        .send()
        .context("fetching Wiktionary dump index")?
        .text()?;
    let wkt_langs = discover_wiktionary_languages(&wkt_body);

    log::info!("Discovering DBpedia languages...");
    let dbp_body = client
        .get("https://downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/")
        .send()
        .context("fetching DBpedia index")?
        .text()?;
    let dbp_langs = discover_dbpedia_languages(&dbp_body);

    let registry = LanguageRegistry {
        discovered_at: Utc::now().to_rfc3339(),
        wikipedia: wp_langs.into_iter().collect(),
        wiktionary: wkt_langs.into_iter().collect(),
        dbpedia: dbp_langs.into_iter().collect(),
    };

    let json = serde_json::to_string_pretty(&registry)?;
    print!("{json}");
    Ok(())
}
