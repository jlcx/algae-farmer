use anyhow::Result;
use clap::Parser;
use std::process::Command;

#[derive(Parser)]
struct Args {
    /// Target table to load (e.g., wp_links, wd_links, wd_entities, etc.)
    table: String,

    /// Input file path
    file: String,

    /// File format: csv or tsv
    #[arg(short, long, default_value = "csv")]
    format: String,

    /// PostgreSQL database name
    #[arg(long, default_value = "algae")]
    dbname: String,
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    let delimiter = match args.format.as_str() {
        "tsv" => "DELIMITER E'\\t'",
        "csv" | _ => "CSV",
    };

    let copy_cmd = format!(
        "\\copy {} FROM '{}' {}", args.table, args.file, delimiter
    );

    log::info!("Loading {} into {} ...", args.file, args.table);

    let status = Command::new("psql")
        .args(["-d", &args.dbname, "-c", &copy_cmd])
        .status()?;

    if !status.success() {
        anyhow::bail!("psql failed with status: {status}");
    }

    log::info!("Done loading {} into {}.", args.file, args.table);
    Ok(())
}
