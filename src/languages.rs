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
    /// Wikipedia editions that exist but have no content export to download —
    /// closed wikis, or ones created since the last export run. They are kept
    /// out of `wikipedia` so the pipeline never tries to fetch them, but they
    /// still carry Wikidata labels, so `label_language_chain` includes them.
    #[serde(default)]
    pub wikipedia_no_export: Vec<String>,
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
///
/// Includes editions with no content export: a wiki we cannot download still
/// has Wikidata labels worth keeping.
pub fn label_language_chain(run_dir: &Path) -> Result<Vec<String>> {
    let mut langs = load_languages(run_dir, "wikipedia")?;
    let registry_path = run_dir.join("languages.json");
    let registry: LanguageRegistry = serde_json::from_str(
        &std::fs::read_to_string(&registry_path)
            .with_context(|| format!("reading {}", registry_path.display()))?,
    )?;
    // Overrides intentionally do not apply here: they select what to build the
    // link graph from, not which labels to store.
    langs.extend(registry.wikipedia_no_export);
    langs.push("mul".to_string());
    langs.push("doi".to_string());
    langs.push("best".to_string());
    Ok(langs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_registry(dir: &Path, json: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("languages.json"), json).unwrap();
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("algae-lang-{name}")).join("run");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
        dir
    }

    #[test]
    fn no_export_wikis_stay_out_of_the_build_list() {
        let run = scratch("build-list");
        write_registry(
            &run,
            r#"{"discovered_at":"now","wikipedia":["en","fr"],"wiktionary":[],
                "dbpedia":[],"wikipedia_no_export":["cr","kl"]}"#,
        );
        assert_eq!(load_languages(&run, "wikipedia").unwrap(), ["en", "fr"]);
    }

    #[test]
    fn no_export_wikis_still_contribute_labels() {
        let run = scratch("labels");
        write_registry(
            &run,
            r#"{"discovered_at":"now","wikipedia":["en","fr"],"wiktionary":[],
                "dbpedia":[],"wikipedia_no_export":["cr","kl"]}"#,
        );
        let chain = label_language_chain(&run).unwrap();
        assert_eq!(chain, ["en", "fr", "cr", "kl", "mul", "doi", "best"]);
    }

    /// Registries written before wikipedia_no_export existed must still load.
    #[test]
    fn registry_without_no_export_field_loads() {
        let run = scratch("legacy");
        write_registry(
            &run,
            r#"{"discovered_at":"now","wikipedia":["en"],"wiktionary":[],"dbpedia":[]}"#,
        );
        assert_eq!(
            label_language_chain(&run).unwrap(),
            ["en", "mul", "doi", "best"]
        );
    }
}
