use anyhow::Result;
use clap::Parser;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use std::io::{self, BufWriter, Read, Write};
use std::path::Path;

#[derive(Parser)]
struct Args {
    /// Language code (e.g., 'en', 'de')
    lang: String,
}

fn extract_wikilinks(text: &str) -> Vec<(String, String)> {
    let re = Regex::new(r"\[\[([^\[\]]*)\]\]").unwrap();
    let mut links = Vec::new();

    for cap in re.captures_iter(text) {
        let inner = &cap[1];
        if inner.contains("{{") || inner.contains("}}") {
            continue;
        }

        let target = if let Some(pipe_pos) = inner.find('|') {
            &inner[..pipe_pos]
        } else {
            inner
        };

        let target = target.trim();
        if target.is_empty() {
            continue;
        }

        // Skip namespace-prefixed links
        if let Some(colon_pos) = target.find(':') {
            if colon_pos > 0 {
                let prefix = &target[..colon_pos];
                let skip_prefixes = [
                    "Category", "File", "Image", "Wikipedia", "WP", "Template",
                    "Help", "Portal", "Draft", "MediaWiki", "Module", "Talk",
                    "User", "Special",
                ];
                if skip_prefixes.iter().any(|p| p.eq_ignore_ascii_case(prefix)) {
                    continue;
                }
            }
        }

        links.push((String::new(), target.to_string()));
    }

    links
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();
    let run_dir = Path::new("run/wkt");
    std::fs::create_dir_all(run_dir)?;

    let links_path = run_dir.join(format!("{}_wikilinks.txt", args.lang));
    let redirects_path = run_dir.join(format!("{}_redirects.txt", args.lang));

    let mut links_out = BufWriter::new(std::fs::File::create(&links_path)?);
    let mut redirects_out = BufWriter::new(std::fs::File::create(&redirects_path)?);

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    let mut reader = Reader::from_str(&input);
    reader.config_mut().trim_text(true);

    let mut in_page = false;
    let mut in_title = false;
    let mut in_ns = false;
    let mut in_text = false;

    let mut page_title = String::new();
    let mut page_ns = String::new();
    let mut page_text = String::new();
    let mut redirect_target: Option<String> = None;
    let mut page_count = 0u64;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                let local = e.local_name();
                match local.as_ref() {
                    b"page" => {
                        in_page = true;
                        page_title.clear();
                        page_ns.clear();
                        page_text.clear();
                        redirect_target = None;
                    }
                    b"title" if in_page => in_title = true,
                    b"ns" if in_page => in_ns = true,
                    b"text" if in_page => in_text = true,
                    b"redirect" if in_page => {
                        for attr in e.attributes().flatten() {
                            if attr.key.as_ref() == b"title" {
                                redirect_target =
                                    Some(String::from_utf8_lossy(&attr.value).to_string());
                            }
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Text(e)) => {
                if in_title {
                    page_title.push_str(&e.unescape().unwrap_or_default());
                } else if in_ns {
                    page_ns.push_str(&e.unescape().unwrap_or_default());
                } else if in_text {
                    page_text.push_str(&e.unescape().unwrap_or_default());
                }
            }
            Ok(Event::End(e)) => {
                let local = e.local_name();
                match local.as_ref() {
                    b"title" => in_title = false,
                    b"ns" => in_ns = false,
                    b"text" => in_text = false,
                    b"page" => {
                        in_page = false;
                        let ns: i32 = page_ns.parse().unwrap_or(-1);
                        if ns != 0 && ns != 14 {
                            continue;
                        }

                        let title = page_title.trim().to_string();

                        if let Some(ref target) = redirect_target {
                            writeln!(redirects_out, "{}\t{}", title, target.trim())?;
                        } else {
                            let links = extract_wikilinks(&page_text);
                            for (_, link_target) in links {
                                // Wiktionary: strip whitespace from source and target
                                writeln!(
                                    links_out,
                                    "{}\t{}",
                                    title.trim(),
                                    link_target.trim()
                                )?;
                            }
                        }

                        page_count += 1;
                        if page_count % 500_000 == 0 {
                            log::info!("[{}] Processed {page_count} pages", args.lang);
                        }

                        page_title.clear();
                        page_ns.clear();
                        page_text.clear();
                        redirect_target = None;
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                log::warn!("XML parse error: {e}");
                break;
            }
            _ => {}
        }
    }

    log::info!("[{}] Done. Processed {page_count} pages.", args.lang);
    Ok(())
}
