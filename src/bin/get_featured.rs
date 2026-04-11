use anyhow::Result;
use chrono::Utc;
use clap::Parser;

#[derive(Parser)]
struct Args {
    /// Language code (default: en)
    #[arg(short, long, default_value = "en")]
    lang: String,

    /// Date in YYYY/MM/DD format (default: today)
    #[arg(short, long)]
    date: Option<String>,
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    let date = match args.date {
        Some(d) => d,
        None => {
            let now = Utc::now();
            now.format("%Y/%m/%d").to_string()
        }
    };

    let url = format!(
        "https://api.wikimedia.org/feed/v1/wikipedia/{}/featured/{date}",
        args.lang
    );

    let client = reqwest::blocking::Client::builder()
        .user_agent("algae-farmer/0.1 (https://github.com/algae-farmer)")
        .build()?;

    log::info!("Fetching featured content from: {url}");
    let resp = client.get(&url).send()?;

    if !resp.status().is_success() {
        anyhow::bail!("HTTP {} from {url}", resp.status());
    }

    let body: serde_json::Value = resp.json()?;
    let pretty = serde_json::to_string_pretty(&body)?;
    println!("{pretty}");

    Ok(())
}
