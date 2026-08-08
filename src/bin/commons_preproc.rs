use std::io::{self, BufRead, Write};

/// Reads the Commons namespace-6 title list from stdin, one title per line.
///
/// Source: `other/mediatitles/<date>/commonswiki-<date>-all-titles-in-ns-6.gz`.
/// This replaces the multistream index that came with the retired XML dumps;
/// titles arrive in database form (underscores, no `File:` prefix) behind a
/// single `page_title` header line.
///
/// Outputs one filename per line to stdout, in display form (spaces), which is
/// how link targets appear in wikitext.
fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    let mut first = true;
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        if first {
            first = false;
            if line == "page_title" {
                continue;
            }
        }
        if line.is_empty() {
            continue;
        }
        let _ = writeln!(out, "{}", line.replace('_', " "));
    }
}
