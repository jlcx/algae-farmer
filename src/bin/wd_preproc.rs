use algae_farmer::constants;
use algae_farmer::languages;
use anyhow::Result;
use crossbeam_channel::bounded;
use serde_json::Value;
use std::collections::HashSet;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;
use std::sync::Arc;
use std::thread;

/// Output lines produced by processing a single entity.
struct EntityOutput {
    items_line: String,
    labels_lines: String,
    links_lines: String,
    dates_lines: String,
}

fn csv_quote(s: &str) -> String {
    if s.contains('"') || s.contains(',') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn extract_qid(value: &Value) -> Option<&str> {
    value
        .get("mainsnak")?
        .get("datavalue")?
        .get("value")?
        .get("id")?
        .as_str()
}

fn extract_datatype(claim: &Value) -> Option<&str> {
    claim.get("mainsnak")?.get("datatype")?.as_str()
}

fn extract_time_value(claim: &Value) -> Option<(&str, i64)> {
    let dv = claim.get("mainsnak")?.get("datavalue")?.get("value")?;
    let time = dv.get("time")?.as_str()?;
    let precision = dv.get("precision")?.as_i64()?;
    Some((time, precision))
}

fn process_entity(
    entity: &Value,
    label_langs: &[String],
    all_times: &HashSet<&str>,
    times_plus_nested: &HashSet<&str>,
) -> Option<EntityOutput> {
    let id = entity.get("id").and_then(|v| v.as_str())?;

    let mut labels_lines = String::new();
    let mut links_lines = String::new();
    let mut dates_lines = String::new();

    // --- Extract labels ---
    let sitelinks = entity.get("sitelinks").and_then(|v| v.as_object());
    let wikidata_labels = entity.get("labels").and_then(|v| v.as_object());

    let mut best_label: Option<String> = None;
    let mut wp_count = 0u32;

    if let Some(sl) = sitelinks {
        for key in sl.keys() {
            if key.ends_with("wiki")
                && !key.contains("quote")
                && !key.contains("source")
                && !key.contains("books")
                && !key.contains("news")
                && !key.contains("versity")
                && !key.contains("voyage")
                && !key.contains("species")
                && !key.contains("commons")
                && !key.contains("data")
                && !key.contains("media")
                && !key.contains("meta")
                && key != "commonswiki"
                && key != "wikidatawiki"
            {
                wp_count += 1;
            }
        }
    }

    for lang in label_langs {
        if lang == "best" || lang == "doi" || lang == "mul" {
            continue;
        }

        let wiki_key = format!("{lang}wiki");
        if let Some(sl) = sitelinks {
            if let Some(sitelink) = sl.get(&wiki_key) {
                if let Some(title) = sitelink.get("title").and_then(|v| v.as_str()) {
                    use std::fmt::Write as _;
                    let _ = writeln!(labels_lines, "{lang}\t{title}\t{id}");
                    if best_label.is_none() {
                        best_label = Some(title.to_string());
                    }
                }
            }
        }
    }

    if best_label.is_none() {
        if let Some(labels) = wikidata_labels {
            for lang in constants::LANG_ORDER {
                if let Some(label_obj) = labels.get(*lang) {
                    if let Some(value) = label_obj.get("value").and_then(|v| v.as_str()) {
                        best_label = Some(value.to_string());
                        break;
                    }
                }
            }
            if best_label.is_none() {
                for label_obj in labels.values() {
                    if let Some(value) = label_obj.get("value").and_then(|v| v.as_str()) {
                        best_label = Some(value.to_string());
                        break;
                    }
                }
            }
        }
    }

    // DOI label (P356)
    if let Some(claims) = entity.get("claims").and_then(|v| v.as_object()) {
        if let Some(doi_claims) = claims.get("P356") {
            if let Some(arr) = doi_claims.as_array() {
                for claim in arr {
                    if let Some(doi_val) = claim
                        .get("mainsnak")
                        .and_then(|m| m.get("datavalue"))
                        .and_then(|d| d.get("value"))
                        .and_then(|v| v.as_str())
                    {
                        use std::fmt::Write as _;
                        let _ = writeln!(labels_lines, "doi\t{doi_val}\t{id}");
                        break;
                    }
                }
            }
        }
    }

    let best = best_label.as_deref().unwrap_or(id);
    {
        use std::fmt::Write as _;
        let _ = writeln!(labels_lines, "best\t{best}\t{id}");
    }

    let items_line = format!("{},{},{}\n", csv_quote(id), csv_quote(best), wp_count);

    // --- Extract relationships and dates ---
    if let Some(claims) = entity.get("claims").and_then(|v| v.as_object()) {
        for (prop, claim_group) in claims {
            if let Some(arr) = claim_group.as_array() {
                for claim in arr {
                    let datatype = extract_datatype(claim);

                    if matches!(datatype, Some("wikibase-item" | "wikibase-property")) {
                        if let Some(target_id) = extract_qid(claim) {
                            use std::fmt::Write as _;
                            let _ = writeln!(links_lines, "{id},{target_id},{prop}");
                        }
                    }

                    if let Some(qualifiers) = claim.get("qualifiers").and_then(|v| v.as_object()) {
                        for (qprop, qvals) in qualifiers {
                            if let Some(qarr) = qvals.as_array() {
                                for qval in qarr {
                                    let qdt = qval.get("datatype").and_then(|v| v.as_str());
                                    if matches!(qdt, Some("wikibase-item" | "wikibase-property")) {
                                        if let Some(target) = qval
                                            .get("datavalue")
                                            .and_then(|d| d.get("value"))
                                            .and_then(|v| v.get("id"))
                                            .and_then(|v| v.as_str())
                                        {
                                            use std::fmt::Write as _;
                                            let _ =
                                                writeln!(links_lines, "{id},{target},{qprop}");
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if all_times.contains(prop.as_str()) {
                        if let Some((time_val, precision)) = extract_time_value(claim) {
                            use std::fmt::Write as _;
                            let _ = writeln!(
                                dates_lines,
                                "{id},{prop},{},{precision},,",
                                csv_quote(time_val)
                            );
                        }
                    }

                    if times_plus_nested.contains(prop.as_str()) {
                        if let Some(qualifiers) =
                            claim.get("qualifiers").and_then(|v| v.as_object())
                        {
                            let source_target = extract_qid(claim).unwrap_or("");
                            for (qprop, qvals) in qualifiers {
                                if all_times.contains(qprop.as_str()) {
                                    if let Some(qarr) = qvals.as_array() {
                                        for qval in qarr {
                                            if let Some(dv) =
                                                qval.get("datavalue").and_then(|d| d.get("value"))
                                            {
                                                if let (Some(time), Some(prec)) = (
                                                    dv.get("time").and_then(|v| v.as_str()),
                                                    dv.get("precision").and_then(|v| v.as_i64()),
                                                ) {
                                                    use std::fmt::Write as _;
                                                    let _ = writeln!(
                                                        dates_lines,
                                                        "{id},{qprop},{},{prec},{prop},{source_target}",
                                                        csv_quote(time)
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Some(EntityOutput {
        items_line,
        labels_lines,
        links_lines,
        dates_lines,
    })
}

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run");
    let label_langs = Arc::new(languages::label_language_chain(run_dir)?);
    let all_times: Arc<HashSet<&'static str>> = Arc::new(
        constants::all_times()
            .into_iter()
            .collect(),
    );
    let times_plus_nested: Arc<HashSet<&'static str>> = Arc::new(
        constants::times_plus_nested()
            .into_iter()
            .collect(),
    );

    let num_workers = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .max(2)
        - 1; // reserve one core for the writer
    let num_workers = num_workers.max(1);

    log::info!("Starting with {num_workers} worker threads");

    // Channel: reader -> workers (raw JSON strings)
    let (line_tx, line_rx) = bounded::<String>(num_workers * 64);

    // Channel: workers -> writer (processed output)
    let (out_tx, out_rx) = bounded::<EntityOutput>(num_workers * 64);

    // Spawn worker threads
    let mut worker_handles = Vec::with_capacity(num_workers);
    for _ in 0..num_workers {
        let line_rx = line_rx.clone();
        let out_tx = out_tx.clone();
        let label_langs = Arc::clone(&label_langs);
        let all_times = Arc::clone(&all_times);
        let times_plus_nested = Arc::clone(&times_plus_nested);

        let handle = thread::spawn(move || {
            for json_str in line_rx {
                let entity: Value = match serde_json::from_str(&json_str) {
                    Ok(v) => v,
                    Err(e) => {
                        log::warn!("Failed to parse JSON: {e}");
                        continue;
                    }
                };

                if let Some(output) =
                    process_entity(&entity, &label_langs, &all_times, &times_plus_nested)
                {
                    if out_tx.send(output).is_err() {
                        break;
                    }
                }
            }
        });
        worker_handles.push(handle);
    }
    // Drop our copy so the writer sees EOF when all workers finish
    drop(out_tx);

    // Spawn writer thread
    let writer_handle = thread::spawn(move || -> Result<()> {
        let mut items = BufWriter::new(std::fs::File::create(run_dir.join("items.csv"))?);
        let mut links = BufWriter::new(std::fs::File::create(run_dir.join("links.csv"))?);
        let mut labels = BufWriter::new(std::fs::File::create(run_dir.join("wd_labels.tsv"))?);
        let mut dates = BufWriter::new(std::fs::File::create(run_dir.join("date_claims.csv"))?);

        let mut count = 0u64;
        for output in out_rx {
            items.write_all(output.items_line.as_bytes())?;
            if !output.labels_lines.is_empty() {
                labels.write_all(output.labels_lines.as_bytes())?;
            }
            if !output.links_lines.is_empty() {
                links.write_all(output.links_lines.as_bytes())?;
            }
            if !output.dates_lines.is_empty() {
                dates.write_all(output.dates_lines.as_bytes())?;
            }

            count += 1;
            if count % 1_000_000 == 0 {
                log::info!("Written {count} entities");
            }
        }

        items.flush()?;
        links.flush()?;
        labels.flush()?;
        dates.flush()?;

        log::info!("Done. Written {count} entities total.");
        Ok(())
    });

    // Reader: main thread reads stdin and dispatches lines
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                log::warn!("Error reading line: {e}");
                continue;
            }
        };

        let trimmed = line.trim();
        if trimmed == "[" || trimmed == "]" {
            continue;
        }
        let json_str = trimmed.trim_end_matches(',');
        if json_str.is_empty() {
            continue;
        }

        if line_tx.send(json_str.to_string()).is_err() {
            break;
        }
    }

    // Signal workers that input is done
    drop(line_tx);

    // Wait for workers to finish
    for handle in worker_handles {
        handle.join().expect("worker thread panicked");
    }

    // Wait for writer to finish
    writer_handle.join().expect("writer thread panicked")?;

    Ok(())
}
