use algae_farmer::languages;
use anyhow::Result;
use crossbeam_channel::bounded;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::thread;
use sysinfo::System;

type QidDict = HashMap<String, HashMap<String, String>>;

// Resolution method ids for the side-channel, mirroring the append-only
// resolution_methods table (queries/db_commands.sql). Only degraded successful
// resolutions are recorded; direct/capfirst/whitespace and depth-1 redirects
// are routine MediaWiki mechanics and stay unrecorded on volume grounds.
const METHOD_REDIRECT_DEEP: u8 = 1;
const METHOD_CROSSLANG_QID: u8 = 2;
const METHOD_CROSSLANG_TITLE: u8 = 3;

/// Maximum stored length (chars) for diagnostic title/target fields, matching
/// the CHECK constraints on the obs_* tables.
const MAX_DIAG_FIELD_CHARS: usize = 384;

/// Make a title/target safe for the diagnostic files' \copy load path
/// (tab-delimited, quoting disabled via QUOTE E'\b'): the delimiter, line
/// separators, and the quote byte are replaced with spaces. Values longer
/// than the obs_* length cap are dropped (None) — real titles are <= 255
/// bytes, anything longer is wikitext junk — and counted by the caller.
fn sanitize_diag_field(s: &str) -> Option<String> {
    if s.chars().count() > MAX_DIAG_FIELD_CHARS {
        return None;
    }
    Some(s.replace(['\t', '\n', '\r', '\u{8}'], " "))
}

fn capfirst(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(c) => {
            let mut result = String::with_capacity(s.len());
            for uc in c.to_uppercase() {
                result.push(uc);
            }
            result.extend(chars);
            result
        }
    }
}

fn is_qid(s: &str) -> bool {
    let s = s.trim();
    if s.len() < 2 {
        return false;
    }
    let first = s.as_bytes()[0];
    (first == b'Q' || first == b'q') && s[1..].chars().all(|c| c.is_ascii_digit())
}

/// Loads wd_labels.tsv into a per-language title -> QID map.
///
/// Also returns the set of `mul` keys that more than one entity claims. Unlike
/// the per-language keys, which are page titles and unique within a wiki, a
/// `mul` value is a name and several entities can share one ("H", "Groningen").
/// Those keys are kept — the first QID seen wins, which is stable because the
/// dump order is — but they are reported so hits on them can be segregated
/// downstream instead of silently becoming edges.
fn load_qid_dict(run_dir: &Path, memory_ceiling: u8) -> Result<(QidDict, HashSet<String>)> {
    let labels_path = run_dir.join("wd_labels.tsv");
    let mut dict: QidDict = HashMap::new();
    let mut mul_ambiguous: HashSet<String> = HashSet::new();

    let sys = System::new_all();
    let total_mem = sys.total_memory();
    let ceiling = (total_mem as f64 * memory_ceiling as f64 / 100.0) as u64;

    log::info!(
        "Loading wd_labels.tsv (memory ceiling: {}% = {} MB)",
        memory_ceiling,
        ceiling / 1_048_576
    );

    let file = std::fs::File::open(&labels_path)?;
    let reader = BufReader::new(file);

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let lang = parts[0];
        let title = parts[1];
        let qid = parts[2];

        let entry = dict.entry(lang.to_string()).or_default();
        if lang == "mul" {
            // First writer wins, so a later duplicate cannot quietly relabel an
            // entity; record the collision instead.
            match entry.get(title) {
                Some(existing) if existing != qid => {
                    mul_ambiguous.insert(title.to_string());
                }
                Some(_) => {}
                None => {
                    entry.insert(title.to_string(), qid.to_string());
                }
            }
        } else {
            entry.insert(title.to_string(), qid.to_string());
        }
    }

    let used_mem = sys.used_memory();
    log::info!(
        "Loaded wd_labels.tsv in-memory ({} languages, ~{} MB used)",
        dict.len(),
        used_mem / 1_048_576
    );
    let mul_total = dict.get("mul").map_or(0, |d| d.len());
    log::info!(
        "mul labels: {mul_total} distinct, {} shared by more than one entity ({:.2}%)",
        mul_ambiguous.len(),
        100.0 * mul_ambiguous.len() as f64 / mul_total.max(1) as f64
    );

    Ok((dict, mul_ambiguous))
}

fn load_redirects(path: &Path) -> Result<HashMap<String, String>> {
    let mut redirects = HashMap::new();
    if !path.exists() {
        return Ok(redirects);
    }
    let file = std::fs::File::open(path)?;
    let reader = BufReader::new(file);
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let parts: Vec<&str> = line.splitn(2, '\t').collect();
        if parts.len() == 2 {
            redirects.insert(parts[0].to_string(), parts[1].to_string());
        }
    }
    Ok(redirects)
}

fn load_commons_files(path: &Path) -> Result<HashSet<String>> {
    let mut files = HashSet::new();
    if !path.exists() {
        return Ok(files);
    }
    let file = std::fs::File::open(path)?;
    let reader = BufReader::new(file);
    for line in reader.lines() {
        if let Ok(l) = line {
            files.insert(l);
        }
    }
    Ok(files)
}

enum RedirectOutcome {
    /// Non-redirect title reached after `depth` hops (0 = not a redirect).
    Resolved { title: String, depth: usize },
    Cycle,
    DepthExceeded,
}

fn resolve_redirect(
    title: &str,
    redirects: &HashMap<String, String>,
    max_depth: usize,
) -> RedirectOutcome {
    let mut current = title.to_string();
    let mut visited = HashSet::new();

    for depth in 0..max_depth {
        if visited.contains(&current) {
            return RedirectOutcome::Cycle;
        }
        visited.insert(current.clone());
        match redirects.get(&current) {
            Some(target) => current = target.clone(),
            None => return RedirectOutcome::Resolved { title: current, depth },
        }
    }
    RedirectOutcome::DepthExceeded
}

fn process_language(
    lang: &str,
    run_dir: &Path,
    qid_dict: &QidDict,
    commons_files: &HashSet<String>,
    mul_ambiguous: &HashSet<String>,
    max_redirect_depth: usize,
) -> Result<()> {
    let wikilinks_path = run_dir.join(format!("{lang}_wikilinks.txt"));
    let redirects_path = run_dir.join(format!("{lang}_redirects.txt"));

    if !wikilinks_path.exists() {
        log::warn!("[{lang}] No wikilinks file found, skipping");
        return Ok(());
    }

    let redirects = load_redirects(&redirects_path)?;

    let converted_path = run_dir.join(format!("{lang}_links_converted.txt"));
    let failed_path = run_dir.join(format!("{lang}_conv_failed.txt"));
    let commons_path = run_dir.join(format!("{lang}_commons.txt"));
    let best_path = run_dir.join(format!("{lang}_best_guesses.txt"));
    let mul_path = run_dir.join(format!("{lang}_mul_guesses.txt"));
    let mul_amb_path = run_dir.join(format!("{lang}_mul_ambiguous.txt"));
    let src_not_found_path = run_dir.join(format!("{lang}_src_not_found.txt"));
    let chain_exceeded_path = run_dir.join(format!("{lang}_redirect_chain_exceeded.txt"));
    let witness_methods_path = run_dir.join(format!("{lang}_witness_methods.txt"));

    let mut converted_out = BufWriter::new(std::fs::File::create(&converted_path)?);
    let mut failed_out = BufWriter::new(std::fs::File::create(&failed_path)?);
    let mut commons_out = BufWriter::new(std::fs::File::create(&commons_path)?);
    let mut best_out = BufWriter::new(std::fs::File::create(&best_path)?);
    let mut mul_out = BufWriter::new(std::fs::File::create(&mul_path)?);
    let mut mul_amb_out = BufWriter::new(std::fs::File::create(&mul_amb_path)?);
    let mut src_not_found_out = BufWriter::new(std::fs::File::create(&src_not_found_path)?);
    let mut chain_exceeded_out = BufWriter::new(std::fs::File::create(&chain_exceeded_path)?);
    let mut witness_methods_out = BufWriter::new(std::fs::File::create(&witness_methods_path)?);

    let lang_dict = qid_dict.get(lang);
    let best_dict = qid_dict.get("best");
    let mul_dict = qid_dict.get("mul");

    let wikilinks_file = std::fs::File::open(&wikilinks_path)?;
    let reader = BufReader::new(wikilinks_file);

    let mut count = 0u64;
    let mut converted = 0u64;
    let mut failed = 0u64;
    let mut wikt_count = 0u64;
    let mut mul_count = 0u64;
    let mut mul_amb_count = 0u64;
    // Diagnostic rows dropped by the emit-time length filter (sanitize_diag_field)
    let mut len_rejected = 0u64;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let parts: Vec<&str> = line.splitn(2, '\t').collect();
        if parts.len() != 2 {
            continue;
        }
        let source_title = parts[0].trim();
        let link_target = parts[1].trim();

        count += 1;

        // Source lookup
        let src_qid = match lang_dict.and_then(|d| d.get(source_title)) {
            Some(q) => q.clone(),
            None => {
                match sanitize_diag_field(source_title) {
                    Some(t) => writeln!(src_not_found_out, "{t}")?,
                    None => len_rejected += 1,
                }
                continue;
            }
        };

        // Target resolution - try strategies in order
        let original_link = link_target.to_string();

        // a. Direct lookup
        if let Some(qid) = lang_dict.and_then(|d| d.get(link_target)) {
            writeln!(converted_out, "{src_qid}\t{qid}")?;
            converted += 1;
            continue;
        }

        // b. Capitalized first letter
        let cap_target = capfirst(link_target);
        if let Some(qid) = lang_dict.and_then(|d| d.get(&cap_target)) {
            writeln!(converted_out, "{src_qid}\t{qid}")?;
            converted += 1;
            continue;
        }

        // c. Redirect resolution
        let mut resolved = false;
        for try_target in &[link_target.to_string(), cap_target.clone()] {
            match resolve_redirect(try_target, &redirects, max_redirect_depth) {
                outcome @ (RedirectOutcome::Cycle | RedirectOutcome::DepthExceeded) => {
                    let kind = match outcome {
                        RedirectOutcome::Cycle => "cycle",
                        _ => "depth_exceeded",
                    };
                    match sanitize_diag_field(try_target) {
                        Some(t) => writeln!(chain_exceeded_out, "{t}\t{kind}")?,
                        None => len_rejected += 1,
                    }
                }
                RedirectOutcome::Resolved { title, depth } => {
                    if &title != try_target {
                        let qid = lang_dict.and_then(|d| {
                            d.get(&title).or_else(|| d.get(&capfirst(&title)))
                        });
                        if let Some(qid) = qid {
                            writeln!(converted_out, "{src_qid}\t{qid}")?;
                            // Chains of >= 2 hops are a title-drift signal.
                            if depth >= 2 {
                                writeln!(
                                    witness_methods_out,
                                    "{src_qid}\t{qid}\t{METHOD_REDIRECT_DEEP}"
                                )?;
                            }
                            converted += 1;
                            resolved = true;
                            break;
                        }
                    }
                }
            }
        }
        if resolved {
            continue;
        }

        // d. Whitespace normalization
        let normalized = link_target.replace("&nbsp;", " ").replace('_', " ");
        if normalized != link_target {
            if let Some(qid) = lang_dict.and_then(|d| d.get(&normalized)) {
                writeln!(converted_out, "{src_qid}\t{qid}")?;
                converted += 1;
                continue;
            }
        }

        // e. Commons detection
        if let Some(colon_pos) = link_target.find(':') {
            let suffix = &link_target[colon_pos + 1..];
            let file_suffix = if suffix.starts_with("File:") {
                &suffix[5..]
            } else {
                suffix
            };
            if commons_files.contains(file_suffix) || commons_files.contains(suffix) {
                writeln!(commons_out, "{src_qid}\t{}", file_suffix)?;
                continue;
            }
        }

        // f. Cross-language QID link
        if let Some(colon_pos) = link_target.find(':') {
            let prefix = &link_target[..colon_pos];
            let suffix = &link_target[colon_pos + 1..];

            let suffix = suffix.trim();
            if (prefix == "d" || prefix == "D") && is_qid(suffix) {
                let dst = suffix.to_uppercase();
                writeln!(converted_out, "{src_qid}\t{dst}")?;
                writeln!(witness_methods_out, "{src_qid}\t{dst}\t{METHOD_CROSSLANG_QID}")?;
                converted += 1;
                continue;
            }

            // g. Cross-language title lookup
            if let Some(cross_dict) = qid_dict.get(prefix) {
                let qid = cross_dict
                    .get(suffix)
                    .or_else(|| cross_dict.get(&capfirst(suffix)));
                if let Some(qid) = qid {
                    writeln!(converted_out, "{src_qid}\t{qid}")?;
                    writeln!(witness_methods_out, "{src_qid}\t{qid}\t{METHOD_CROSSLANG_TITLE}")?;
                    converted += 1;
                    continue;
                }
            }
        }

        // h. Language-neutral (`mul`) label fallback, tried ahead of `best` so
        //    that `best` sees only what mul missed — the two volumes then read
        //    directly as mul's incremental value. A hit on a name that several
        //    entities share is kept but segregated, since which QID it resolves
        //    to is an artifact of dump order rather than evidence.
        let mul_hit = mul_dict.and_then(|d| {
            d.get(link_target)
                .map(|qid| (link_target, qid))
                .or_else(|| d.get(&cap_target).map(|qid| (cap_target.as_str(), qid)))
        });
        if let Some((matched, qid)) = mul_hit {
            if mul_ambiguous.contains(matched) {
                writeln!(mul_amb_out, "{src_qid}\t{qid}")?;
                mul_amb_count += 1;
            } else {
                writeln!(mul_out, "{src_qid}\t{qid}")?;
                mul_count += 1;
            }
            converted += 1;
            continue;
        }

        // i. Best-label fallback
        if let Some(qid) = best_dict.and_then(|d| d.get(link_target)) {
            writeln!(best_out, "{src_qid}\t{qid}")?;
            converted += 1;
            continue;
        }
        if let Some(qid) = best_dict.and_then(|d| d.get(&cap_target)) {
            writeln!(best_out, "{src_qid}\t{qid}")?;
            converted += 1;
            continue;
        }

        // j. Wiktionary link
        if link_target.starts_with("Wikt:") || link_target.starts_with("wikt:") {
            wikt_count += 1;
            continue;
        }

        // k. Failure
        match (
            sanitize_diag_field(link_target),
            sanitize_diag_field(&original_link),
        ) {
            (Some(target), Some(original)) => {
                writeln!(failed_out, "{src_qid}\t{target}\t{original}")?;
            }
            _ => len_rejected += 1,
        }
        failed += 1;
    }

    log::info!(
        "[{lang}] Done. total={count}, converted={converted}, failed={failed}, \
         wikt={wikt_count}, mul={mul_count}, mul_ambiguous={mul_amb_count}, \
         len_rejected={len_rejected}"
    );
    Ok(())
}

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run");

    let languages = languages::load_languages(run_dir, "wikipedia")?;
    log::info!("Processing {} Wikipedia languages", languages.len());

    let (qid_dict, mul_ambiguous) = load_qid_dict(run_dir, 80)?;
    let commons_files = load_commons_files(&run_dir.join("commons_files.txt"))?;

    let num_workers = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .max(1);

    log::info!("Using {num_workers} worker threads for {} languages", languages.len());

    thread::scope(|s| {
        let (tx, rx) = bounded::<&str>(num_workers * 2);

        let mut handles = Vec::with_capacity(num_workers);
        for _ in 0..num_workers {
            let rx = rx.clone();
            let qid_dict = &qid_dict;
            let commons_files = &commons_files;
            let mul_ambiguous = &mul_ambiguous;
            handles.push(s.spawn(move || -> Result<()> {
                for lang in rx {
                    log::info!("[{lang}] Starting link conversion");
                    process_language(lang, run_dir, qid_dict, commons_files, mul_ambiguous, 5)?;
                }
                Ok(())
            }));
        }
        drop(rx);

        for lang in &languages {
            tx.send(lang.as_str()).unwrap();
        }
        drop(tx);

        for handle in handles {
            handle.join().unwrap()?;
        }

        Ok(())
    })
}
