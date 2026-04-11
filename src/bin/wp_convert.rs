use anyhow::Result;
use clap::Parser;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use sysinfo::System;

#[derive(Parser)]
struct Args {
    /// Language code to process (e.g., 'en', 'de')
    lang: String,

    /// Maximum redirect chain depth
    #[arg(long, default_value = "5")]
    max_redirect_depth: usize,

    /// Memory ceiling as percentage of available RAM (0-100)
    #[arg(long, default_value = "80")]
    memory_ceiling: u8,
}

type QidDict = HashMap<String, HashMap<String, String>>;

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

fn load_qid_dict(run_dir: &Path, memory_ceiling: u8) -> Result<QidDict> {
    let labels_path = run_dir.join("wd_labels.tsv");
    let mut dict: QidDict = HashMap::new();

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

        dict.entry(lang.to_string())
            .or_default()
            .insert(title.to_string(), qid.to_string());
    }

    let used_mem = sys.used_memory();
    log::info!(
        "Loaded wd_labels.tsv in-memory ({} languages, ~{} MB used)",
        dict.len(),
        used_mem / 1_048_576
    );

    Ok(dict)
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

fn resolve_redirect(
    title: &str,
    redirects: &HashMap<String, String>,
    max_depth: usize,
) -> (Option<String>, bool) {
    let mut current = title.to_string();
    let mut visited = HashSet::new();

    for _ in 0..max_depth {
        if visited.contains(&current) {
            return (None, true); // cycle
        }
        visited.insert(current.clone());
        match redirects.get(&current) {
            Some(target) => current = target.clone(),
            None => return (Some(current), false),
        }
    }
    (None, true) // exceeded depth
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();
    let run_dir = Path::new("run");

    let qid_dict = load_qid_dict(run_dir, args.memory_ceiling)?;
    let commons_files = load_commons_files(&run_dir.join("commons_files.txt"))?;

    let lang = &args.lang;
    let wikilinks_path = run_dir.join(format!("{lang}_wikilinks.txt"));
    let redirects_path = run_dir.join(format!("{lang}_redirects.txt"));

    let redirects = load_redirects(&redirects_path)?;

    let converted_path = run_dir.join(format!("{lang}_links_converted.txt"));
    let failed_path = run_dir.join(format!("{lang}_conv_failed.txt"));
    let commons_path = run_dir.join(format!("{lang}_commons.txt"));
    let best_path = run_dir.join(format!("{lang}_best_guesses.txt"));
    let src_not_found_path = run_dir.join(format!("{lang}_src_not_found.txt"));
    let chain_exceeded_path = run_dir.join(format!("{lang}_redirect_chain_exceeded.txt"));

    let mut converted_out = BufWriter::new(std::fs::File::create(&converted_path)?);
    let mut failed_out = BufWriter::new(std::fs::File::create(&failed_path)?);
    let mut commons_out = BufWriter::new(std::fs::File::create(&commons_path)?);
    let mut best_out = BufWriter::new(std::fs::File::create(&best_path)?);
    let mut src_not_found_out = BufWriter::new(std::fs::File::create(&src_not_found_path)?);
    let mut chain_exceeded_out = BufWriter::new(std::fs::File::create(&chain_exceeded_path)?);

    let lang_dict = qid_dict.get(lang);
    let best_dict = qid_dict.get("best");

    let wikilinks_file = std::fs::File::open(&wikilinks_path)?;
    let reader = BufReader::new(wikilinks_file);

    let mut count = 0u64;
    let mut converted = 0u64;
    let mut failed = 0u64;
    let mut wikt_count = 0u64;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let parts: Vec<&str> = line.splitn(2, '\t').collect();
        if parts.len() != 2 {
            continue;
        }
        let source_title = parts[0];
        let link_target = parts[1];

        count += 1;

        // Source lookup
        let src_qid = match lang_dict.and_then(|d| d.get(source_title)) {
            Some(q) => q.clone(),
            None => {
                writeln!(src_not_found_out, "{source_title}")?;
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
            let (resolved_title, exceeded) =
                resolve_redirect(try_target, &redirects, args.max_redirect_depth);
            if exceeded {
                writeln!(chain_exceeded_out, "{try_target}")?;
            }
            if let Some(title) = resolved_title {
                if &title != try_target {
                    if let Some(qid) = lang_dict.and_then(|d| d.get(&title)) {
                        writeln!(converted_out, "{src_qid}\t{qid}")?;
                        converted += 1;
                        resolved = true;
                        break;
                    }
                    // Also try capfirst of resolved title
                    let cap_resolved = capfirst(&title);
                    if let Some(qid) = lang_dict.and_then(|d| d.get(&cap_resolved)) {
                        writeln!(converted_out, "{src_qid}\t{qid}")?;
                        converted += 1;
                        resolved = true;
                        break;
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

            if (prefix == "d" || prefix == "D") && is_qid(suffix) {
                writeln!(converted_out, "{src_qid}\t{}", suffix.to_uppercase())?;
                converted += 1;
                continue;
            }

            // g. Cross-language title lookup
            if let Some(cross_dict) = qid_dict.get(prefix) {
                if let Some(qid) = cross_dict.get(suffix) {
                    writeln!(converted_out, "{src_qid}\t{qid}")?;
                    converted += 1;
                    continue;
                }
                let cap_suffix = capfirst(suffix);
                if let Some(qid) = cross_dict.get(&cap_suffix) {
                    writeln!(converted_out, "{src_qid}\t{qid}")?;
                    converted += 1;
                    continue;
                }
            }
        }

        // h. Best-label fallback
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

        // i. Wiktionary link
        if link_target.starts_with("Wikt:") || link_target.starts_with("wikt:") {
            wikt_count += 1;
            continue;
        }

        // j. Failure
        writeln!(failed_out, "{src_qid}\t{link_target}\t{original_link}")?;
        failed += 1;
    }

    log::info!(
        "[{lang}] Done. total={count}, converted={converted}, failed={failed}, wikt={wikt_count}"
    );
    Ok(())
}
