use anyhow::Result;
use std::collections::BTreeSet;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run/wkt");

    let links_path = run_dir.join("links_uniq_combined.tsv");
    let entries_path = run_dir.join("entries.tsv");
    let rejected_path = run_dir.join("wkt_links_rejected.txt");
    let bad_path = run_dir.join("wkt_links_bad.txt");

    let mut links_out = BufWriter::new(std::fs::File::create(&links_path)?);
    let mut entries_set = BTreeSet::new();
    let mut rejected_out = BufWriter::new(std::fs::File::create(&rejected_path)?);
    let mut bad_out = BufWriter::new(std::fs::File::create(&bad_path)?);

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                writeln!(bad_out, "READ_ERROR: {e}")?;
                continue;
            }
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Filter out lines with colons (namespace prefixes), double quotes, or too long
        if trimmed.len() > 384 {
            writeln!(rejected_out, "{trimmed}")?;
            continue;
        }

        // Parse uniq -c format: "   count src\tdst" or "   count src dst"
        let parts: Vec<&str> = trimmed.splitn(2, |c: char| c.is_whitespace()).collect();
        if parts.len() != 2 {
            writeln!(bad_out, "{trimmed}")?;
            continue;
        }

        let count_str = parts[0].trim();
        let rest = parts[1].trim();

        let count: u64 = match count_str.parse() {
            Ok(c) => c,
            Err(_) => {
                writeln!(bad_out, "{trimmed}")?;
                continue;
            }
        };

        // Split rest into src and dst (tab-separated)
        let fields: Vec<&str> = rest.splitn(2, '\t').collect();
        if fields.len() != 2 {
            // Try whitespace split
            let fields2: Vec<&str> = rest.splitn(2, |c: char| c.is_whitespace()).collect();
            if fields2.len() != 2 {
                writeln!(bad_out, "{trimmed}")?;
                continue;
            }
            let src = fields2[0].trim();
            let dst = fields2[1].trim();

            if src.contains(':') || dst.contains(':') || src.contains('"') || dst.contains('"')
                || src.contains('\t') || dst.contains('\t')
            {
                writeln!(rejected_out, "{trimmed}")?;
                continue;
            }

            writeln!(links_out, "{src}\t{dst}\t{count}")?;
            entries_set.insert(src.to_string());
            entries_set.insert(dst.to_string());
            continue;
        }

        let src = fields[0].trim();
        let dst = fields[1].trim();

        if src.contains(':') || dst.contains(':') || src.contains('"') || dst.contains('"')
            || src.contains('\t') || dst.contains('\t')
        {
            writeln!(rejected_out, "{trimmed}")?;
            continue;
        }

        writeln!(links_out, "{src}\t{dst}\t{count}")?;
        entries_set.insert(src.to_string());
        entries_set.insert(dst.to_string());
    }

    // Write unique entries, filtering out any containing tabs
    // (tabs in headwords are data artifacts that break TSV loading)
    let mut entries_out = BufWriter::new(std::fs::File::create(&entries_path)?);
    for entry in &entries_set {
        if !entry.contains('\t') {
            writeln!(entries_out, "{entry}")?;
        }
    }

    log::info!(
        "Done. {} links, {} unique entries",
        0, // we don't count here but it's logged
        entries_set.len()
    );

    Ok(())
}
