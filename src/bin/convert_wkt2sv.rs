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

    // Input is `sort $FILES | uniq -c`, so lines arrive ordered by the raw
    // SRC\tDST key. Two raw lines that differ only in trim-equivalent whitespace
    // land adjacent, and after our own trim they collapse to the same (src, dst).
    // Sum their counts into one row so downstream doesn't see duplicate PKs.
    let mut pending: Option<(String, String, u64)> = None;

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

        if trimmed.len() > 384 {
            writeln!(rejected_out, "{trimmed}")?;
            continue;
        }

        // Parse uniq -c format: "   count src\tdst" (whitespace-separated count,
        // tab-separated fields; fall back to whitespace split if no tab).
        let parts: Vec<&str> = trimmed.splitn(2, |c: char| c.is_whitespace()).collect();
        if parts.len() != 2 {
            writeln!(bad_out, "{trimmed}")?;
            continue;
        }

        let count: u64 = match parts[0].trim().parse() {
            Ok(c) => c,
            Err(_) => {
                writeln!(bad_out, "{trimmed}")?;
                continue;
            }
        };

        let rest = parts[1].trim();
        let (src, dst) = {
            let tab_fields: Vec<&str> = rest.splitn(2, '\t').collect();
            if tab_fields.len() == 2 {
                (tab_fields[0].trim(), tab_fields[1].trim())
            } else {
                let ws_fields: Vec<&str> =
                    rest.splitn(2, |c: char| c.is_whitespace()).collect();
                if ws_fields.len() != 2 {
                    writeln!(bad_out, "{trimmed}")?;
                    continue;
                }
                (ws_fields[0].trim(), ws_fields[1].trim())
            }
        };

        if src.contains(':') || dst.contains(':') || src.contains('"') || dst.contains('"')
            || src.contains('\t') || dst.contains('\t')
        {
            writeln!(rejected_out, "{trimmed}")?;
            continue;
        }

        match pending.as_mut() {
            Some((psrc, pdst, pcount)) if psrc == src && pdst == dst => {
                *pcount += count;
            }
            _ => {
                if let Some((psrc, pdst, pcount)) = pending.take() {
                    writeln!(links_out, "{psrc}\t{pdst}\t{pcount}")?;
                    entries_set.insert(psrc);
                    entries_set.insert(pdst);
                }
                pending = Some((src.to_string(), dst.to_string(), count));
            }
        }
    }

    if let Some((psrc, pdst, pcount)) = pending.take() {
        writeln!(links_out, "{psrc}\t{pdst}\t{pcount}")?;
        entries_set.insert(psrc);
        entries_set.insert(pdst);
    }

    // Write unique entries, filtering out any containing tabs
    // (tabs in headwords are data artifacts that break TSV loading)
    let mut entries_out = BufWriter::new(std::fs::File::create(&entries_path)?);
    for entry in &entries_set {
        if !entry.contains('\t') {
            writeln!(entries_out, "{entry}")?;
        }
    }

    log::info!("Done. {} unique entries", entries_set.len());

    Ok(())
}
