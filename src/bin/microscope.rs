use anyhow::Result;
use clap::Parser;
use tokio_postgres::NoTls;

#[derive(Parser)]
struct Args {
    /// QID to explore (default: Q42)
    #[arg(default_value = "Q42")]
    qid: String,
}

async fn get_neighbors(
    client: &tokio_postgres::Client,
    qid: &str,
) -> Result<(Vec<String>, Vec<(String, String, i32)>, Vec<(String, String, String)>)> {
    // Query wp_links
    let wp_rows = client
        .query(
            "SELECT src, dst, wp_count FROM wp_links WHERE src = $1 OR dst = $1 ORDER BY wp_count DESC",
            &[&qid],
        )
        .await?;

    let mut wp_links = Vec::new();
    let mut items = std::collections::HashSet::new();
    for row in &wp_rows {
        let src: String = row.get(0);
        let dst: String = row.get(1);
        let count: i32 = row.get(2);
        items.insert(src.clone());
        items.insert(dst.clone());
        wp_links.push((src, dst, count));
    }

    // Query wd_links
    let wd_rows = client
        .query(
            "SELECT src, dst, prop FROM wd_links WHERE src = $1 OR dst = $1",
            &[&qid],
        )
        .await?;

    let mut wd_links = Vec::new();
    for row in &wd_rows {
        let src: String = row.get(0);
        let dst: String = row.get(1);
        let prop: String = row.get(2);
        items.insert(src.clone());
        items.insert(dst.clone());
        wd_links.push((src, dst, prop));
    }

    let items_vec: Vec<String> = items.into_iter().collect();
    Ok((items_vec, wp_links, wd_links))
}

async fn get_entities(
    client: &reqwest::Client,
    qids: &[String],
) -> Result<serde_json::Value> {
    let ids = qids.join("|");
    let url = format!(
        "https://www.wikidata.org/w/api.php?action=wbgetentities&ids={}&format=json",
        ids
    );
    let resp = client
        .get(&url)
        .header("User-Agent", "algae-farmer/0.1 (https://github.com/algae-farmer)")
        .send()
        .await?
        .json::<serde_json::Value>()
        .await?;
    Ok(resp.get("entities").cloned().unwrap_or(serde_json::Value::Null))
}

async fn get_article_wikitext(
    client: &reqwest::Client,
    lang: &str,
    title: &str,
) -> Result<String> {
    let encoded_title = urlencoding::encode(title);
    let url = format!(
        "https://{lang}.wikipedia.org/w/index.php?title={encoded_title}&action=raw"
    );
    let text = client
        .get(&url)
        .header("User-Agent", "algae-farmer/0.1 (https://github.com/algae-farmer)")
        .send()
        .await?
        .text()
        .await?;
    Ok(text)
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    let db_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "host=localhost dbname=algae".to_string());

    let (db_client, connection) = tokio_postgres::connect(&db_url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            log::error!("DB connection error: {e}");
        }
    });

    let http_client = reqwest::Client::new();

    println!("=== Microscope: {} ===\n", args.qid);

    let (items, wp_links, wd_links) = get_neighbors(&db_client, &args.qid).await?;

    println!("--- Wikipedia Links ({} total) ---", wp_links.len());
    for (src, dst, count) in &wp_links {
        println!("  {src} -> {dst}  (wp_count: {count})");
    }

    println!("\n--- Wikidata Links ({} total) ---", wd_links.len());
    for (src, dst, prop) in &wd_links {
        println!("  {src} -> {dst}  ({prop})");
    }

    println!("\n--- Fetching entity data for {} items ---", items.len());

    // Fetch in batches of 50 (Wikidata API limit)
    for chunk in items.chunks(50) {
        let entities = get_entities(&http_client, chunk).await?;
        if let Some(obj) = entities.as_object() {
            for (qid, entity) in obj {
                let label = entity
                    .get("labels")
                    .and_then(|l| l.get("en"))
                    .and_then(|l| l.get("value"))
                    .and_then(|v| v.as_str())
                    .unwrap_or(qid);
                println!("  {qid}: {label}");

                // Fetch wikitext for each sitelink
                if let Some(sitelinks) = entity.get("sitelinks").and_then(|s| s.as_object()) {
                    if let Some(enwiki) = sitelinks.get("enwiki") {
                        if let Some(title) = enwiki.get("title").and_then(|t| t.as_str()) {
                            match get_article_wikitext(&http_client, "en", title).await {
                                Ok(wikitext) => {
                                    let preview = if wikitext.len() > 200 {
                                        &wikitext[..200]
                                    } else {
                                        &wikitext
                                    };
                                    println!("    wikitext preview: {preview}...");
                                }
                                Err(e) => {
                                    log::warn!("Failed to fetch wikitext for {title}: {e}");
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
