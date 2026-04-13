use anyhow::Result;
use clap::Parser;
use crossbeam_channel::bounded;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use std::io::{self, BufWriter, Write};
use std::path::Path;
use std::thread;

#[derive(Parser)]
struct Args {
    /// Language code (e.g., 'en', 'de')
    lang: String,
}

/// A complete parsed page ready for worker processing.
struct Page {
    title: String,
    redirect_target: Option<String>,
    text: String,
}

/// Output produced by a worker for one page.
enum PageOutput {
    Redirect { title: String, target: String },
    Links { title: String, links: Vec<String> },
}

fn extract_wikilinks(text: &str) -> Vec<String> {
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

        links.push(target.to_string());
    }

    links
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();
    let lang = args.lang.clone();
    let run_dir = Path::new("run/wkt");
    std::fs::create_dir_all(run_dir)?;

    let num_workers = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .max(2)
        - 1;
    let num_workers = num_workers.max(1);

    log::info!("[{lang}] Starting with {num_workers} worker threads");

    // Channel: reader -> workers (parsed pages)
    let (page_tx, page_rx) = bounded::<Page>(num_workers * 64);

    // Channel: workers -> writer (processed output)
    let (out_tx, out_rx) = bounded::<PageOutput>(num_workers * 64);

    // Spawn worker threads
    let mut worker_handles = Vec::with_capacity(num_workers);
    for _ in 0..num_workers {
        let page_rx = page_rx.clone();
        let out_tx = out_tx.clone();

        let handle = thread::spawn(move || {
            for page in page_rx {
                let output = if let Some(target) = page.redirect_target {
                    PageOutput::Redirect {
                        title: page.title,
                        target,
                    }
                } else {
                    PageOutput::Links {
                        title: page.title,
                        links: extract_wikilinks(&page.text),
                    }
                };

                if out_tx.send(output).is_err() {
                    break;
                }
            }
        });
        worker_handles.push(handle);
    }
    drop(out_tx);

    // Spawn writer thread
    let writer_lang = lang.clone();
    let writer_run_dir = run_dir.to_path_buf();
    let writer_handle = thread::spawn(move || -> Result<()> {
        let links_path = writer_run_dir.join(format!("{}_wikilinks.txt", writer_lang));
        let redirects_path = writer_run_dir.join(format!("{}_redirects.txt", writer_lang));

        let mut links_out = BufWriter::new(std::fs::File::create(&links_path)?);
        let mut redirects_out = BufWriter::new(std::fs::File::create(&redirects_path)?);

        let mut count = 0u64;
        for output in out_rx {
            match output {
                PageOutput::Redirect { title, target } => {
                    // Wiktionary: strip whitespace from source and target
                    writeln!(redirects_out, "{}\t{}", title.trim(), target.trim())?;
                }
                PageOutput::Links { title, links } => {
                    for link in links {
                        writeln!(links_out, "{}\t{}", title.trim(), link.trim())?;
                    }
                }
            }

            count += 1;
            if count % 500_000 == 0 {
                log::info!("[{writer_lang}] Written {count} pages");
            }
        }

        links_out.flush()?;
        redirects_out.flush()?;

        log::info!("[{writer_lang}] Done. Written {count} pages total.");
        Ok(())
    });

    // Reader: main thread parses XML and dispatches pages
    let mut reader = Reader::from_reader(io::BufReader::new(io::stdin().lock()));
    reader.config_mut().trim_text(true);

    let mut in_page = false;
    let mut in_title = false;
    let mut in_ns = false;
    let mut in_text = false;
    let mut page_title = String::new();
    let mut page_ns = String::new();
    let mut page_text = String::new();
    let mut redirect_target: Option<String> = None;
    let mut buf = Vec::new();

    loop {
        buf.clear();
        match reader.read_event_into(&mut buf) {
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

                        let page = Page {
                            title: std::mem::take(&mut page_title),
                            redirect_target: redirect_target.take(),
                            text: std::mem::take(&mut page_text),
                        };

                        if page_tx.send(page).is_err() {
                            break;
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                log::warn!("[{lang}] XML parse error: {e}");
                break;
            }
            _ => {}
        }
    }

    drop(page_tx);

    for handle in worker_handles {
        handle.join().expect("worker thread panicked");
    }

    writer_handle.join().expect("writer thread panicked")?;

    Ok(())
}
