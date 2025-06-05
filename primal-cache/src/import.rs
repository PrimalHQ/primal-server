pub use std::sync::Arc;

pub use hex::FromHex;
pub use sqlx::pool::PoolOptions;

pub use hex;

pub use std::str::FromStr;

pub use nostr_sdk::prelude::{PublicKey, JsonUtil};

pub use serde_json::Value;
pub use serde_json::json;

use std::collections::HashMap;

use serde::Deserialize;

use crate::log;

use crate::nostr::*;

#[derive(Debug)]
pub struct RollingMap<K, V> 
where 
    K: std::hash::Hash + Eq + Clone + std::fmt::Debug,
    V: std::fmt::Debug,
{
    pub map: HashMap<K, V>,
    pub window: HashMap<i64, K>,
    pub oldest: i64,
    pub next: i64,
    pub capacity: i64,
    pub fallback: V,
}

impl<K, V> RollingMap<K, V> 
where
    K: std::hash::Hash + Eq + Clone + std::fmt::Debug,
    V: std::fmt::Debug + Default,
{
    pub fn new(capacity: i64) -> Self {
        Self {
            map: HashMap::new(),
            window: HashMap::new(),
            oldest: 0,
            next: 0,
            capacity,
            fallback: V::default(),
        }
    }
    pub fn contains_key(&self, key: &K) -> bool {
        self.map.contains_key(key)
    }
    pub fn get(&self, key: &K) -> Option<&V> {
        self.map.get(key)
    }
    pub fn get_mut(&mut self, key: &K) -> Option<&mut V> {
        self.map.get_mut(key)
    }
    pub fn insert(&mut self, key: &K, value: V) -> &mut V {
        if !self.map.contains_key(key) {
            self.window.insert(self.next, key.clone());
            self.next += 1;
        }
        self.map.insert(key.clone(), value);
        self.get_mut(key).unwrap()
    }
    pub fn maintain_capacity(&mut self, max_capacity: i64) -> Vec<(K, V)> {
        let cap = std::cmp::min(self.capacity, max_capacity);
        let mut removed = Vec::new();
        while self.next - self.oldest > cap {
            if let Some(old_key) = self.window.remove(&self.oldest) {
                if let Some(v) = self.map.remove(&old_key) {
                    removed.push((old_key, v));
                } else {
                    println!("KeyedStats: remove failed for key {old_key:?}");
                }
            }
            self.oldest += 1;
        }
        removed
    }
}

#[derive(Debug)]
pub struct EventRow {
    pub id: Option<Vec<u8>>,
    pub kind: Option<i64>,
    pub created_at: Option<i64>,
    pub pubkey: Option<Vec<u8>>,
    pub content: Option<String>,
    pub tags: Option<Value>,
    pub sig: Option<Vec<u8>>,
    pub imported_at: Option<i64>,
}

pub fn parse_event(r: EventRow) -> Result<Event, anyhow::Error> {
    if let (Some(id), Some(kind), Some(created_at), Some(pubkey), Some(content), Some(tags), Some(sig)) = (r.id.clone(), r.kind, r.created_at, r.pubkey, r.content, r.tags, r.sig) {
        match parse_tags(&tags) {
            Ok(tags) => {
                Ok(Event {
                    id: EventId(id),
                    pubkey: PubKeyId(pubkey),
                    created_at,
                    kind,
                    tags,
                    content,
                    sig: Sig(sig),
                })
            }
            Err(err) => {
                let e = json!({
                    "id": hex::encode(&id),
                    "pubkey": hex::encode(&pubkey),
                    "created_at": created_at,
                    "kind": kind,
                    "tags": tags,
                    "content": content,
                    "sig": hex::encode(&sig),
                });
                println!("{}", serde_json::to_string_pretty(&e).unwrap());
                Err(anyhow::anyhow!("error parsing tags: {err:?}, for event: {e:?}"))
            }
        }
    } else {
        Err(anyhow::anyhow!("error parsing event: {:?}", r.id.clone()))
    }
}

#[derive(Debug,Clone,Deserialize)]
pub struct Config {
    pub proxy: Option<String>,
    pub cache_database_url: String,
    pub membership_database_url: String,
    pub since: Option<String>,
    #[serde(default)]
    pub tables: Vec<String>,
    pub import_latest_t_key: String,
}

#[derive(Debug)]
pub struct State {
    pub config: Config,
    pub cache_pool: PgPool,
    pub membership_pool: PgPool,
    pub got_sig: Arc<AtomicBool>,
    pub since: i64,
    pub incremental: bool,
    pub one_day: bool,
    pub iteration_step: i64,
    pub graph_coverage: i64,
}

use std::future::Future;

use std::sync::atomic::{AtomicBool, Ordering};

pub use sqlx::Transaction;
pub use sqlx::Postgres;
pub use sqlx::Pool;
pub use sqlx::PgPool;
pub use sqlx::Executor;

pub async fn parametrized_replaceable_events(cache_pool: &PgPool, addr: &EventAddr) -> Result<Option<EventId>, anyhow::Error> {
    for r in sqlx::query!(r#"SELECT event_id FROM parametrized_replaceable_events WHERE pubkey = $1 AND kind = $2 AND identifier = $3"#,
        addr.pubkey.0, addr.kind, addr.identifier).fetch_all(cache_pool).await? {
        return Ok(r.event_id.map(EventId));
    }
    Ok(None)
}

pub async fn update_id_table(state: &State, id: i64, table_name: &str) -> anyhow::Result<()> {
    sqlx::query!(r#"
        insert into id_table (id, table_name) values ($1, $2)
        on conflict (id, table_name) do nothing
        "#, id, table_name).execute(&state.cache_pool).await?;
    Ok(())
}

pub trait Ref {
    fn to_ref(&self) -> serde_json::Value;

    fn get_ref(&self, state: &State) -> impl std::future::Future<Output = anyhow::Result<i64>> + Send {
        let rf = self.to_ref();
        async move {
            if let Some(r) = sqlx::query!(r#"
                select id from refs where ref = $1
                "#, &rf).fetch_optional(&state.cache_pool).await? 
            {
                return Ok(r.id);
            }
            let r = sqlx::query!(r#"
                insert into refs (ref) values ($1)
                on conflict (ref) do update set ref = excluded.ref
                returning (id)
                "#, &rf).fetch_one(&state.cache_pool).await?;
            Ok(r.id)
        }
    }
}

impl Ref for EventId {
    fn to_ref(&self) -> serde_json::Value {
        json!({"table": "events", "key": {"id": self}})
    }
}
impl Ref for EventAddr {
    fn to_ref(&self) -> serde_json::Value {
        json!({"table": "parametrized_replaceable_events", "key": {"kind": self.kind, "pubkey": self.pubkey, "identifier": self.identifier}})
    }
}
impl Ref for i64 {
    fn to_ref(&self) -> serde_json::Value {
        Value::Null
    }
    async fn get_ref(&self, _state: &State) -> anyhow::Result<i64> {
        Ok(*self)
    }
}

pub async fn get_edgetype<'c, E>(exe: E, name: &str) -> anyhow::Result<i64>
where E: Executor<'c, Database = Postgres> + std::marker::Copy
{
    if let Some(r) = sqlx::query!(r#"
            select id from edgetypes where name = $1
            "#, name).fetch_optional(exe).await? 
    {
        return Ok(r.id);
    }
    let r = sqlx::query!(r#"
        insert into edgetypes (name) values ($1)
        on conflict (name) do update set name = excluded.name
        returning (id)
        "#, name).fetch_one(exe).await?;
    Ok(r.id)
}

pub async fn insert_edge<'c, E>(exe: E, input_id: i64, output_id: i64, etype: Option<&str>) -> anyhow::Result<()>
where E: Executor<'c, Database = Postgres> + std::marker::Copy
{
    let etype = if let Some(etype) = etype {
        Some(get_edgetype(exe, etype).await?)
    } else {
        None
    };
    sqlx::query!(r#"INSERT INTO edges (input_id, output_id, etype) VALUES ($1, $2, $3)"#, input_id, output_id, etype).execute(exe).await?;
    Ok(())
}

pub use tokio::signal;

pub async fn shutdown_signal() {
    let mut usr1 = signal::unix::signal(signal::unix::SignalKind::user_defined1()).unwrap();
    tokio::select! {
        _ = signal::ctrl_c() => {},
        _ = usr1.recv() => {},
    }
    log!("signal received, shutting down");
}

pub use clap::Parser;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
pub struct Cli {
    #[arg(long)]
    pub config_file: Option<String>,

    #[command(subcommand)]
    pub command: Option<CliCommand>,
}

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
pub enum CliCommand {
    #[command(name = "run")]
    Run {
        #[arg(long)]
        since: Option<String>,

        #[arg(long, default_value = "false", action = clap::ArgAction::SetTrue)]
        incremental: bool,

        #[arg(long, default_value = "false", action = clap::ArgAction::SetTrue)]
        one_day: bool,

        #[arg(long, default_value = "86400")]
        iteration_step: i64,

        #[arg(long, default_value = "864000")]
        graph_coverage: i64,
    },

    #[command(name = "rename")]
    RenameTables {
        #[arg(short, long)]
        from_table_suffix: String,

        #[arg(short, long)]
        to_table_suffix: String,
    },

    #[command(name = "drop")]
    DropTables {
        #[arg(short, long)]
        table_suffix: String,
    },

    #[command(name = "truncate")]
    TruncateTables {
        #[arg(short, long, default_value="")]
        table_suffix: String,
    },

    #[command(name = "scratch")]
    Scratch {
    },
}

pub async fn main_1<H1, H2, Fut1, Fut2>(my_main: H1, my_scratch: H2) -> anyhow::Result<()>
where
  H1: Fn(Config, State) -> Fut1 + Send + Sync + 'static,
  H2: Fn(Config, State) -> Fut2 + Send + Sync + 'static,
  Fut1: Future<Output = anyhow::Result<()>> + Send + 'static,
  Fut2: Future<Output = anyhow::Result<()>> + Send + 'static,
{
    let cli = Cli::parse();

    let config_file = cli.config_file.or(std::env::var("CONFIG_FILE").ok()).expect("config file is required");
    let config_str = tokio::fs::read_to_string(config_file).await.expect("config file read error");
    let config: Config = serde_json::from_str(&config_str).expect("config file parse error");

    match cli.command {
        Some(CliCommand::RenameTables { from_table_suffix, to_table_suffix }) => {
            let pool: Pool<Postgres> = PoolOptions::new()
                .max_connections(1)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;

            let mut tx = pool.begin().await?;
            for table in config.tables.iter() {
                let table_without_schema = table.split('.').next_back().unwrap_or(table);
                let q = &format!("ALTER TABLE {}{} RENAME TO {}{}", table, from_table_suffix, table_without_schema, to_table_suffix);
                println!("{q}");
                sqlx::query(q).execute(&mut *tx).await?;
            }
            tx.commit().await?;
            log!("tables renamed successfully");
            return Ok(());
        },
        Some(CliCommand::DropTables { table_suffix }) => {
            let pool: Pool<Postgres> = PoolOptions::new()
                .max_connections(1)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;

            let mut tx = pool.begin().await?;
            for table in config.tables.iter() {
                let q = &format!("DROP TABLE IF EXISTS {}{}", table, table_suffix);
                println!("{q}");
                sqlx::query(q).execute(&mut *tx).await?;
            }
            tx.commit().await?;
            log!("tables dropped successfully");
            return Ok(());
        },
        Some(CliCommand::TruncateTables { table_suffix }) => {
            let pool: Pool<Postgres> = PoolOptions::new()
                .max_connections(1)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;

            let mut tx = pool.begin().await?;
            for table in config.tables.iter() {
                let q = &format!("TRUNCATE {}{}", table, table_suffix);
                println!("{q}");
                sqlx::query(q).execute(&mut *tx).await?;
            }
            tx.commit().await?;
            log!("tables truncated successfully");
            return Ok(());
        },
        Some(CliCommand::Run { since, incremental: _, one_day, iteration_step, graph_coverage }) => {
            let since = if let Some(since) = since {
                since
            } else if let Some(since) = config.since.clone() {
                since
            } else {
                "2023-01-01".to_string()
            };

            let since = if let Ok(ts) = chrono::NaiveDate::parse_from_str(&since, "%Y-%m-%d") {
                ts.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp()
            } else {
                anyhow::bail!("invalid since date format");
            };

            let cache_pool = PoolOptions::new()
                .max_connections(10)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;
            let membership_pool = PoolOptions::new()
                .max_connections(10)
                .min_connections(1)
                .connect(&config.membership_database_url).await?;

            let since = get_var(&cache_pool, &config.import_latest_t_key).await?.and_then(|r| r.as_i64()).unwrap_or(since);

            let state = State {
                config: config.clone(),
                cache_pool,
                membership_pool,
                got_sig: make_got_sig(), 
                since,
                incremental: true,
                one_day, 
                iteration_step,
                graph_coverage,
            };

            my_main(config, state).await?
        },
        Some(CliCommand::Scratch { }) => {
            let cache_pool = PoolOptions::new()
                .max_connections(10)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;
            let membership_pool = PoolOptions::new()
                .max_connections(10)
                .min_connections(1)
                .connect(&config.membership_database_url).await?;

            let state = State {
                config: config.clone(),
                cache_pool,
                membership_pool,
                got_sig: make_got_sig(), 
                since: 0,
                incremental: true,
                one_day: false, 
                iteration_step: 0,
                graph_coverage: 0,
            };
            my_scratch(config, state).await?
        },
        None => {
            log!("no command provided, exiting.");
            return Ok(());
        }
    }

    Ok(())
}

fn make_got_sig() -> Arc<AtomicBool> {
    let got_sig = Arc::new(AtomicBool::new(false));
    let watcher = got_sig.clone();
    tokio::spawn(async move {
        tokio::signal::ctrl_c().await.expect("failed to install Ctrl+C handler");
        println!("interrupted, stopping...");
        watcher.store(true, Ordering::SeqCst);
    });
    got_sig
}

pub async fn get_var(pool: &Pool<Postgres>, key: &str) -> anyhow::Result<Option<Value>> {
    Ok(sqlx::query!(r#"select value from vars where key = $1"#, key).fetch_optional(pool).await?.map(|r| r.value))
}

pub async fn set_var(pool: &Pool<Postgres>, key: &str, value: Value) -> anyhow::Result<()> {
    sqlx::query!(
        r#"insert into vars values ($1, $2, now()) on conflict (key) do update set value = $2, updated_at = now()"#,
        key, value).fetch_all(pool).await?;
    Ok(())
}

