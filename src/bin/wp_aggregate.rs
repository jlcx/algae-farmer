// Cross-language aggregation with witness provenance (replaces the
// `sort *_links_converted_uniq.txt | uniq -c` step, spec §2.6).
//
// K-way merge over the per-language sorted `{lang}_links_converted_uniq.txt`
// files. Each stream is tagged with the language's id from the append-only
// `languages` DB table; for every distinct (src, dst) pair the set of tags
// that produced it is emitted as a Postgres int2[] literal:
//
//     src,dst,"{5,12,88}"
//
// suitable for `\copy wp_links (src, dst, witnesses) FROM ... CSV`.
//
// Memory is O(k): one buffered line per open stream, never the pair universe.

use algae_farmer::languages::load_languages;
use anyhow::{bail, Context, Result};
use clap::Parser;
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;
use tokio_postgres::NoTls;

#[derive(Parser)]
struct Args {
    /// Pipeline run directory (languages.json + per-language link files)
    #[arg(long, default_value = "run")]
    run_dir: PathBuf,

    /// Output CSV path (default: <run-dir>/wp_links_witnesses.csv)
    #[arg(long)]
    output: Option<PathBuf>,

    /// Postgres connection string (falls back to $DATABASE_URL, then
    /// "host=localhost dbname=algae")
    #[arg(long)]
    db_url: Option<String>,
}

/// Insert any codes not yet present (append-only: never update or delete),
/// then return the full code -> id map.
///
/// The NOT EXISTS guard keeps re-runs from burning identity values on
/// conflicts; ON CONFLICT DO NOTHING remains as a race safety net. New codes
/// are inserted in sorted order so first-time id assignment is deterministic
/// and independent of languages.json ordering.
async fn sync_languages(db_url: &str, codes: &[String]) -> Result<HashMap<String, i16>> {
    let (client, connection) = tokio_postgres::connect(db_url, NoTls)
        .await
        .with_context(|| format!("connecting to {db_url}"))?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            log::error!("DB connection error: {e}");
        }
    });

    let mut sorted: Vec<&str> = codes.iter().map(String::as_str).collect();
    sorted.sort_unstable();

    client
        .execute(
            "INSERT INTO languages (code)
             SELECT c FROM unnest($1::text[]) AS t(c)
             WHERE NOT EXISTS (SELECT 1 FROM languages l WHERE l.code = t.c)
             ON CONFLICT (code) DO NOTHING",
            &[&sorted],
        )
        .await
        .context("inserting new codes into languages (does the table exist? run db_setup)")?;

    let rows = client.query("SELECT code, id FROM languages", &[]).await?;
    Ok(rows
        .into_iter()
        .map(|r| (r.get::<_, String>(0), r.get::<_, i16>(1)))
        .collect())
}

struct Stream {
    reader: BufReader<File>,
    id: i16,
    lang: String,
}

/// Read the next non-empty line (without trailing newline) into `buf`.
/// Returns false at EOF.
fn next_line(reader: &mut BufReader<File>, buf: &mut Vec<u8>) -> Result<bool> {
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', buf)?;
        if n == 0 {
            return Ok(false);
        }
        if buf.last() == Some(&b'\n') {
            buf.pop();
        }
        if buf.last() == Some(&b'\r') {
            buf.pop();
        }
        if !buf.is_empty() {
            return Ok(true);
        }
    }
}

fn emit(writer: &mut impl Write, pair: &[u8], tags: &mut Vec<i16>) -> Result<()> {
    let tab = pair
        .iter()
        .position(|&b| b == b'\t')
        .with_context(|| format!("malformed line (no tab): {}", String::from_utf8_lossy(pair)))?;
    tags.sort_unstable();
    writer.write_all(&pair[..tab])?;
    writer.write_all(b",")?;
    writer.write_all(&pair[tab + 1..])?;
    writer.write_all(b",\"{")?;
    let mut first = true;
    for id in tags.iter() {
        if !first {
            writer.write_all(b",")?;
        }
        first = false;
        write!(writer, "{id}")?;
    }
    writer.write_all(b"}\"\n")?;
    tags.clear();
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    let db_url = args
        .db_url
        .or_else(|| std::env::var("DATABASE_URL").ok())
        .unwrap_or_else(|| "host=localhost dbname=algae".to_string());
    let output = args
        .output
        .unwrap_or_else(|| args.run_dir.join("wp_links_witnesses.csv"));

    let codes = load_languages(&args.run_dir, "wikipedia")?;
    if codes.is_empty() {
        bail!("no Wikipedia languages resolved from {}", args.run_dir.display());
    }

    let id_map = sync_languages(&db_url, &codes).await?;

    let mut streams: Vec<Stream> = Vec::with_capacity(codes.len());
    for lang in &codes {
        let path = args.run_dir.join(format!("{lang}_links_converted_uniq.txt"));
        let file = File::open(&path).with_context(|| format!("opening {}", path.display()))?;
        let id = *id_map
            .get(lang)
            .with_context(|| format!("language {lang} missing from languages table"))?;
        streams.push(Stream {
            reader: BufReader::with_capacity(1 << 20, file),
            id,
            lang: lang.clone(),
        });
    }

    let tmp = output.with_extension("csv.tmp");
    let mut writer = BufWriter::with_capacity(1 << 22, File::create(&tmp)?);

    // Min-heap on (line bytes, stream index). Per-language files are sorted
    // with LC_ALL=C, so whole-line byte comparison matches their order.
    let mut heap: BinaryHeap<Reverse<(Vec<u8>, usize)>> = BinaryHeap::with_capacity(streams.len());
    for (idx, s) in streams.iter_mut().enumerate() {
        let mut buf = Vec::new();
        if next_line(&mut s.reader, &mut buf)? {
            heap.push(Reverse((buf, idx)));
        }
    }

    let mut current: Vec<u8> = Vec::new();
    let mut tags: Vec<i16> = Vec::new();
    let mut lines_read: u64 = 0;
    let mut pairs_out: u64 = 0;

    while let Some(Reverse((mut line, idx))) = heap.pop() {
        lines_read += 1;
        if tags.is_empty() {
            std::mem::swap(&mut current, &mut line);
        } else if line != current {
            emit(&mut writer, &current, &mut tags)?;
            pairs_out += 1;
            std::mem::swap(&mut current, &mut line);
        }
        tags.push(streams[idx].id);

        let mut buf = line; // reuse allocation
        if next_line(&mut streams[idx].reader, &mut buf)? {
            if buf.as_slice() <= current.as_slice() {
                bail!(
                    "{}_links_converted_uniq.txt is not sorted/unique: {:?} after {:?}",
                    streams[idx].lang,
                    String::from_utf8_lossy(&buf),
                    String::from_utf8_lossy(&current)
                );
            }
            heap.push(Reverse((buf, idx)));
        }
    }
    if !tags.is_empty() {
        emit(&mut writer, &current, &mut tags)?;
        pairs_out += 1;
    }

    writer.flush()?;
    drop(writer);
    std::fs::rename(&tmp, &output)?;

    eprintln!(
        "wp_aggregate: {} languages, {} lines in, {} pairs out -> {}",
        streams.len(),
        lines_read,
        pairs_out,
        output.display()
    );
    Ok(())
}
