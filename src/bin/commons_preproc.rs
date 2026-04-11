use std::io::{self, BufRead, Write};

/// Reads Commons multistream index from stdin (format: offset:page_id:title).
/// Outputs one filename per line to stdout.
fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Format: offset:page_id:title
        // Title is the third field (everything after the second colon)
        let mut parts = line.splitn(3, ':');
        let _offset = parts.next();
        let _page_id = parts.next();
        if let Some(title) = parts.next() {
            let _ = writeln!(out, "{title}");
        }
    }
}
