use anyhow::{Context, Result};
use chrono::Utc;
use algae_farmer::languages::LanguageRegistry;
use regex::Regex;
use std::collections::BTreeSet;

/// Returns true if a code looks like a valid language code:
/// 2-3 lowercase letters, optionally followed by hyphenated subtags (e.g., "zh-min-nan"),
/// or the special code "simple".
fn is_lang_code(code: &str) -> bool {
    if code == "simple" {
        return true;
    }
    let parts: Vec<&str> = code.split('-').collect();
    if parts.is_empty() {
        return false;
    }
    let first = parts[0];
    if first.len() < 2 || first.len() > 3 || !first.chars().all(|c| c.is_ascii_lowercase()) {
        return false;
    }
    parts[1..].iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_lowercase()))
}

fn discover_wikipedia_languages(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"href="([a-z\-]+)wiki/"#).unwrap();
    let mut langs = BTreeSet::new();
    for cap in re.captures_iter(body) {
        let code = &cap[1];
        if is_lang_code(code) {
            langs.insert(code.to_string());
        }
    }
    langs
}

fn discover_wiktionary_languages(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"href="([a-z\-]+)wiktionary/"#).unwrap();
    let mut langs = BTreeSet::new();
    for cap in re.captures_iter(body) {
        let code = &cap[1];
        if is_lang_code(code) {
            langs.insert(code.to_string());
        }
    }
    langs
}

fn discover_dbpedia_languages(body: &str) -> BTreeSet<String> {
    // DBpedia uses URL-encoded lang%3D in hrefs and sometimes lang= in text
    let re = Regex::new(r#"lang(?:%3D|=)([a-z\-]+)"#).unwrap();
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
    let dbp_index = client
        .get("https://downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/")
        .send()
        .context("fetching DBpedia index")?
        .text()?;
    // Find the latest version directory (they sort chronologically)
    let version_re = Regex::new(r#"href="(\d{4}\.\d{2}\.\d{2})/""#).unwrap();
    let latest_version = version_re
        .captures_iter(&dbp_index)
        .last()
        .map(|c| c[1].to_string());
    let dbp_langs = if let Some(version) = latest_version {
        log::info!("Using DBpedia version: {version}");
        let dbp_body = client
            .get(format!(
                "https://downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/{version}/"
            ))
            .send()
            .context("fetching DBpedia version index")?
            .text()?;
        discover_dbpedia_languages(&dbp_body)
    } else {
        log::warn!("No DBpedia version found");
        BTreeSet::new()
    };

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
