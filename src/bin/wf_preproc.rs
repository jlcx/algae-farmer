use anyhow::Result;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use serde_json::Value;
use std::collections::HashSet;
use std::io::{self, BufWriter, Write};
use std::path::Path;

fn sanitize(s: &str) -> String {
    // Keep label text safe for `COPY ... WITH (FORMAT csv, DELIMITER E'\t')`.
    // Tabs/newlines/CR collide with the delimiter; `"` would need CSV doubling.
    s.chars()
        .map(|c| match c {
            '\t' | '\n' | '\r' | '"' => ' ',
            _ => c,
        })
        .collect::<String>()
        .trim()
        .to_string()
}

/// Walk `Z2K3 -> Z12K1` → (lang, label) pairs; `Z2K4 -> Z32K1` → (lang, alias) pairs.
/// First array element is a type header ("Z11" or "Z31"), skip it.
fn emit_labels(
    root: &Value,
    zid: &str,
    out: &mut impl Write,
) -> Result<()> {
    let mut seen: HashSet<(String, char, String)> = HashSet::new();

    if let Some(arr) = root
        .get("Z2K3")
        .and_then(|v| v.get("Z12K1"))
        .and_then(|v| v.as_array())
    {
        for item in arr.iter().skip(1) {
            let lang = item.get("Z11K1").and_then(|v| v.as_str()).unwrap_or("");
            let label = item.get("Z11K2").and_then(|v| v.as_str()).unwrap_or("");
            if lang.is_empty() || label.is_empty() {
                continue;
            }
            let label = sanitize(label);
            if label.is_empty() {
                continue;
            }
            if seen.insert((lang.to_string(), 'L', label.clone())) {
                writeln!(out, "{zid}\t{lang}\tL\t{label}")?;
            }
        }
    }

    if let Some(arr) = root
        .get("Z2K4")
        .and_then(|v| v.get("Z32K1"))
        .and_then(|v| v.as_array())
    {
        for item in arr.iter().skip(1) {
            let lang = item.get("Z31K1").and_then(|v| v.as_str()).unwrap_or("");
            if lang.is_empty() {
                continue;
            }
            let aliases = match item.get("Z31K2").and_then(|v| v.as_array()) {
                Some(a) => a,
                None => continue,
            };
            // First element is the list type tag ("Z6"); the rest are alias strings.
            for alias in aliases.iter().skip(1) {
                let s = match alias.as_str() {
                    Some(s) => s,
                    None => continue,
                };
                let s = sanitize(s);
                if s.is_empty() {
                    continue;
                }
                if seen.insert((lang.to_string(), 'A', s.clone())) {
                    writeln!(out, "{zid}\t{lang}\tA\t{s}")?;
                }
            }
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run/wf");
    std::fs::create_dir_all(run_dir)?;

    let objects_path = run_dir.join("objects.tsv");
    let labels_path = run_dir.join("labels.tsv");
    let bad_path = run_dir.join("wf_bad.txt");

    let mut objects_out = BufWriter::new(std::fs::File::create(&objects_path)?);
    let mut labels_out = BufWriter::new(std::fs::File::create(&labels_path)?);
    let mut bad_out = BufWriter::new(std::fs::File::create(&bad_path)?);

    let title_re = Regex::new(r"^Z\d+$").unwrap();

    let mut reader = Reader::from_reader(io::BufReader::new(io::stdin().lock()));
    reader.config_mut().trim_text(true);

    let mut in_page = false;
    let mut in_title = false;
    let mut in_ns = false;
    let mut in_text = false;
    let mut page_title = String::new();
    let mut page_ns = String::new();
    let mut page_text = String::new();
    let mut buf = Vec::new();

    let mut processed = 0u64;

    loop {
        buf.clear();
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                match e.local_name().as_ref() {
                    b"page" => {
                        in_page = true;
                        page_title.clear();
                        page_ns.clear();
                        page_text.clear();
                    }
                    b"title" if in_page => in_title = true,
                    b"ns" if in_page => in_ns = true,
                    b"text" if in_page => in_text = true,
                    _ => {}
                }
            }
            Ok(Event::Text(e)) => {
                let s = e.unescape().unwrap_or_default();
                if in_title {
                    page_title.push_str(&s);
                } else if in_ns {
                    page_ns.push_str(&s);
                } else if in_text {
                    page_text.push_str(&s);
                }
            }
            Ok(Event::End(e)) => match e.local_name().as_ref() {
                b"title" => in_title = false,
                b"ns" => in_ns = false,
                b"text" => in_text = false,
                b"page" => {
                    in_page = false;
                    let ns: i32 = page_ns.trim().parse().unwrap_or(-1);
                    let title = page_title.trim();
                    if ns == 0 && title_re.is_match(title) {
                        writeln!(objects_out, "{title}")?;
                        match serde_json::from_str::<Value>(&page_text) {
                            Ok(root) => {
                                emit_labels(&root, title, &mut labels_out)?;
                            }
                            Err(e) => {
                                writeln!(bad_out, "{title}\t{e}")?;
                            }
                        }
                        processed += 1;
                        if processed % 10_000 == 0 {
                            log::info!("Processed {processed} Z-objects");
                        }
                    }
                }
                _ => {}
            },
            Ok(Event::Eof) => break,
            Err(e) => {
                log::warn!("XML parse error: {e}");
                break;
            }
            _ => {}
        }
    }

    objects_out.flush()?;
    labels_out.flush()?;
    bad_out.flush()?;
    log::info!("Done. {processed} Z-objects processed");
    Ok(())
}
