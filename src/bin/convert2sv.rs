use anyhow::Result;
use clap::Parser;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;

#[derive(Parser)]
struct Args {
    /// Input .txt file
    input: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let output = args.input.with_extension("csv");

    let file = std::fs::File::open(&args.input)?;
    let reader = BufReader::new(file);
    let mut writer = BufWriter::new(std::fs::File::create(&output)?);

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Detect if this is `uniq -c` output (leading count + whitespace)
        // Format from uniq -c: "     count\tsrc\tdst" or "     count src dst"
        let parts: Vec<&str> = trimmed.split_whitespace().collect();

        if parts.len() == 3 {
            // Could be: count src dst (from uniq -c)
            // Try to parse first field as a number
            if let Ok(_count) = parts[0].parse::<u64>() {
                // 3-column input: count, src, dst -> output: src,dst,count
                writeln!(writer, "{},{},{}", parts[1], parts[2], parts[0])?;
                continue;
            }
        }

        if parts.len() == 2 {
            // 2-column input: src, dst -> output: src,dst
            writeln!(writer, "{},{}", parts[0], parts[1])?;
            continue;
        }

        // Try tab-separated
        let tab_parts: Vec<&str> = trimmed.splitn(3, '\t').collect();
        if tab_parts.len() == 3 {
            if let Ok(_count) = tab_parts[0].trim().parse::<u64>() {
                writeln!(
                    writer,
                    "{},{},{}",
                    tab_parts[1],
                    tab_parts[2],
                    tab_parts[0].trim()
                )?;
                continue;
            }
        }
        if tab_parts.len() == 2 {
            writeln!(writer, "{},{}", tab_parts[0], tab_parts[1])?;
            continue;
        }

        // Fallback: write as-is with commas replacing whitespace
        writeln!(writer, "{}", parts.join(","))?;
    }

    Ok(())
}
