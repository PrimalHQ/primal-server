use std::collections::{HashMap, HashSet};
use std::sync::atomic::AtomicI64;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
use serde_json::{Value, json};
use primal_cache::{EventAddr, PubKeyId};
use crate::connector::connection::MessageSink;
use futures_util::stream::SplitSink;
use tokio_tungstenite::WebSocketStream;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;

// type WS = Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>;
type WS = Arc<Mutex<MessageSink<SplitSink<WebSocketStream<TcpStream>, Message>>>>;
pub type SubscriptionId = String;
pub type WebSocketId = i64;
pub type ContentModerationMode = String;

#[derive(Debug)]
pub struct ReqError {
    pub description: String,
}

impl std::fmt::Display for ReqError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "ReqError: {}", self.description)
    }
}

impl From<&str> for ReqError {
    fn from(v: &str) -> Self {
        ReqError { description: v.to_string() }
    }
}

impl From<hex::FromHexError> for ReqError {
    fn from(v: hex::FromHexError) -> Self {
        ReqError { description: format!("{}", v) }
    }
}

impl From<tokio_postgres::Error> for ReqError {
    fn from(v: tokio_postgres::Error) -> Self {
        ReqError { description: format!("{}", v) }
    }
}

pub enum ReqStatus {
    Handled,
    NotHandled,
    Notice(String),
}

impl From<&str> for ReqStatus {
    fn from(v: &str) -> Self {
        ReqStatus::Notice(v.to_string())
    }
}

pub struct KeyedSubscriptions<K, ExtraData> {
    pub key_to_subs: HashMap<K, HashMap<(WebSocketId, SubscriptionId), ExtraData>>,
    pub sub_to_key: HashMap<(WebSocketId, SubscriptionId), K>,
}

impl<K: Clone + Eq + std::hash::Hash, ExtraData: Eq + std::hash::Hash> KeyedSubscriptions<K, ExtraData> {
    pub fn new() -> Self {
        Self { key_to_subs: HashMap::new(), sub_to_key: HashMap::new() }
    }
    
    pub fn register(&mut self, ws_id: WebSocketId, sub_id: SubscriptionId, key: K, extra_data: ExtraData) {
        if !self.key_to_subs.contains_key(&key.clone()) {
            self.key_to_subs.insert(key.clone(), HashMap::new());
        }
        if let Some(subs) = self.key_to_subs.get_mut(&key.clone()) {
            subs.insert((ws_id, sub_id.clone()), extra_data);
        }

        self.sub_to_key.insert((ws_id, sub_id.clone()), key);
    }
    
    pub fn unregister(&mut self, ws_id: WebSocketId, sub_id: SubscriptionId) {
        if let Some(key) = self.sub_to_key.remove(&(ws_id, sub_id.clone())) {
            if let Some(subs) = self.key_to_subs.get_mut(&key) {
                subs.remove(&(ws_id, sub_id));
                if subs.is_empty() {
                    self.key_to_subs.remove(&key);
                }
            }
        }
    }
}

pub struct Stats {
    pub recvmsgcnt: AtomicI64,
    pub sendmsgcnt: AtomicI64,
    pub proxyreqcnt: AtomicI64,
    pub handlereqcnt: AtomicI64,
    pub connections: AtomicI64,
    pub recveventcnt: AtomicI64,
    pub importeventcnt: AtomicI64,
}

#[derive(Debug, Default)]
pub struct LogEntry {
    pub run: i64,
    pub task: i64,
    pub tokio_task: i64,
    pub info: Value,
    pub func: Option<String>,
    pub conn_id: Option<i64>,
}

impl LogEntry {
    pub fn new(func: &str, info: Value, run: i64, task_id: i64, conn_id: Option<i64>) -> Self {
        LogEntry {
            run,
            task: task_id,
            tokio_task: get_tokio_task_id(),
            info,
            func: Some(func.to_string()),
            conn_id,
        }
    }
}

pub struct SharedState {
    pub stats: Stats,
    pub default_app_settings_filename: String,
    pub app_releases_filename: String,
    pub srv_name: Option<String>,
    pub primal_pubkey: Option<Vec<u8>>,
    pub shutting_down: bool,
    pub logging_enabled: bool,
    pub idle_connection_timeout: u64,
    pub log_sender_batch_size: usize,
    pub logtx: Option<mpsc::Sender<LogEntry>>,
    pub run: i64,
    pub task_index: i64,
    pub conn_index: i64,
    pub tasks: HashMap<i64, i64>,
    pub conns: HashMap<i64, i64>,
}

pub fn parse_tokio_task_id(task_id: tokio::task::Id) -> i64 {
    format!("{}", task_id).parse::<i64>().unwrap() 
}

pub fn get_tokio_task_id() -> i64 {
    tokio::task::try_id().map(|v| parse_tokio_task_id(v)).unwrap_or(0)
}

pub fn get_sys_time_in_secs() -> u64 {
    use std::time::SystemTime;
    match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(n) => n.as_secs(),
        Err(_) => panic!("SystemTime before UNIX EPOCH!"),
    }
}

pub struct State {
    pub shared: SharedState,
    pub websockets: HashMap<WebSocketId, WS>,
    pub ws_to_subs: HashMap<WebSocketId, std::collections::HashSet<SubscriptionId>>,
    pub subs_to_ws: HashMap<(WebSocketId, SubscriptionId), WebSocketId>,
    pub live_events: KeyedSubscriptions<EventAddr, (PubKeyId, ContentModerationMode)>,
    pub live_events_from_follows: KeyedSubscriptions<PubKeyId, ()>,
}

pub fn register_subscription(
    state: &mut State, ws_id: WebSocketId, sub_id: SubscriptionId,
) {
    if !state.ws_to_subs.contains_key(&ws_id) {
        state.ws_to_subs.insert(ws_id, HashSet::new());
    }
    if let Some(subs) = state.ws_to_subs.get_mut(&ws_id) {
        subs.insert(sub_id.clone());
    }

    state.subs_to_ws.insert((ws_id, sub_id.clone()), ws_id);
}

pub struct TaskTrace {
    func: String,
    #[allow(dead_code)]
    task_id: i64,
    tokio_task_id: i64,
    state: Arc<Mutex<State>>,
}

pub async fn send_log(tokio_task_id: i64, func: &str, info: Value, state: &Arc<Mutex<State>>) {
    let state = state.lock().await;
    if state.shared.logging_enabled {
        if let Some(logtx) = &state.shared.logtx {
            let task_id = *state.shared.tasks.get(&tokio_task_id).unwrap_or(&(-1 as i64));
            let conn_id = state.shared.conns.get(&tokio_task_id).map(|x| *x);
            let _ = logtx.send(LogEntry::new(func, info, state.shared.run, task_id, conn_id)).await;
        }
    }
}

impl TaskTrace {
    pub async fn new(func: &str, conn_id: Option<i64>, state: &Arc<Mutex<State>>) -> Self {
        let tt = {
            let state_ = state;
            let mut state = state.lock().await;
            state.shared.task_index += 1;
            let task_id = state.shared.task_index;
            let tokio_task_id = get_tokio_task_id();
            state.shared.tasks.insert(tokio_task_id, task_id);
            if let Some(conn_id) = conn_id {
                state.shared.conns.insert(tokio_task_id, conn_id);
            }
            Self {
                func: func.to_string(),
                task_id,
                tokio_task_id,
                state: state_.clone(),
            }
        };
        send_log(tt.tokio_task_id, func, json!({"event": "task-start"}), state).await;
        tt
    }
}

impl Drop for TaskTrace {
    fn drop(&mut self) {
        let state = self.state.clone();
        let tokio_task_id = self.tokio_task_id;
        let func = self.func.clone();
        tokio::spawn(async move {
            send_log(tokio_task_id, &func, json!({"event": "task-stop"}), &state).await;
            let mut state = state.lock().await;
            state.shared.tasks.remove(&tokio_task_id);
        });
    }
}
