use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

#[derive(Debug, Serialize, Deserialize)]
pub struct LanguageRegistry {
    pub discovered_at: String,
    pub wikipedia: Vec<String>,
    pub wiktionary: Vec<String>,
    pub dbpedia: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct LanguageOverride {
    #[serde(default)]
    pub wikipedia: Vec<String>,
    #[serde(default)]
    pub wiktionary: Vec<String>,
    #[serde(default)]
    pub dbpedia: Vec<String>,
}

/// Load the resolved language list for a given project, applying overrides if present.
pub fn load_languages(run_dir: &Path, project: &str) -> Result<Vec<String>> {
    let registry_path = run_dir.join("languages.json");
    let registry: LanguageRegistry = serde_json::from_str(
        &std::fs::read_to_string(&registry_path)
            .with_context(|| format!("reading {}", registry_path.display()))?,
    )?;

    let discovered = match project {
        "wikipedia" => registry.wikipedia,
        "wiktionary" => registry.wiktionary,
        "dbpedia" => registry.dbpedia,
        _ => anyhow::bail!("unknown project: {project}"),
    };

    // Check for override file in pipeline root (parent of run/)
    let pipeline_root = run_dir.parent().unwrap_or(Path::new("."));
    let override_path = pipeline_root.join("languages_override.json");

    if override_path.exists() {
        let overrides: LanguageOverride = serde_json::from_str(
            &std::fs::read_to_string(&override_path)
                .with_context(|| format!("reading {}", override_path.display()))?,
        )?;

        let override_set: HashSet<String> = match project {
            "wikipedia" => overrides.wikipedia,
            "wiktionary" => overrides.wiktionary,
            "dbpedia" => overrides.dbpedia,
            _ => unreachable!(),
        }
        .into_iter()
        .collect();

        // Intersect: only keep discovered languages that are also in the override
        let filtered: Vec<String> = discovered
            .into_iter()
            .filter(|l| override_set.contains(l))
            .collect();

        Ok(filtered)
    } else {
        Ok(discovered)
    }
}

/// Build the label language chain from the Wikipedia list plus synthetic entries.
pub fn label_language_chain(run_dir: &Path) -> Result<Vec<String>> {
    let mut langs = load_languages(run_dir, "wikipedia")?;
    langs.push("mul".to_string());
    langs.push("doi".to_string());
    langs.push("best".to_string());
    Ok(langs)
}
