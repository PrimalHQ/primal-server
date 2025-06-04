#![allow(unused)]

pub use tower_http::trace::{DefaultMakeSpan, DefaultOnResponse, TraceLayer};
pub use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};
pub use std::sync::Arc;

pub use hex::FromHex;
pub use sqlx::PgPool;
pub use sqlx::pool::PoolOptions;

pub use hex;

pub use std::str::FromStr;

pub use nostr_sdk::prelude::{PublicKey, JsonUtil};

pub use serde_json::Value;
pub use serde_json::json;

use std::fmt;

use sha2::{Sha256, Digest};
use futures::stream::{StreamExt, iter};

use std::collections::HashMap;

// ------------------ log ---------------------

pub fn log(s: String) {
    // return;
    println!("{} [{}]  {}", 
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S.%6f"), 
        std::process::id(), 
        s);
}

#[macro_export]
macro_rules! log {
    // match: log!( "foo" )
    ($msg:expr) => {
        $crate::log(format!($msg))
    };
    // match: log!( "foo {} {}", a, b )
    ($fmt:expr, $($arg:tt)+) => {
        $crate::log(format!($fmt, $($arg)+))
    };
}

pub fn logerr<T>(e: T)
where
    T: std::fmt::Debug,
{
    log!("{e:?}");
}

pub fn loge<T, R>(res: R) -> impl Fn(T) -> R
where
    T: std::fmt::Debug,
    R: std::clone::Clone
{
    move |e: T| {
        log!("{e:?}");
        res.clone()
    }
}

pub trait ResultLogErr<T, E, R> {
    fn map_log_err(self, r: R) -> Result<T, R>;
}

impl<T, E, R> ResultLogErr<T, E, R> for Result<T, E>
where
    E: std::fmt::Debug,
    R: std::clone::Clone
{
    fn map_log_err(self, r: R) -> Result<T, R> {
        self.map_err(|e| {
            log!("{e:?}");
            r
        })
    }
}


// ------------------ main ---------------------

use serde::{Deserialize, Serialize};

#[derive(Debug,Clone,Deserialize)]
pub struct Config {
    pub proxy: Option<String>,
    pub cache_database_url: String,
    pub membership_database_url: String,
    pub since: Option<String>,
    #[serde(default)]
    pub tables: Vec<String>,
}

#[derive(Debug,Clone)]
pub struct State {
    pub cache_pool: PgPool,
    pub membership_pool: PgPool,
    pub since: i64,
    pub incremental: bool,
}

use std::future::Future;

use std::sync::atomic::{AtomicBool, Ordering};
use tokio::signal::unix::{signal, SignalKind};
use tokio::time::sleep;

use tokio::sync::Mutex;
use std::time::Instant;
use std::time::Duration;

pub use sqlx::Transaction;
pub use sqlx::Postgres;
pub use sqlx::Pool;
pub use sqlx::Executor;

use tokio::sync::mpsc::{self, Sender};

use serde::Serializer;

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct EventId(pub Vec<u8>);

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct PubKeyId(pub Vec<u8>);

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct Sig(pub Vec<u8>);

impl Default for EventId {
    fn default() -> Self {
        EventId(vec![0; 32])
    }
}
impl Default for PubKeyId {
    fn default() -> Self {
        PubKeyId(vec![0; 32])
    }
}
impl Default for Sig {
    fn default() -> Self {
        Sig(vec![0; 64])
    }
}

macro_rules! impl_traits {
    ($($name:ident),+) => {
        $(
            impl serde::Serialize for $name {
                fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
                where
                    S: serde::Serializer,
                {
                    let hex = hex::encode(&self.0);
                    serializer.serialize_str(&hex)
                }
            }
            impl fmt::Debug for $name {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    let hex = hex::encode(&self.0);
                    write!(f, "\"{hex}\"")
                }
            }
            impl $name {
                pub fn from_hex(hex: &str) -> Result<Self, anyhow::Error> {
                    let bytes = Vec::from_hex(hex)?;
                    Ok($name(bytes))
                }
            }
            impl From<Vec<u8>> for $name {
                fn from(v: Vec<u8>) -> Self {
                    $name(v)
                }
            }
        )*
    };
}

impl_traits!(EventId, PubKeyId, Sig);

#[derive(PartialEq, Eq, Serialize, Debug, Hash, Clone)]
pub struct EventAddr {
    pub kind: i64,
    pub pubkey: PubKeyId,
    pub identifier: String,
}

impl EventAddr {
    pub fn new(kind: i64, pubkey: PubKeyId, identifier: String) -> Self {
        EventAddr { kind, pubkey, identifier }
    }
}

#[derive(PartialEq, Eq, Hash, Clone, Debug)]
pub enum EventReference {
    EventId(EventId),
    EventAddr(EventAddr),
}

#[derive(Debug, Serialize, Clone)]
pub enum Tag {
    EventId(EventId, Vec<String>),
    PubKeyId(PubKeyId, Vec<String>),
    EventAddr(EventAddr, Vec<String>),
    Any(Vec<String>),
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct Event {
    pub id: EventId,
    pub pubkey: PubKeyId,
    pub created_at: i64,
    pub kind: i64,
    pub tags: Vec<Tag>,
    pub content: String,
    pub sig: Sig,
}

pub fn parse_tags(tags: &Value) -> Result<Vec<Tag>, anyhow::Error> {
    let mut result = Vec::new();
    if let Some(arr) = tags.as_array() {
        for tag in arr {
            if let Some(tag_arr) = tag.as_array() {
                if tag_arr.len() > 0 {
                    let tag_data = tag_arr.iter()
                        .filter_map(|v| v.as_str())
                        .map(|s| s.to_string())
                        .collect::<Vec<_>>();
                    match tag_data[0].as_str() {
                        "e" if tag_data.len() >= 2 => {
                            if let Ok(eid) = EventId::from_hex(&tag_data[1]) {
                                result.push(Tag::EventId(eid, tag_data[2..].to_vec()));
                            }
                        }
                        "p" if tag_data.len() >= 2 => {
                            if let Ok(pk) = PubKeyId::from_hex(&tag_data[1]) {
                                result.push(Tag::PubKeyId(pk, tag_data[2..].to_vec()));
                            }
                        }
                        "a" if tag_data.len() >= 2 => {
                            let parts = tag_data[1].split(':').collect::<Vec<_>>();
                            if parts.len() == 3 {
                                if let (Ok(kind), Ok(pubkey)) = (parts[0].parse::<i64>(), PubKeyId::from_hex(parts[1])) {
                                    result.push(Tag::EventAddr(EventAddr {
                                        kind, pubkey, identifier: parts[2].to_string(),
                                    }, tag_data[2..].to_vec()));
                                }
                            }
                        }
                        _ => result.push(Tag::Any(tag_data)),
                    }
                }
            }
        }
    }
    Ok(result)
}

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
            self.map.insert(key.clone(), value);
            self.window.insert(self.next, key.clone());
            self.next += 1;
        }
        self.get_mut(key).unwrap()
    }
    pub fn maintain_capacity(&mut self, max_capacity: i64) -> Vec<V> {
        let cap = std::cmp::min(self.capacity, max_capacity);
        let mut removed = Vec::new();
        while self.next - self.oldest > cap {
            if let Some(old_key) = self.window.remove(&self.oldest) {
                if let Some(v) = self.map.remove(&old_key) {
                    removed.push(v);
                } else {
                    println!("KeyedStats: remove failed for key {old_key:?}");
                }
            }
            self.oldest += 1;
        }
        removed
    }
}

pub const TEXT_NOTE: i64 = 1;
pub const REPOST: i64 = 6;
pub const REACTION: i64 = 7;
pub const ZAP_RECEIPT: i64 = 9735;
pub const LONG_FORM_CONTENT: i64 = 30023;
pub const BOOKMARKS: i64 = 10003;

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

pub async fn parse_event(r: EventRow) -> Result<Event, anyhow::Error> {
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

pub fn event_to_json(e: &Event) -> Value {
    json!({
        "id": hex::encode(&e.id),
        "pubkey": hex::encode(&e.pubkey),
        "created_at": e.created_at,
        "kind": e.kind,
        "tags": e.tags.iter()
            .map(|tag| tag.clone().into_vec())
            .collect::<Vec<_>>(),
        "content": e.content,
        "sig": hex::encode(&e.sig),
    })
}

impl Tag {
    pub fn into_vec(self) -> Vec<String> {
        match self {
            Tag::EventId(eid, tag_data) => {
                let mut vec = vec![String::from("e"), hex::encode(&eid)];
                vec.extend(tag_data);
                vec
            }
            Tag::PubKeyId(pkid, tag_data) => {
                let mut vec = vec![String::from("p"), hex::encode(&pkid)];
                vec.extend(tag_data);
                vec
            }
            Tag::EventAddr(addr, tag_data) => {
                let mut vec = vec![String::from("a"), format!("{}:{}:{}", addr.kind, hex::encode(&addr.pubkey), addr.identifier)];
                vec.extend(tag_data);
                vec
            }
            Tag::Any(tag_data) => tag_data,
        }
    }
}

impl AsRef<[u8]> for EventId {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}
impl AsRef<[u8]> for PubKeyId {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}
impl AsRef<[u8]> for Sig {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

pub async fn parametrized_replaceable_events(cache_pool: &PgPool, addr: &EventAddr) -> Result<Option<EventId>, anyhow::Error> {
    for r in sqlx::query!(r#"SELECT event_id FROM parametrized_replaceable_events WHERE pubkey = $1 AND kind = $2 AND identifier = $3"#,
        addr.pubkey.0, addr.kind, addr.identifier).fetch_all(cache_pool).await? {
        return Ok(r.event_id.map(|eid| EventId(eid)));
    }
    Ok(None)
}

pub async fn parse_parent_eid(e: &Event) -> Result<Option<EventReference>, anyhow::Error> {
    // async fn f(tags: &Vec<Tag>, cb: impl Fn(&Vec<String>) -> bool) -> Result<Option<EventId>, anyhow::Error> {
    //     for tag in tags {
    //         match tag {
    //             Tag::EventId(eid, tag_data) if cb(tag_data) => {
    //                 return Ok(Some(eid.clone()));
    //             }
    //             Tag::EventAddr(addr, tag_data) if cb(tag_data) => {
    //                 if let Some(eid) = parametrized_replaceable_events(addr).await? {
    //                     return Ok(Some(eid.clone()));
    //                 }
    //             }
    //             _ => { },
    //         }
    //     }
    //     Ok(None)
    // }
    async fn f(tags: &Vec<Tag>, cb: impl Fn(&Vec<String>) -> bool) -> Result<Option<EventReference>, anyhow::Error> {
        for tag in tags {
            match tag {
                Tag::EventId(eid, tag_data) if cb(tag_data) => {
                    return Ok(Some(EventReference::EventId(eid.clone())));
                }
                Tag::EventAddr(addr, tag_data) if cb(tag_data) => {
                    return Ok(Some(EventReference::EventAddr(addr.clone())));
                }
                _ => { },
            }
        }
        Ok(None)
    }

    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && tag_data[1] == "reply"
    }).await?;
    if parent_eid.is_some() { return Ok(parent_eid); }
    
    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && tag_data[1] == "root"
    }).await?;
    if parent_eid.is_some() { return Ok(parent_eid); }

    let parent_eid = f(&e.tags, |tag_data| {
        tag_data.len() >= 2 && (tag_data.len() < 2 || tag_data[1] != "mention")
    }).await?;
    if parent_eid.is_some() { return Ok(parent_eid); }

    Ok(parent_eid)
}

#[derive(Debug)]
pub struct ZapReceipt {
    pub sender_pubkey: PubKeyId,
    pub receiver_pubkey: PubKeyId,
    pub amount_msats: i64,
    pub event: Option<EventReference>,
}

pub fn parse_zap_receipt(e: &Event) -> Option<ZapReceipt> {
    if e.kind != ZAP_RECEIPT {
        return None;
    }

    let mut sender_pubkey: Option<PubKeyId> = None;
    let mut receiver_pubkey: Option<PubKeyId> = None;
    let mut amount_msats: Option<i64> = None;
    let mut event: Option<EventReference> = None;

    for tag in &e.tags {
        match tag {
            Tag::PubKeyId(pk, tag_data) => {
                receiver_pubkey = Some(pk.clone());
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "P" => {
                if let Ok(pk) = PubKeyId::from_hex(&tag_data[1]) {
                    sender_pubkey = Some(pk);
                }
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "bolt11" => {
                amount_msats = tag_data[1].parse::<lightning_invoice::Bolt11Invoice>().ok()
                    .and_then(|i| i.amount_milli_satoshis()).and_then(|a| a.try_into().ok());
            }
            Tag::Any(tag_data) if tag_data.len() >= 2 && tag_data[0] == "description" => {
                if let Ok(json) = serde_json::from_str::<Value>(&tag_data[1]) {
                    if let Some(pubkey_str) = json.get("pubkey").and_then(|v| v.as_str()) {
                        if let Ok(pk) = PubKeyId::from_hex(pubkey_str) {
                            sender_pubkey = Some(pk);
                        }
                    }
                }
            }
            Tag::EventId(eid, _) => {
                event = Some(EventReference::EventId(eid.clone()));
            }
            Tag::EventAddr(eaddr, _) => {
                event = Some(EventReference::EventAddr(eaddr.clone()));
            }
            _ => {}
        }
    }

    if let (Some(sender_pubkey), Some(receiver_pubkey), Some(amount_msats)) = (sender_pubkey, receiver_pubkey, amount_msats) {
        Some(ZapReceipt { sender_pubkey, receiver_pubkey, amount_msats, event })
    } else {
        None
    }
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

// ------------------ cli ---------------------

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

        #[arg(short, long, default_value = "false", action = clap::ArgAction::SetTrue)]
        incremental: bool,
    },

    #[command(name = "deploy")]
    Rename {
        #[arg(long)]
        from_table_suffix: String,

        #[arg(long)]
        to_table_suffix: String,
    },
}

pub async fn main_1<H, Fut>(my_main: H) -> anyhow::Result<()>
where
  H: Fn(Config, State) -> Fut + Send + Sync + 'static,
  Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
{
    let cli = Cli::parse();

    let config_file = cli.config_file.or(std::env::var("CONFIG_FILE").ok()).expect("config file is required");
    let config_str = tokio::fs::read_to_string(config_file).await.expect("config file read error");
    let config: Config = serde_json::from_str(&config_str).expect("config file parse error");

    match cli.command {
        Some(CliCommand::Rename { from_table_suffix, to_table_suffix }) => {
            let pool: Pool<Postgres> = PoolOptions::new()
                .max_connections(1)
                .min_connections(1)
                .connect(&config.cache_database_url).await?;

            let mut tx = pool.begin().await?;
            for table in config.tables.iter() {
                sqlx::query(&format!("ALTER TABLE {}{} RENAME TO {}{}", table, from_table_suffix, table, to_table_suffix)).execute(&mut *tx).await?;
            }
            tx.commit().await?;
            log!("tables renamed successfully");
            return Ok(());
        },
        Some(CliCommand::Run { since, incremental }) => {
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

            let state = State {
                cache_pool: PoolOptions::new()
                    .max_connections(10)
                    .min_connections(1)
                    .connect(&config.cache_database_url).await?,
                membership_pool: PoolOptions::new()
                    .max_connections(10)
                    .min_connections(1)
                    .connect(&config.membership_database_url).await?,
                since,
                incremental,
            };

            my_main(config, state).await?
        },
        None => {
            log!("no command provided, exiting.");
            return Ok(());
        }
    }

    return Ok(());
}

