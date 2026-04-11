use std::collections::{HashMap, HashSet};

/// Causal graph relationship properties (~70 properties).
pub fn cg_rels() -> HashMap<&'static str, &'static str> {
    let pairs: &[(&str, &str)] = &[
        // Influence/derivation
        ("P737", "influenced by"),
        ("P941", "inspired by"),
        ("P144", "based on"),
        ("P5191", "derived from"),
        // Causation
        ("P828", "has cause"),
        ("P1542", "cause of"),
        ("P1478", "has immediate cause"),
        ("P1536", "immediate cause of"),
        ("P1479", "has contributing factor"),
        ("P1537", "contributing factor of"),
        // Kinship
        ("P22", "father"),
        ("P25", "mother"),
        ("P40", "child"),
        ("P3448", "stepparent"),
        // Mentorship
        ("P184", "doctoral advisor"),
        ("P185", "doctoral student"),
        ("P1066", "student of"),
        ("P802", "student"),
        // Creation
        ("P112", "founded by"),
        ("P170", "creator"),
        ("P50", "author"),
        ("P61", "discoverer or inventor"),
        ("P86", "composer"),
        ("P178", "developer"),
        ("P287", "designed by"),
        // Succession
        ("P155", "follows"),
        ("P156", "followed by"),
        ("P1365", "replaces"),
        ("P1366", "replaced by"),
        ("P167", "structure replaced by"),
        // Film/media production
        ("P57", "director"),
        ("P58", "screenwriter"),
        ("P161", "cast member"),
        ("P162", "producer"),
        ("P272", "production company"),
        ("P344", "director of photography"),
        ("P1040", "film editor"),
        ("P1431", "executive producer"),
        ("P2515", "costume designer"),
        ("P2554", "production designer"),
        ("P3092", "film crew member"),
        ("P6338", "colorist"),
        // Other
        ("P138", "named after"),
        ("P800", "notable work"),
        ("P710", "participant"),
        ("P1344", "participant of"),
        ("P279", "subclass of"),
        ("P175", "performer"),
        ("P176", "manufacturer"),
    ];
    pairs.iter().copied().collect()
}

/// Start-time properties (12 properties).
pub fn starts() -> HashSet<&'static str> {
    [
        "P580", // start time
        "P571", // inception
        "P569", // date of birth
        "P575", // time of discovery or invention
        "P577", // publication date
        "P729", // service entry
        "P1191", // first performance
        "P1319", // earliest date
        "P6949", // announcement date
        "P2031", // work period (start)
        "P3999", // date of official opening
        "P1619", // date of official opening (alt)
    ]
    .into_iter()
    .collect()
}

/// End-time properties (9 properties).
pub fn ends() -> HashSet<&'static str> {
    [
        "P582", // end time
        "P576", // dissolved, abolished or demolished date
        "P570", // date of death
        "P2669", // discontinued date
        "P730", // service retirement
        "P3999", // date of official closing
        "P2032", // work period (end)
        "P1326", // latest date
        "P746",  // date of disappearance
    ]
    .into_iter()
    .collect()
}

/// Other time properties.
pub fn others() -> HashSet<&'static str> {
    ["P585", "P1317"].into_iter().collect() // point in time, floruit
}

/// Comprehensive set of all date/time properties (~80).
pub fn all_times() -> HashSet<&'static str> {
    let mut s = starts();
    s.extend(ends());
    s.extend(others());
    // Additional time properties
    for p in &[
        "P585", "P1317", "P813", "P1326", "P1319", "P2913", "P3893", "P2960",
        "P606", "P607", "P1636", "P2754", "P2755", "P2756", "P7124", "P7125",
        "P837", "P1734", "P2913", "P4602", "P1249", "P6257", "P1619", "P3999",
        "P1619", "P6949", "P8556", "P8557", "P585", "P580", "P582", "P571",
        "P576", "P569", "P570", "P577", "P575", "P729", "P730", "P1191",
        "P2031", "P2032", "P2669", "P746", "P7588", "P7589", "P2610",
        "P523", "P524", "P2894", "P2895", "P1619", "P585", "P3415",
        "P556", "P748", "P749", "P1734", "P1636", "P859", "P1389",
        "P7104", "P7103", "P6555", "P6556", "P4733", "P4734", "P9714",
        "P9715", "P2285", "P2286", "P4282", "P4283", "P6207", "P6208",
        "P7506", "P7507", "P7584", "P7585",
    ] {
        s.insert(p);
    }
    s
}

/// Properties that may carry date qualifiers nested inside non-date claims.
pub fn nested_time_rels() -> HashSet<&'static str> {
    [
        "P348", // software version identifier
        "P106", // occupation
        "P108", // employer
        "P69",  // educated at
        "P26",  // spouse
        "P449", // original network
        "P793", // significant event
        "P1891", // signatory
    ]
    .into_iter()
    .collect()
}

/// Union of starts, ends, others, and nested_time_rels.
pub fn times_plus_nested() -> HashSet<&'static str> {
    let mut s = all_times();
    s.extend(nested_time_rels());
    s
}

/// Properties where dateless statement is probably generic/non-specific.
pub fn likely_nonspecific() -> HashSet<&'static str> {
    ["P828", "P1542", "P1478", "P1536", "P1479", "P1537"]
        .into_iter()
        .collect()
}

/// Original inverse property pairs that Wikidata defines.
pub fn original_inverses() -> HashMap<&'static str, &'static str> {
    let pairs: &[(&str, &str)] = &[
        ("P22", "P40"),   // father <-> child
        ("P25", "P40"),   // mother <-> child
        ("P40", "P22"),   // child -> father (reverse)
        ("P184", "P185"), // doctoral advisor <-> doctoral student
        ("P185", "P184"),
        ("P1066", "P802"), // student of <-> student
        ("P802", "P1066"),
        ("P155", "P156"), // follows <-> followed by
        ("P156", "P155"),
        ("P1365", "P1366"), // replaces <-> replaced by
        ("P1366", "P1365"),
        ("P828", "P1542"), // has cause <-> cause of
        ("P1542", "P828"),
        ("P1478", "P1536"), // immediate cause <-> immediate cause of
        ("P1536", "P1478"),
        ("P1479", "P1537"), // contributing factor <-> contributing factor of
        ("P1537", "P1479"),
        ("P710", "P1344"), // participant <-> participant of
        ("P1344", "P710"),
    ];
    pairs.iter().copied().collect()
}

/// Extended inverse map including synthetic inverses (suffixed with 'i').
pub fn combined_inverses() -> HashMap<String, String> {
    let mut m: HashMap<String, String> = original_inverses()
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    // Add synthetic inverses for properties without official ones
    let synthetic = &[
        "P50", "P57", "P58", "P61", "P86", "P112", "P138", "P144", "P161",
        "P162", "P170", "P175", "P176", "P178", "P272", "P279", "P287",
        "P344", "P737", "P800", "P941", "P1040", "P1431", "P2515", "P2554",
        "P3092", "P3448", "P5191", "P6338",
    ];
    for p in synthetic {
        let inv = format!("{p}i");
        m.insert(p.to_string(), inv.clone());
        m.insert(inv, p.to_string());
    }
    m
}

/// Lexeme-to-lexeme properties.
pub fn l2l_properties() -> HashSet<&'static str> {
    ["P5191", "P5238", "P6571"].into_iter().collect()
}

/// Lexeme-to-item properties.
pub fn l2q_properties() -> HashSet<&'static str> {
    ["P6684", "P5137"].into_iter().collect()
}

/// Sense-to-item properties.
pub fn s2q_properties() -> HashSet<&'static str> {
    ["P5137", "P6684", "P9970"].into_iter().collect()
}

/// Sense-to-sense properties.
pub fn s2s_properties() -> HashSet<&'static str> {
    [
        "P5972", // translation
        "P5973", // synonym
        "P5974", // antonym
        "P5975", // troponym
        "P6593", // hyperonym
        "P8471", // pertainym
        "P12410", // semantic derivation
    ]
    .into_iter()
    .collect()
}

/// Short fallback chain for human-readable labels.
pub const LANG_ORDER: &[&str] = &[
    "en", "de", "fr", "es", "it", "pl", "pt", "nl", "sv", "no", "fi", "ro",
];
