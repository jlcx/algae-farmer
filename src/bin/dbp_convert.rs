use anyhow::Result;
use clap::Parser;
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::Path;

#[derive(Parser)]
struct Args {
    /// Language code (e.g., 'en', 'de')
    lang: String,
}

fn load_qid_dict_for_lang(
    labels_path: &Path,
    lang: &str,
) -> Result<HashMap<String, String>> {
    let mut dict = HashMap::new();
    let file = std::fs::File::open(labels_path)?;
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
        if parts[0] == lang {
            dict.insert(parts[1].to_string(), parts[2].to_string());
        }
    }
    Ok(dict)
}

fn extract_resource_name(uri: &str) -> Option<String> {
    // Extract last path segment from URI and replace underscores with spaces
    let trimmed = uri.trim_start_matches('<').trim_end_matches('>');
    let last_segment = trimmed.rsplit('/').next()?;
    // URL-decode common patterns
    let decoded = urlencoding::decode(last_segment).ok()?;
    Some(decoded.replace('_', " "))
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();
    let run_dir = Path::new("run");
    let dbp_dir = run_dir.join("dbp");
    std::fs::create_dir_all(&dbp_dir)?;

    let labels_path = run_dir.join("wd_labels.tsv");
    log::info!("[{}] Loading QID dictionary...", args.lang);
    let qid_dict = load_qid_dict_for_lang(&labels_path, &args.lang)?;
    log::info!(
        "[{}] Loaded {} title->QID mappings",
        args.lang,
        qid_dict.len()
    );

    let output_path = dbp_dir.join(format!("dbp_mappings_{}.tsv", args.lang));
    let mut out = BufWriter::new(std::fs::File::create(&output_path)?);

    let stdin = io::stdin();
    let mut count = 0u64;
    let mut resolved = 0u64;

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        let trimmed = line.trim();
        // Skip comments and empty lines
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('@') {
            continue;
        }

        // Parse Turtle triple: subject predicate object .
        let parts: Vec<&str> = trimmed.splitn(4, ' ').collect();
        if parts.len() < 3 {
            continue;
        }

        let subject = parts[0];
        let predicate = parts[1];
        let object = parts[2];

        count += 1;

        let src_name = match extract_resource_name(subject) {
            Some(n) => n,
            None => continue,
        };
        let dst_name = match extract_resource_name(object) {
            Some(n) => n,
            None => continue,
        };

        let src_qid = match qid_dict.get(&src_name) {
            Some(q) => q,
            None => continue,
        };
        let dst_qid = match qid_dict.get(&dst_name) {
            Some(q) => q,
            None => continue,
        };

        writeln!(out, "{src_qid}\t{dst_qid}\t{predicate}")?;
        resolved += 1;
    }

    log::info!(
        "[{}] Done. Parsed {} triples, resolved {} to QIDs.",
        args.lang,
        count,
        resolved
    );
    Ok(())
}
