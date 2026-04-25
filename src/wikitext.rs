//! MediaWiki template parser and link extractors.
//!
//! Companion to the `[[...]]` regex used in wp_preproc / wkt_preproc: covers
//! link targets that live in template parameters (e.g. `{{ill|Foo|de|...}}`,
//! `{{l|en|word}}`, `{{cite book|title-link=Bar}}`).

pub struct Template<'a> {
    pub name: &'a str,
    pub positional: Vec<&'a str>,
    pub named: Vec<(&'a str, &'a str)>,
}

impl<'a> Template<'a> {
    pub fn pos(&self, i: usize) -> Option<&'a str> {
        self.positional.get(i).copied().filter(|s| !s.is_empty())
    }

    pub fn get(&self, key: &str) -> Option<&'a str> {
        self.named
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| *v)
            .filter(|s| !s.is_empty())
    }
}

/// Walks `text` and returns every `{{...}}` invocation, including nested ones
/// (each emitted in its own right, so `{{l|en|{{w|x}}}}` yields two templates).
/// Pages with malformed brace pairs are tolerated: unmatched `{{` and stray
/// `}}` are skipped silently.
pub fn parse_templates(text: &str) -> Vec<Template<'_>> {
    let bytes = text.as_bytes();
    let mut starts: Vec<usize> = Vec::new();
    let mut bodies: Vec<(usize, usize)> = Vec::new();

    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'{' && bytes[i + 1] == b'{' {
            starts.push(i + 2);
            i += 2;
        } else if bytes[i] == b'}' && bytes[i + 1] == b'}' {
            if let Some(start) = starts.pop() {
                if start <= i {
                    bodies.push((start, i));
                }
            }
            i += 2;
        } else {
            i += 1;
        }
    }

    bodies
        .into_iter()
        .filter_map(|(s, e)| parse_template_body(&text[s..e]))
        .collect()
}

fn parse_template_body(body: &str) -> Option<Template<'_>> {
    let parts = split_args(body);
    let mut iter = parts.into_iter();
    let name = iter.next()?.trim();
    if name.is_empty() {
        return None;
    }

    let mut positional = Vec::new();
    let mut named = Vec::new();
    for part in iter {
        if let Some(eq_pos) = find_named_split(part) {
            let key = part[..eq_pos].trim();
            // Per design: ignore numeric-named args ({{l|en|1=word}}).
            if !key.is_empty() && !key.bytes().all(|b| b.is_ascii_digit()) {
                let value = part[eq_pos + 1..].trim();
                named.push((key, value));
            }
        } else {
            positional.push(part.trim());
        }
    }
    Some(Template {
        name,
        positional,
        named,
    })
}

/// Splits on top-level `|` only — depth tracked for both `{{...}}` and `[[...]]`.
fn split_args(body: &str) -> Vec<&str> {
    let bytes = body.as_bytes();
    let mut depth_brace: i32 = 0;
    let mut depth_bracket: i32 = 0;
    let mut last = 0;
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let next = bytes.get(i + 1).copied();
        match (bytes[i], next) {
            (b'{', Some(b'{')) => {
                depth_brace += 1;
                i += 2;
                continue;
            }
            (b'}', Some(b'}')) => {
                if depth_brace > 0 {
                    depth_brace -= 1;
                }
                i += 2;
                continue;
            }
            (b'[', Some(b'[')) => {
                depth_bracket += 1;
                i += 2;
                continue;
            }
            (b']', Some(b']')) => {
                if depth_bracket > 0 {
                    depth_bracket -= 1;
                }
                i += 2;
                continue;
            }
            (b'|', _) if depth_brace == 0 && depth_bracket == 0 => {
                out.push(&body[last..i]);
                last = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    out.push(&body[last..]);
    out
}

fn find_named_split(arg: &str) -> Option<usize> {
    let bytes = arg.as_bytes();
    let mut depth_brace: i32 = 0;
    let mut depth_bracket: i32 = 0;
    let mut i = 0;
    while i < bytes.len() {
        let next = bytes.get(i + 1).copied();
        match (bytes[i], next) {
            (b'{', Some(b'{')) => {
                depth_brace += 1;
                i += 2;
            }
            (b'}', Some(b'}')) => {
                if depth_brace > 0 {
                    depth_brace -= 1;
                }
                i += 2;
            }
            (b'[', Some(b'[')) => {
                depth_bracket += 1;
                i += 2;
            }
            (b']', Some(b']')) => {
                if depth_bracket > 0 {
                    depth_bracket -= 1;
                }
                i += 2;
            }
            (b'=', _) if depth_brace == 0 && depth_bracket == 0 => return Some(i),
            _ => {
                i += 1;
            }
        }
    }
    None
}

/// Lowercase + collapse `_`/whitespace runs to single spaces. Used so that
/// `{{See also}}`, `{{see_also}}`, and `{{see  also}}` all dispatch the same.
fn normalize_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut prev_space = true;
    for c in name.chars() {
        let c = if c == '_' { ' ' } else { c };
        if c.is_whitespace() {
            if !prev_space {
                out.push(' ');
                prev_space = true;
            }
        } else {
            out.extend(c.to_lowercase());
            prev_space = false;
        }
    }
    if out.ends_with(' ') {
        out.pop();
    }
    out
}

/// Trims, drops empty strings, and filters out namespace-prefixed targets that
/// the existing wikilink extractor also rejects (Category, File, …).
pub fn normalize_link_target(target: &str) -> Option<&str> {
    let target = target.trim();
    if target.is_empty() {
        return None;
    }
    if let Some(colon_pos) = target.find(':') {
        if colon_pos > 0 {
            let prefix = &target[..colon_pos];
            const SKIP: &[&str] = &[
                "Category",
                "File",
                "Image",
                "Wikipedia",
                "WP",
                "Template",
                "Help",
                "Portal",
                "Draft",
                "MediaWiki",
                "Module",
                "Talk",
                "User",
                "Special",
            ];
            if SKIP.iter().any(|p| p.eq_ignore_ascii_case(prefix)) {
                return None;
            }
        }
    }
    Some(target)
}

/// Link targets extractable from a Wikipedia-style template. Conservative
/// list — covers `{{ill}}`, the common hatnotes, `{{redirect}}`/`{{about}}`,
/// and `*-link=` parameters in citation templates.
pub fn wp_template_links<'a>(tmpl: &Template<'a>) -> Vec<&'a str> {
    let name = normalize_name(tmpl.name);
    let mut out = Vec::new();
    match name.as_str() {
        // Interlanguage link: positional[0] is the en.wp redlink target.
        "ill" | "illm" | "ill-wd" | "interlanguage link" | "interlanguage link multi"
        | "interwiki link" | "link-interwiki" => {
            if let Some(t) = tmpl.pos(0) {
                out.push(t);
            }
        }

        // Hatnotes: every positional arg is a link target.
        "main" | "see also" | "further" | "details" | "broader" => {
            for arg in &tmpl.positional {
                if !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        // {{redirect|term|use1|tgt1|use2|tgt2|...}} — targets at even indices >= 2.
        "redirect" | "redirect2" | "redirect-distinguish" => {
            for (i, arg) in tmpl.positional.iter().enumerate() {
                if i >= 2 && i % 2 == 0 && !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        // {{about|use|use1|tgt1|use2|tgt2|...}} — targets at even indices >= 2.
        "about" => {
            for (i, arg) in tmpl.positional.iter().enumerate() {
                if i >= 2 && i % 2 == 0 && !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        // Citation templates: pull targets from named *-link params.
        n if n.starts_with("cite ") || n == "citation" => {
            for key in [
                "title-link",
                "chapter-link",
                "author-link",
                "editor-link",
                "publisher-link",
                "subject-link",
                "contribution-link",
                "encyclopedia-link",
                "work-link",
            ] {
                if let Some(v) = tmpl.get(key) {
                    out.push(v);
                }
            }
        }

        _ => {}
    }
    out
}

/// Link targets extractable from a Wiktionary-style template. Covers the
/// dominant link mechanisms: `{{l}}`/`{{m}}`, etymology templates, alt forms,
/// semantic relations, and affixation templates.
pub fn wkt_template_links<'a>(tmpl: &Template<'a>) -> Vec<&'a str> {
    let name = normalize_name(tmpl.name);
    let mut out = Vec::new();
    match name.as_str() {
        // {{l|lang|word}} / {{m|lang|word}} — target at positional[1].
        "l" | "ll" | "l-self" | "link" | "m" | "m-self" | "mention" | "m+" => {
            if let Some(t) = tmpl.pos(1) {
                out.push(t);
            }
        }

        // Etymology: {{der|en|la|cattus}} — source word at positional[2].
        "der" | "derived" | "inh" | "inherited" | "bor" | "borrowed" | "cog" | "cognate"
        | "lbor" | "learned borrowing" | "obor" | "orthographic borrowing" | "slbor"
        | "semi-learned borrowing" | "ubor" | "unadapted borrowing" | "psm"
        | "phono-semantic matching" | "calque" | "cal" | "clq" | "semantic loan" | "sl"
        | "noncog" | "nc" => {
            if let Some(t) = tmpl.pos(2) {
                out.push(t);
            }
        }

        // {{alter|lang|w1|w2|...}} / {{alt|...}} — every positional after the lang code.
        "alt" | "alter" => {
            for (i, arg) in tmpl.positional.iter().enumerate() {
                if i >= 1 && !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        // Single-target alt-form templates: positional[1] only.
        "alt form" | "altform" | "alternative form of" | "alternative spelling of"
        | "inflection of" | "infl of" | "form of" => {
            if let Some(t) = tmpl.pos(1) {
                out.push(t);
            }
        }

        // Semantic relations: {{syn|lang|w1|w2|...}} — every positional after lang.
        "syn" | "synonyms" | "ant" | "antonyms" | "hyper" | "hypernyms" | "hypo"
        | "hyponyms" | "mero" | "meronyms" | "holo" | "holonyms" | "cot"
        | "coordinate terms" | "tropo" | "troponyms" => {
            for (i, arg) in tmpl.positional.iter().enumerate() {
                if i >= 1 && !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        // Affixation: {{compound|lang|w1|w2|...}}, {{suffix|lang|root|suf}}, etc.
        "suffix" | "suf" | "prefix" | "pre" | "confix" | "con" | "compound" | "com"
        | "affix" | "af" | "circumfix" => {
            for (i, arg) in tmpl.positional.iter().enumerate() {
                if i >= 1 && !arg.is_empty() {
                    out.push(*arg);
                }
            }
        }

        _ => {}
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(text: &str) -> Vec<String> {
        parse_templates(text)
            .iter()
            .map(|t| t.name.to_string())
            .collect()
    }

    #[test]
    fn parses_simple_template() {
        let tmpls = parse_templates("{{ill|Foo|de|Bar}}");
        assert_eq!(tmpls.len(), 1);
        assert_eq!(tmpls[0].name, "ill");
        assert_eq!(tmpls[0].positional, vec!["Foo", "de", "Bar"]);
    }

    #[test]
    fn parses_named_args() {
        let tmpls = parse_templates("{{cite book|title=A B|title-link=A_B}}");
        assert_eq!(tmpls.len(), 1);
        assert_eq!(tmpls[0].positional.len(), 0);
        assert_eq!(tmpls[0].get("title"), Some("A B"));
        assert_eq!(tmpls[0].get("title-link"), Some("A_B"));
    }

    #[test]
    fn parses_nested_templates() {
        // Both inner and outer should be emitted.
        let names = names("{{l|en|{{m|en|x}}}}");
        assert!(names.contains(&"l".to_string()));
        assert!(names.contains(&"m".to_string()));
    }

    #[test]
    fn pipe_inside_wikilink_does_not_split_args() {
        let tmpls = parse_templates("{{main|[[Foo|Bar]]}}");
        assert_eq!(tmpls.len(), 1);
        assert_eq!(tmpls[0].positional, vec!["[[Foo|Bar]]"]);
    }

    #[test]
    fn ignores_numeric_named_args() {
        let tmpls = parse_templates("{{l|en|1=word}}");
        assert_eq!(tmpls[0].positional, vec!["en"]);
        assert!(tmpls[0].named.is_empty());
    }

    #[test]
    fn handles_unbalanced_braces() {
        // Should not panic.
        let _ = parse_templates("{{foo|bar");
        let _ = parse_templates("foo}}bar");
        let _ = parse_templates("{{{foo}}}");
    }

    #[test]
    fn wp_ill() {
        let tmpls = parse_templates("{{ill|Some Topic|de|Anderes}}");
        let links = wp_template_links(&tmpls[0]);
        assert_eq!(links, vec!["Some Topic"]);
    }

    #[test]
    fn wp_main_multi() {
        let tmpls = parse_templates("{{main|Article A|Article B}}");
        let links = wp_template_links(&tmpls[0]);
        assert_eq!(links, vec!["Article A", "Article B"]);
    }

    #[test]
    fn wp_redirect() {
        let tmpls = parse_templates("{{redirect|TERM|use1|Tgt1|use2|Tgt2}}");
        let links = wp_template_links(&tmpls[0]);
        assert_eq!(links, vec!["Tgt1", "Tgt2"]);
    }

    #[test]
    fn wp_about() {
        let tmpls = parse_templates("{{about|primary|use1|Tgt1|use2|Tgt2}}");
        let links = wp_template_links(&tmpls[0]);
        assert_eq!(links, vec!["Tgt1", "Tgt2"]);
    }

    #[test]
    fn wp_cite_links() {
        let tmpls =
            parse_templates("{{cite book|title=T|title-link=TL|author-link=AL|publisher=P}}");
        let mut links = wp_template_links(&tmpls[0]);
        links.sort();
        assert_eq!(links, vec!["AL", "TL"]);
    }

    #[test]
    fn wkt_l_and_m() {
        let tmpls = parse_templates("{{l|en|word}} {{m|en|other}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["word"]);
        assert_eq!(wkt_template_links(&tmpls[1]), vec!["other"]);
    }

    #[test]
    fn wkt_etymology() {
        let tmpls = parse_templates("{{der|en|la|cattus}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["cattus"]);
    }

    #[test]
    fn wkt_alt_multi() {
        let tmpls = parse_templates("{{alter|en|color|colour}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["color", "colour"]);
    }

    #[test]
    fn wkt_alt_form_single() {
        let tmpls = parse_templates("{{alt form|en|target}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["target"]);
    }

    #[test]
    fn wkt_synonyms() {
        let tmpls = parse_templates("{{syn|en|w1|w2|w3}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["w1", "w2", "w3"]);
    }

    #[test]
    fn wkt_compound() {
        let tmpls = parse_templates("{{compound|en|head|line}}");
        assert_eq!(wkt_template_links(&tmpls[0]), vec!["head", "line"]);
    }

    #[test]
    fn normalize_filters_namespaces() {
        assert_eq!(normalize_link_target("Foo"), Some("Foo"));
        assert_eq!(normalize_link_target("  Foo  "), Some("Foo"));
        assert_eq!(normalize_link_target("File:bar.png"), None);
        assert_eq!(normalize_link_target("category:X"), None);
        assert_eq!(normalize_link_target(":Foo"), Some(":Foo"));
        assert_eq!(normalize_link_target(""), None);
    }

    #[test]
    fn normalize_name_collapses_whitespace_and_underscores() {
        assert_eq!(normalize_name("See also"), "see also");
        assert_eq!(normalize_name("See_also"), "see also");
        assert_eq!(normalize_name("  See   _also  "), "see also");
    }
}
