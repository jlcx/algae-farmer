use anyhow::Result;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use std::collections::BTreeSet;
use std::io::{self, BufWriter, Write};
use std::path::Path;

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run/aw");
    std::fs::create_dir_all(run_dir)?;

    let entries_path = run_dir.join("entries.tsv");
    let refs_path = run_dir.join("refs.tsv");

    let mut entries_out = BufWriter::new(std::fs::File::create(&entries_path)?);
    let mut refs_out = BufWriter::new(std::fs::File::create(&refs_path)?);

    // Accept titles that are bare QIDs (main-namespace abstract articles).
    let title_re = Regex::new(r"^Q\d+$").unwrap();
    // K-suffix is not part of the match, so "Z825K1" is captured as "Z825".
    let ref_re = Regex::new(r"[QZ]\d+").unwrap();

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
                        writeln!(entries_out, "{title}")?;
                        let mut seen: BTreeSet<&str> = BTreeSet::new();
                        for m in ref_re.find_iter(&page_text) {
                            if seen.insert(m.as_str()) {
                                writeln!(refs_out, "{title}\t{}", m.as_str())?;
                            }
                        }
                        processed += 1;
                        if processed % 10_000 == 0 {
                            log::info!("Processed {processed} pages");
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

    entries_out.flush()?;
    refs_out.flush()?;
    log::info!("Done. {processed} main-namespace pages processed");
    Ok(())
}
