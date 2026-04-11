use algae_farmer::constants;
use anyhow::Result;
use serde_json::Value;
use std::collections::HashSet;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;

struct OutputWriters {
    lemmas: BufWriter<std::fs::File>,
    forms: BufWriter<std::fs::File>,
    l2l: BufWriter<std::fs::File>,
    l2q: BufWriter<std::fs::File>,
    s2q: BufWriter<std::fs::File>,
    s2s: BufWriter<std::fs::File>,
}

fn process_lexeme(
    entity: &Value,
    l2l_props: &HashSet<&str>,
    l2q_props: &HashSet<&str>,
    s2q_props: &HashSet<&str>,
    s2s_props: &HashSet<&str>,
    out: &mut OutputWriters,
) -> Result<()> {
    let id = match entity.get("id").and_then(|v| v.as_str()) {
        Some(id) => id,
        None => return Ok(()),
    };

    // Extract lemmas
    if let Some(lemmas) = entity.get("lemmas").and_then(|v| v.as_object()) {
        for (lang, lemma_obj) in lemmas {
            if let Some(value) = lemma_obj.get("value").and_then(|v| v.as_str()) {
                writeln!(out.lemmas, "{lang}\t{value}\t{id}")?;
            }
        }
    }

    // Extract lexeme claims
    if let Some(claims) = entity.get("claims").and_then(|v| v.as_object()) {
        for (prop, claim_group) in claims {
            if let Some(arr) = claim_group.as_array() {
                for claim in arr {
                    let target_id = claim
                        .get("mainsnak")
                        .and_then(|m| m.get("datavalue"))
                        .and_then(|d| d.get("value"))
                        .and_then(|v| v.get("id"))
                        .and_then(|v| v.as_str());

                    if let Some(target) = target_id {
                        if l2l_props.contains(prop.as_str()) && target.starts_with('L') {
                            writeln!(out.l2l, "{id}\t{target}\t{prop}")?;
                        }
                        if l2q_props.contains(prop.as_str()) && target.starts_with('Q') {
                            writeln!(out.l2q, "{id}\t{target}\t{prop}")?;
                        }
                    }
                }
            }
        }
    }

    // Extract forms
    if let Some(forms) = entity.get("forms").and_then(|v| v.as_array()) {
        for form in forms {
            if let Some(reps) = form.get("representations").and_then(|v| v.as_object()) {
                for (lang, rep_obj) in reps {
                    if let Some(value) = rep_obj.get("value").and_then(|v| v.as_str()) {
                        writeln!(out.forms, "{lang}\t{value}\t{id}")?;
                    }
                }
            }
        }
    }

    // Extract senses
    if let Some(senses) = entity.get("senses").and_then(|v| v.as_array()) {
        for sense in senses {
            let sense_id = match sense.get("id").and_then(|v| v.as_str()) {
                Some(sid) => sid,
                None => continue,
            };

            if let Some(claims) = sense.get("claims").and_then(|v| v.as_object()) {
                for (prop, claim_group) in claims {
                    if let Some(arr) = claim_group.as_array() {
                        for claim in arr {
                            let target_id = claim
                                .get("mainsnak")
                                .and_then(|m| m.get("datavalue"))
                                .and_then(|d| d.get("value"))
                                .and_then(|v| v.get("id"))
                                .and_then(|v| v.as_str());

                            if let Some(target) = target_id {
                                // Sense-to-item
                                if s2q_props.contains(prop.as_str()) && target.starts_with('Q') {
                                    writeln!(out.s2q, "{id}\t{sense_id}\t{target}\t{prop}")?;
                                }

                                // Sense-to-sense: target is a sense ID like L123-S1
                                if s2s_props.contains(prop.as_str()) {
                                    // For S2S, we need to parse the target as lid-sid
                                    // The target from Wikidata for sense properties
                                    // points to another sense with form LID-SID
                                    if let Some(dash_pos) = target.find('-') {
                                        let dst_lid = &target[..dash_pos];
                                        let dst_sid = target;
                                        writeln!(
                                            out.s2s,
                                            "{id}\t{sense_id}\t{dst_lid}\t{dst_sid}\t{prop}"
                                        )?;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    env_logger::init();
    let run_dir = Path::new("run");
    let l2l_props = constants::l2l_properties();
    let l2q_props = constants::l2q_properties();
    let s2q_props = constants::s2q_properties();
    let s2s_props = constants::s2s_properties();

    let mut out = OutputWriters {
        lemmas: BufWriter::new(std::fs::File::create(run_dir.join("from_lemmas.tsv"))?),
        forms: BufWriter::new(std::fs::File::create(run_dir.join("from_forms.tsv"))?),
        l2l: BufWriter::new(std::fs::File::create(run_dir.join("l2l.tsv"))?),
        l2q: BufWriter::new(std::fs::File::create(run_dir.join("l2q.tsv"))?),
        s2q: BufWriter::new(std::fs::File::create(run_dir.join("s2q.tsv"))?),
        s2s: BufWriter::new(std::fs::File::create(run_dir.join("s2s.tsv"))?),
    };

    let stdin = io::stdin();
    let mut count = 0u64;

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

        let entity: Value = match serde_json::from_str(json_str) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("Failed to parse JSON at line {count}: {e}");
                continue;
            }
        };

        process_lexeme(&entity, &l2l_props, &l2q_props, &s2q_props, &s2s_props, &mut out)?;

        count += 1;
        if count % 100_000 == 0 {
            log::info!("Processed {count} lexemes");
        }
    }

    log::info!("Done. Processed {count} lexemes total.");
    Ok(())
}
