use anyhow::{Context, Result};
use chrono::Utc;
use algae_farmer::languages::LanguageRegistry;
use regex::Regex;
use reqwest::blocking::Client;
use std::collections::BTreeSet;
use std::sync::OnceLock;
use std::time::Duration;

const CONTENT_BASE: &str = "https://dumps.wikimedia.org/other/mediawiki_content_current";

/// Keep in sync with `DBP_VERSION` in scripts/download.sh — see the comment at
/// the DBpedia discovery step in `main`.
const DBP_VERSION: &str = "2021.09.01";

/// Concurrent probes against dumps.wikimedia.org. Kept modest deliberately:
/// this is ~500 small directory listings and we are a guest on that server.
const DEFAULT_PROBE_JOBS: usize = 8;
const PROBE_RETRIES: u32 = 3;

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

/// Wiki ids (`enwiki`, `frwiktionary`, `commonswiki`, ...) listed in a
/// directory index of the content-export tree.
fn parse_wiki_ids(body: &str) -> BTreeSet<String> {
    let re = Regex::new(r#"href="([a-z0-9_\-]+)/""#).unwrap();
    re.captures_iter(body)
        .map(|cap| cap[1].to_string())
        .collect()
}

/// Language codes of the wikis whose id is `<code><suffix>` — e.g. suffix
/// "wiki" picks `enwiki` but not `enwiktionary`, since the latter does not end
/// in "wiki".
fn languages_with_suffix(wiki_ids: &BTreeSet<String>, suffix: &str) -> BTreeSet<String> {
    wiki_ids
        .iter()
        .filter_map(|id| id.strip_suffix(suffix))
        .filter(|code| is_lang_code(code))
        .map(str::to_string)
        .collect()
}

/// Export date directories (`2026-08-01/`) listed in a wiki's export index,
/// newest first.
fn parse_export_dates(body: &str) -> Vec<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#"href="(\d{4}-\d{2}-\d{2})/""#).unwrap());
    let mut dates: Vec<String> = re.captures_iter(body).map(|c| c[1].to_string()).collect();
    dates.sort_unstable_by(|a, b| b.cmp(a));
    dates.dedup();
    dates
}

/// GET a URL, retrying transport errors and 5xx. `Ok(None)` means the server
/// answered with 404 — a definite "not there", as opposed to "could not tell".
fn get_text(client: &Client, url: &str) -> Result<Option<String>> {
    let mut last: Option<anyhow::Error> = None;
    for attempt in 1..=PROBE_RETRIES {
        match client.get(url).send() {
            Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => return Ok(None),
            Ok(resp) if resp.status().is_success() => return Ok(Some(resp.text()?)),
            Ok(resp) => last = Some(anyhow::anyhow!("HTTP {} from {url}", resp.status())),
            Err(e) => last = Some(anyhow::Error::new(e).context(format!("fetching {url}"))),
        }
        if attempt < PROBE_RETRIES {
            std::thread::sleep(Duration::from_secs(u64::from(attempt) * 2));
        }
    }
    Err(last.unwrap())
}

/// True if `url` exists, retrying the same way `get_text` does.
fn head_exists(client: &Client, url: &str) -> Result<bool> {
    let mut last: Option<anyhow::Error> = None;
    for attempt in 1..=PROBE_RETRIES {
        match client.head(url).send() {
            Ok(resp) if resp.status() == reqwest::StatusCode::NOT_FOUND => return Ok(false),
            Ok(resp) if resp.status().is_success() => return Ok(true),
            Ok(resp) => last = Some(anyhow::anyhow!("HTTP {} from {url}", resp.status())),
            Err(e) => last = Some(anyhow::Error::new(e).context(format!("heading {url}"))),
        }
        if attempt < PROBE_RETRIES {
            std::thread::sleep(Duration::from_secs(u64::from(attempt) * 2));
        }
    }
    Err(last.unwrap())
}

/// Newest *completed* export date for a wiki, mirroring `latest_export_date`
/// in scripts/download.sh: a date directory is only usable once SHA256SUMS has
/// been published under it.
///
/// `Ok(None)` means the wiki has no usable export — either it never will
/// (closed wikis such as `crwiki` and `klwiki` get an empty directory in the
/// index but are never exported) or not yet (a wiki created since the last
/// export run). An `Err` means the probe itself failed, which must not be
/// confused with "no export": silently dropping a language would quietly
/// shrink the dataset.
fn latest_export_date(client: &Client, wiki: &str) -> Result<Option<String>> {
    let listing = match get_text(client, &format!("{CONTENT_BASE}/{wiki}/"))? {
        Some(body) => body,
        None => return Ok(None),
    };
    for date in parse_export_dates(&listing) {
        let sums = format!("{CONTENT_BASE}/{wiki}/{date}/xml/bzip2/SHA256SUMS");
        if head_exists(client, &sums)? {
            return Ok(Some(date));
        }
    }
    Ok(None)
}

/// Drop candidate languages whose wiki has no completed content export.
///
/// The export index is not the same thing as the set of wikis that have an
/// export: it also contains directories for wikis that have none at all. Only
/// looking inside tells the difference, so this probes every candidate.
fn retain_with_exports(
    client: &Client,
    candidates: &BTreeSet<String>,
    suffix: &str,
    jobs: usize,
) -> Result<(BTreeSet<String>, BTreeSet<String>)> {
    let (work_tx, work_rx) = crossbeam_channel::unbounded();
    for lang in candidates {
        work_tx.send(lang.clone()).unwrap();
    }
    drop(work_tx);

    let (res_tx, res_rx) = crossbeam_channel::unbounded();
    std::thread::scope(|scope| {
        for _ in 0..jobs.max(1) {
            let work_rx = work_rx.clone();
            let res_tx = res_tx.clone();
            scope.spawn(move || {
                while let Ok(lang) = work_rx.recv() {
                    let wiki = format!("{lang}{suffix}");
                    let outcome = latest_export_date(client, &wiki);
                    res_tx.send((lang, wiki, outcome)).unwrap();
                }
            });
        }
    });
    drop(res_tx);

    let mut kept = BTreeSet::new();
    let mut skipped = BTreeSet::new();
    let mut failed = Vec::new();
    for (lang, wiki, outcome) in res_rx {
        match outcome {
            Ok(Some(date)) => {
                log::debug!("{wiki}: newest completed export {date}");
                kept.insert(lang);
            }
            Ok(None) => {
                skipped.insert(lang);
            }
            Err(e) => failed.push(format!("{wiki}: {e:#}")),
        }
    }

    // A probe that errored leaves us unable to say whether the wiki has an
    // export. Guessing either way is wrong, so refuse to write a registry we
    // cannot stand behind.
    if !failed.is_empty() {
        anyhow::bail!(
            "could not determine export status for {} wiki(s):\n  {}",
            failed.len(),
            failed.join("\n  ")
        );
    }

    if !skipped.is_empty() {
        log::warn!(
            "skipping {} *{suffix} with no completed content export: {}",
            skipped.len(),
            skipped
                .iter()
                .map(|l| format!("{l}{suffix}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    Ok((kept, skipped))
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
        .timeout(Duration::from_secs(120))
        .build()?;
    let jobs = std::env::var("DISCOVER_JOBS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(DEFAULT_PROBE_JOBS);

    // The MediaWiki Content File Exports index names every wiki the exporter
    // knows about, which is *not* the same as every wiki that has an export:
    // closed wikis (crwiki, klwiki) get an empty directory that never fills in,
    // and a wiki created since the last run has one too. Both would fail the
    // download with "no completed content export found", so the candidates
    // from the index get probed below before they reach the registry.
    log::info!("Discovering wikis with content exports...");
    let index_body = client
        .get(format!("{CONTENT_BASE}/"))
        .send()
        .context("fetching content export index")?
        .text()?;
    let wiki_ids = parse_wiki_ids(&index_body);
    if wiki_ids.is_empty() {
        anyhow::bail!("no wikis found in the content export index");
    }
    let wp_candidates = languages_with_suffix(&wiki_ids, "wiki");
    let wkt_candidates = languages_with_suffix(&wiki_ids, "wiktionary");
    log::info!(
        "Index lists {} Wikipedia and {} Wiktionary editions; checking exports with {jobs} jobs",
        wp_candidates.len(),
        wkt_candidates.len()
    );
    let (wp_langs, wp_no_export) = retain_with_exports(&client, &wp_candidates, "wiki", jobs)?;
    let (wkt_langs, _) = retain_with_exports(&client, &wkt_candidates, "wiktionary", jobs)?;
    log::info!(
        "Kept {} Wikipedia and {} Wiktionary editions with completed exports",
        wp_langs.len(),
        wkt_langs.len()
    );

    // Deliberately *not* the newest version directory. DBpedia stopped
    // publishing the multilingual mappingbased-objects set after 2021.12.01:
    // 2022.09.01 and 2022.12.01 contain `en` alone, so "latest" silently
    // collapses this pipeline from 39 languages to one. The version is pinned
    // to the same DBP_VERSION that scripts/download.sh uses, with the same
    // default, so discovery can never name a version the downloader won't
    // fetch from.
    let dbp_version = std::env::var("DBP_VERSION").unwrap_or_else(|_| DBP_VERSION.to_string());
    log::info!("Using DBpedia version: {dbp_version} (override with DBP_VERSION)");
    let dbp_body = client
        .get(format!(
            "https://downloads.dbpedia.org/repo/dbpedia/mappings/mappingbased-objects/{dbp_version}/"
        ))
        .send()
        .context("fetching DBpedia version index")?
        .text()?;
    let dbp_langs = discover_dbpedia_languages(&dbp_body);
    if dbp_langs.is_empty() {
        anyhow::bail!("no DBpedia languages found for version {dbp_version}");
    }
    log::info!("Found {} DBpedia languages", dbp_langs.len());

    let registry = LanguageRegistry {
        discovered_at: Utc::now().to_rfc3339(),
        wikipedia: wp_langs.into_iter().collect(),
        wiktionary: wkt_langs.into_iter().collect(),
        dbpedia: dbp_langs.into_iter().collect(),
        wikipedia_no_export: wp_no_export.into_iter().collect(),
    };

    let json = serde_json::to_string_pretty(&registry)?;
    print!("{json}");
    Ok(())
}
