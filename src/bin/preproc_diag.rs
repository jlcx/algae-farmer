//! Diagnostic for the template-aware link extractor.
//!
//! Reads a pages-articles XML stream (same shape as wp_preproc / wkt_preproc),
//! and for each article page reports the *delta* between the old `[[...]]`-only
//! extraction and the new template-aware extraction — i.e. link targets that
//! the template pass adds beyond what the wikilink regex already finds.
//!
//! Per-delta lines go to stdout: `<page-title>\t<template-name>\t<target>`
//! Aggregate counts go to stderr at the end.

use algae_farmer::wikitext::{
    normalize_link_target, normalize_name, parse_templates, wkt_template_links, wp_template_links,
};
use anyhow::{Result, bail};
use clap::Parser;
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::io::{self, BufWriter, Write};

#[derive(Clone, Copy)]
enum Mode {
    Wp,
    Wkt,
}

#[derive(Parser)]
struct Args {
    /// Template handler to use: "wp" or "wkt".
    mode: String,
    /// Stop after this many article pages have been processed.
    #[arg(long)]
    limit: Option<u64>,
    /// Suppress per-page delta lines on stdout; only print the summary.
    #[arg(long)]
    summary_only: bool,
}

fn wikilink_targets(re: &Regex, text: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    for cap in re.captures_iter(text) {
        let inner = &cap[1];
        if inner.contains("{{") || inner.contains("}}") {
            continue;
        }
        let target = inner.split('|').next().unwrap_or("");
        if let Some(clean) = normalize_link_target(target) {
            out.insert(clean.to_string());
        }
    }
    out
}

fn template_targets(text: &str, mode: Mode) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for tmpl in parse_templates(text) {
        let targets = match mode {
            Mode::Wp => wp_template_links(&tmpl),
            Mode::Wkt => wkt_template_links(&tmpl),
        };
        for t in targets {
            if let Some(clean) = normalize_link_target(t) {
                out.push((tmpl.name.to_string(), clean.to_string()));
            }
        }
    }
    out
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mode = match args.mode.as_str() {
        "wp" => Mode::Wp,
        "wkt" => Mode::Wkt,
        other => bail!("mode must be 'wp' or 'wkt', got {other:?}"),
    };

    let re = Regex::new(r"\[\[([^\[\]]*)\]\]")?;

    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());

    let mut reader = Reader::from_reader(io::BufReader::new(io::stdin().lock()));
    reader.config_mut().trim_text(true);

    let mut in_page = false;
    let mut in_title = false;
    let mut in_ns = false;
    let mut in_text = false;
    let mut page_title = String::new();
    let mut page_ns = String::new();
    let mut page_text = String::new();
    let mut is_redirect = false;
    let mut buf = Vec::new();

    let mut pages_processed: u64 = 0;
    let mut total_wikilinks: u64 = 0;
    let mut total_template_links: u64 = 0;
    let mut total_delta: u64 = 0;
    let mut per_template_delta: HashMap<String, u64> = HashMap::new();

    'pages: loop {
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
                        is_redirect = false;
                    }
                    b"title" if in_page => in_title = true,
                    b"ns" if in_page => in_ns = true,
                    b"text" if in_page => in_text = true,
                    b"redirect" if in_page => is_redirect = true,
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
                        if !is_redirect && (ns == 0 || ns == 14) {
                            let wikilinks = wikilink_targets(&re, &page_text);
                            let tmpl_links = template_targets(&page_text, mode);

                            total_wikilinks += wikilinks.len() as u64;
                            total_template_links += tmpl_links.len() as u64;

                            for (tmpl_name, target) in &tmpl_links {
                                if !wikilinks.contains(target) {
                                    total_delta += 1;
                                    *per_template_delta
                                        .entry(normalize_name(tmpl_name))
                                        .or_insert(0) += 1;
                                    if !args.summary_only {
                                        writeln!(out, "{page_title}\t{tmpl_name}\t{target}")?;
                                    }
                                }
                            }

                            pages_processed += 1;
                            if let Some(limit) = args.limit {
                                if pages_processed >= limit {
                                    break 'pages;
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                eprintln!("XML parse error: {e}");
                break;
            }
            _ => {}
        }
    }

    out.flush()?;

    let mut top: Vec<(String, u64)> = per_template_delta.into_iter().collect();
    top.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));

    let stderr = io::stderr();
    let mut err = stderr.lock();
    writeln!(err, "--- preproc_diag summary ({}) ---", args.mode)?;
    writeln!(err, "pages processed:           {pages_processed}")?;
    writeln!(err, "[[...]] links (deduped):   {total_wikilinks}")?;
    writeln!(err, "template-derived links:    {total_template_links}")?;
    writeln!(err, "delta (template - wikilink): {total_delta}")?;
    if total_wikilinks > 0 {
        let pct = (total_delta as f64 / total_wikilinks as f64) * 100.0;
        writeln!(err, "delta as % of wikilinks:   {pct:.2}%")?;
    }
    writeln!(err, "")?;
    writeln!(err, "top templates by delta:")?;
    for (name, count) in top.iter().take(30) {
        writeln!(err, "  {count:>10}  {name}")?;
    }

    Ok(())
}
