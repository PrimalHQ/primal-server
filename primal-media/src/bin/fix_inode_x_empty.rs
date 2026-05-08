// Ad-hoc fix for `content_type = 'inode/x-empty'` rows in `media_storage`
// that were created on 2026-05-02 (the day the parse_mimetype race spiked
// to ~8.7% of S3 uploads). For each affected row:
//   1. find the correct mimetype from a sibling row with same sha256
//      that already has a sane content_type;
//   2. rewrite the S3 object's metadata in place via CopyObject with
//      MetadataDirective=REPLACE, setting Content-Type to the correct
//      mimetype (the object body is unchanged);
//   3. update media_storage.content_type for that row.
//
// Defaults to dry-run; pass --apply to actually write.

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use aws_config::BehaviorVersion;
use aws_sdk_s3::config::Credentials;
use aws_sdk_s3::config::Region;
use aws_sdk_s3::types::MetadataDirective;
use aws_sdk_s3::Client;
use aws_types::sdk_config::{RequestChecksumCalculation, ResponseChecksumValidation};
use clap::Parser;
use env_logger::Env;
use log::{error, info, warn};
use primal_media::config::{Config, S3ProviderConfig};
use sqlx::Row;
use url::Url;

#[derive(Debug, Parser)]
#[command(name = "fix_inode_x_empty")]
#[command(about = "Repair S3 object Content-Type for inode/x-empty rows from 2026-05-02")]
struct Cli {
    #[arg(long = "config", value_name = "FILE", default_value = "./primal-media.config.json")]
    config: PathBuf,

    /// UTC day to repair (inclusive start, exclusive end)
    #[arg(long = "day", default_value = "2026-05-02")]
    day: String,

    /// Actually perform the fix (default: dry-run)
    #[arg(long = "apply", default_value_t = false)]
    apply: bool,

    /// Limit number of rows to process (0 = all)
    #[arg(long = "limit", default_value_t = 0)]
    limit: usize,

    /// Concurrent S3+DB workers
    #[arg(long = "concurrency", default_value_t = 16)]
    concurrency: usize,
}

#[derive(Debug, Clone)]
struct BadRow {
    sha256: Vec<u8>,
    storage_provider: String,
    media_url: String,
}

fn day_bounds(day: &str) -> Result<(i64, i64)> {
    let start = time::Date::parse(
        day,
        time::macros::format_description!("[year]-[month]-[day]"),
    )?;
    let start_ts = start
        .midnight()
        .assume_utc()
        .unix_timestamp();
    let end_ts = start_ts + 86_400;
    Ok((start_ts, end_ts))
}

fn provider<'a>(cfg: &'a Config, name: &str) -> Option<&'a S3ProviderConfig> {
    cfg.media.s3_providers.iter().find(|p| p.name == name)
}

fn object_key_from_url(media_url: &str) -> Result<String> {
    let u = Url::parse(media_url).with_context(|| format!("parse url: {}", media_url))?;
    Ok(u.path().trim_start_matches('/').to_string())
}

async fn s3_client_for(p: &S3ProviderConfig) -> Client {
    let region = Region::new(p.region.clone());
    let credentials = Credentials::new(
        p.access_key.clone(),
        p.secret_key.clone(),
        None,
        None,
        "static",
    );
    let conf = aws_config::defaults(BehaviorVersion::latest())
        .region(region)
        .credentials_provider(credentials)
        .endpoint_url(p.endpoint.clone())
        .request_checksum_calculation(RequestChecksumCalculation::WhenRequired)
        .response_checksum_validation(ResponseChecksumValidation::WhenRequired)
        .load()
        .await;
    Client::new(&conf)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 8)]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_path(cli.config.to_str().unwrap())?;
    let (start_ts, end_ts) = day_bounds(&cli.day)?;
    info!(
        "day={} start_ts={} end_ts={} apply={} limit={} concurrency={}",
        cli.day, start_ts, end_ts, cli.apply, cli.limit, cli.concurrency
    );

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections((cli.concurrency as u32 + 4).min(64))
        .connect(&cfg.database_url())
        .await?;

    // Step 1: pull bad rows on the chosen day. We restrict to S3 providers,
    // since the ppr* local stores are the source of truth for mimetype.
    let s3_providers: Vec<String> = cfg
        .media
        .s3_providers
        .iter()
        .map(|p| p.name.clone())
        .collect();

    let mut q = format!(
        "select sha256, storage_provider, media_url \
         from media_storage \
         where added_at >= $1 and added_at < $2 \
           and content_type = 'inode/x-empty' \
           and size > 0 \
           and storage_provider = any($3::text[])"
    );
    if cli.limit > 0 {
        q.push_str(&format!(" limit {}", cli.limit));
    }

    let bad_rows: Vec<BadRow> = sqlx::query(&q)
        .bind(start_ts)
        .bind(end_ts)
        .bind(&s3_providers)
        .fetch_all(&pool)
        .await?
        .into_iter()
        .map(|r| BadRow {
            sha256: r.get::<Vec<u8>, _>("sha256"),
            storage_provider: r.get::<String, _>("storage_provider"),
            media_url: r.get::<String, _>("media_url"),
        })
        .collect();

    info!("bad rows on {}: {}", cli.day, bad_rows.len());
    if bad_rows.is_empty() {
        return Ok(());
    }

    // Step 2: gather the correct mimetype per distinct sha256 from a good
    // sibling row (any provider, any day). Local stores are preferred since
    // they were the original source of truth, but anything non-empty works.
    let distinct_shas: Vec<Vec<u8>> = {
        let mut s: Vec<Vec<u8>> = bad_rows.iter().map(|r| r.sha256.clone()).collect();
        s.sort();
        s.dedup();
        s
    };
    info!("distinct sha256: {}", distinct_shas.len());

    let mt_rows = sqlx::query(
        "select sha256, content_type, ext, storage_provider \
         from media_storage \
         where sha256 = any($1::bytea[]) \
           and content_type <> 'inode/x-empty' \
           and content_type <> '' \
           and size > 0",
    )
    .bind(&distinct_shas)
    .fetch_all(&pool)
    .await?;

    // Prefer ppr* (local) over S3 entries.
    let mut sha_to_mt: HashMap<Vec<u8>, (String, String)> = HashMap::new();
    for r in mt_rows {
        let sha: Vec<u8> = r.get("sha256");
        let ct: String = r.get("content_type");
        let ext: String = r.get("ext");
        let sp: String = r.get("storage_provider");
        let is_local = sp.starts_with("ppr");
        match sha_to_mt.get(&sha) {
            None => {
                sha_to_mt.insert(sha, (ct, ext));
            }
            Some(_) if is_local => {
                sha_to_mt.insert(sha, (ct, ext));
            }
            _ => {}
        }
    }

    let unmapped = distinct_shas
        .iter()
        .filter(|s| !sha_to_mt.contains_key(*s))
        .count();
    if unmapped > 0 {
        warn!(
            "{} distinct sha256 have no good sibling row; they will be skipped",
            unmapped
        );
    }

    // Step 3: build one S3 client per provider.
    let mut clients: HashMap<String, (Client, S3ProviderConfig)> = HashMap::new();
    for r in &bad_rows {
        if !clients.contains_key(&r.storage_provider) {
            let p = provider(&cfg, &r.storage_provider)
                .ok_or_else(|| anyhow!("unknown s3 provider in bad row: {}", r.storage_provider))?;
            let c = s3_client_for(p).await;
            clients.insert(r.storage_provider.clone(), (c, p.clone()));
        }
    }

    // Step 4: process bad rows with bounded concurrency.
    use futures::stream::{FuturesUnordered, StreamExt};

    let total = bad_rows.len();
    let mut iter = bad_rows.into_iter();
    let mut in_flight = FuturesUnordered::new();
    let mut done = 0usize;
    let mut fixed = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;

    let process_one = |row: BadRow,
                       clients: HashMap<String, (Client, S3ProviderConfig)>,
                       sha_to_mt: HashMap<Vec<u8>, (String, String)>,
                       pool: sqlx::PgPool,
                       apply: bool| {
        async move {
            let (mt, _ext) = match sha_to_mt.get(&row.sha256) {
                Some(v) => v.clone(),
                None => return Outcome::Skipped("no good sibling".into()),
            };
            let (client, pcfg) = clients.get(&row.storage_provider).expect("client present");
            let key = match object_key_from_url(&row.media_url) {
                Ok(k) => k,
                Err(e) => return Outcome::Failed(format!("bad url: {}", e)),
            };
            if apply {
                if let Err(e) = client
                    .copy_object()
                    .bucket(&pcfg.bucket)
                    .key(&key)
                    .copy_source(format!("{}/{}", pcfg.bucket, key))
                    .metadata_directive(MetadataDirective::Replace)
                    .content_type(&mt)
                    .send()
                    .await
                {
                    return Outcome::Failed(format!("s3 copy: {:?}", e));
                }
                if let Err(e) = sqlx::query(
                    "update media_storage set content_type = $1 \
                     where storage_provider = $2 and media_url = $3 \
                       and content_type = 'inode/x-empty'",
                )
                .bind(&mt)
                .bind(&row.storage_provider)
                .bind(&row.media_url)
                .execute(&pool)
                .await
                {
                    return Outcome::Failed(format!("db update: {}", e));
                }
            }
            Outcome::Fixed(mt)
        }
    };

    loop {
        while in_flight.len() < cli.concurrency {
            match iter.next() {
                Some(row) => {
                    let fut = process_one(
                        row.clone(),
                        clients.clone(),
                        sha_to_mt.clone(),
                        pool.clone(),
                        cli.apply,
                    );
                    in_flight.push(async move {
                        let outcome = fut.await;
                        (row, outcome)
                    });
                }
                None => break,
            }
        }
        match in_flight.next().await {
            Some((row, outcome)) => {
                done += 1;
                match outcome {
                    Outcome::Fixed(mt) => {
                        fixed += 1;
                        if done % 200 == 0 || done == total {
                            info!(
                                "[{}/{}] {} {} -> {}",
                                done, total, row.storage_provider, row.media_url, mt
                            );
                        }
                    }
                    Outcome::Skipped(reason) => {
                        skipped += 1;
                        warn!("skip {}: {}", row.media_url, reason);
                    }
                    Outcome::Failed(reason) => {
                        failed += 1;
                        error!("fail {}: {}", row.media_url, reason);
                    }
                }
            }
            None => break,
        }
    }

    info!(
        "done: total={} fixed={} skipped={} failed={} apply={}",
        total, fixed, skipped, failed, cli.apply
    );
    Ok(())
}

enum Outcome {
    Fixed(String),
    Skipped(String),
    Failed(String),
}
