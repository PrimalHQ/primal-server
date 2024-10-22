use std::{env, io::Error};
use std::time::{SystemTime};
use tokio::time;
use tokio::time::timeout;

use futures_util::Future;
use futures_util::{StreamExt, SinkExt};
use futures_util::stream::SplitSink;
use futures_util::FutureExt;
use futures::sink::Sink;
use log::{info, error};
use tokio::net::{TcpStream, TcpSocket};
use tokio::sync::Mutex;
use tokio::signal::unix::{signal, SignalKind};
use tokio::time::{sleep, Duration};
use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::sync::atomic::Ordering;
use tokio::sync::mpsc;

use std::os::fd::AsRawFd;

use serde_json::Value;
use serde_json::json;

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod, Client};
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;

use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message::{Text, Binary};
use tokio_tungstenite::tungstenite::Message;

use measure_time::info_time;

use std::io::prelude::Write;
use flate2::Compression;
use flate2::write::ZlibEncoder;

use std::marker::{Unpin, PhantomData};
use std::fmt::{Debug, Display};

use hex::FromHexError;

use clap::{Parser, Subcommand};

use std::collections::HashMap;

use ::function_name::named;

const POOL_GET_TIMEOUT: u64 = 1;

struct Stats {
    recvmsgcnt: AtomicI64,
    sendmsgcnt: AtomicI64,
    proxyreqcnt: AtomicI64,
    handlereqcnt: AtomicI64,
    connections: AtomicI64,
}

struct State {
    stats: Stats,

    default_app_settings: Option<String>,
    app_releases: Option<String>,

    srv_name: Option<String>,

    primal_pubkey: Option<Vec<u8>>,

    shutting_down: bool,

    logging_enabled: bool,
    idle_connection_timeout: u64,
    log_sender_batch_size: usize,

    logtx: Option<mpsc::Sender<LogEntry>>,

    run: i64,
    task_index: i64,
    conn_index: i64,
    tasks: HashMap<i64, i64>, // tokio_task_id -> task_id
    conns: HashMap<i64, i64>, // tokio_task_id -> conn_id
}

struct MessageSink<T: Sink<Message>> {
    use_zlib: bool,
    // sink: SplitSink<WebSocketStream<TcpStream>, Message>,
    sink: T,
}

type ClientWrite<T> = Arc<Mutex<MessageSink<T>>>;

struct FunArgs<'a, T: Sink<Message>> {
    state: &'a Arc<Mutex<State>>,
    subid: &'a str,
    kwargs: &'a Value,
    pool: &'a Pool,
    membership_pool: &'a Pool,
    client_write: &'a ClientWrite<T>,
}

struct ReqHandlers<T: Sink<Message>> {
    t: PhantomData<T>,
}

#[derive(Debug)]
struct ReqError {
    description: String,
}

impl Display for ReqError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "ReqError: {}", self.description)
    }
}

impl From<&str> for ReqError {
    fn from(v: &str) -> Self {
        ReqError { description: v.to_string(), }
    }
}
impl From<FromHexError> for ReqError {
    fn from(v: FromHexError) -> Self {
        ReqError { description: format!("{}", v), }
    }
}
impl From<tokio_postgres::Error> for ReqError {
    fn from(v: tokio_postgres::Error) -> Self {
        ReqError { description: format!("{}", v), }
    }
}

enum ReqStatus {
    Handled,
    NotHandled,
    Notice(String),
}
use crate::ReqStatus::*;
impl From<&str> for ReqStatus {
    fn from(v: &str) -> Self {
        Notice(v.to_string())
    }
}

#[derive(Debug, Default)]
struct LogEntry {
    run: i64,
    task: i64,
    tokio_task: i64,
    info: Value,
    func: Option<String>,
    conn_id: Option<i64>,
}
impl LogEntry {
    fn new(func: &str, info: Value, run: i64, task_id: i64, conn_id: Option<i64>) -> Self {
        let tokio_task_id = get_tokio_task_id();
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

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[arg(short, long)]
    servername: String,

    #[arg(short, long, default_value="100")]
    log_sender_batch_size: usize,

    #[arg(short, long, default_value="/home/pr/work/itk/primal/content-moderation")]
    content_moderation_root: String,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Run {
        #[arg(short, long)]
        port: i32,
    },
    Req {
        #[arg(short, long)]
        msg: String,
    },
}

struct TaskTrace {
    func: String,
    task_id: i64,
    tokio_task_id: i64,
    state: Arc<Mutex<State>>,
}

async fn send_log(tokio_task_id: i64, func: &str, info: Value, state: &Arc<Mutex<State>>) {
    let state = state.lock().await;
    if state.logging_enabled {
        if let Some(logtx) = &state.logtx {
            let task_id = *state.tasks.get(&tokio_task_id).unwrap_or(&(-1 as i64));
            let conn_id = state.conns.get(&tokio_task_id).map(|x| *x);
            logtx.send(LogEntry::new(func, info, state.run, task_id, conn_id)).await;
        }
    }
}

impl TaskTrace {
    async fn new(func: &str, conn_id: Option<i64>, state: &Arc<Mutex<State>>) -> Self {
        let tt = {
            let state_ = state;
            let mut state = state.lock().await;
            state.task_index += 1;
            let task_id = state.task_index;
            let tokio_task_id = get_tokio_task_id();
            state.tasks.insert(tokio_task_id, task_id);
            if let Some(conn_id) = conn_id {
                state.conns.insert(tokio_task_id, conn_id);
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
            state.tasks.remove(&tokio_task_id);
        });
    }
}

fn parse_tokio_task_id(task_id: tokio::task::Id) -> i64 {
    format!("{}", task_id).parse::<i64>().unwrap() 
}

fn get_tokio_task_id() -> i64 {
    tokio::task::try_id().map(|v| parse_tokio_task_id(v)).unwrap_or(0)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
// #[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    let _ = env_logger::try_init();

    let cli = Cli::parse();

    let state = Arc::new(Mutex::new(State {
        stats: Stats {
            recvmsgcnt: AtomicI64::new(0),
            sendmsgcnt: AtomicI64::new(0),
            proxyreqcnt: AtomicI64::new(0),
            handlereqcnt: AtomicI64::new(0),
            connections: AtomicI64::new(0),
        },

        default_app_settings: None,
        app_releases: None,

        srv_name: Some(cli.servername),

        primal_pubkey: Some(hex::decode("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb").unwrap()),

        shutting_down: false,

        logging_enabled: false,
        idle_connection_timeout: 600,
        log_sender_batch_size: cli.log_sender_batch_size,

        logtx: None,

        run: 0,
        task_index: 0,
        conn_index: 0,
        tasks: HashMap::new(),
        conns: HashMap::new(),
    }));

    {
        let mut state = state.lock().await;
        state.default_app_settings = Some(std::fs::read_to_string(format!("{}/default-settings.json", cli.content_moderation_root)).unwrap());
        state.app_releases = Some(std::fs::read_to_string(format!("{}/app-releases.json", cli.content_moderation_root)).unwrap());
    }

    let management_pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 4);
    let pool            = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 16);
    let membership_pool = make_dbconn_pool("192.168.11.7", 5432, "primal", "primal", 16);

    {
        let mut state = state.lock().await;
        state.run = management_pool.get().await.unwrap().query_one(
            "insert into wsconnruns values (default, now(), $1, $2) returning run", 
            &[&state.srv_name, &(0 as i64)]).await.unwrap().get::<_, i64>(0);
        println!("run: {}", state.run);
    }

    update_management_settings(&state, &management_pool).await;

    let (logtx, mut logrx) = mpsc::channel(10000);
    state.lock().await.logtx = Some(logtx);

    tokio::task::spawn(management_task(state.clone(), management_pool.clone()));

    tokio::task::spawn(log_task(state.clone(), logrx, management_pool.clone()));

    {
        let state = state.clone();
        let pool = pool.clone();
        let membership_pool = membership_pool.clone();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("print-status", None, &state).await;
            let mut interval = time::interval(Duration::from_millis(1000));
            loop {
                interval.tick().await;
                print_status(&state.lock().await.stats, &pool, &membership_pool);
            }
        });
    }

    {
        let state = state.clone();
        let mut sig = signal(SignalKind::user_defined1()).unwrap();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("usr1-sig-recv", None, &state).await;
            sig.recv().await;
            println!("got signal USR1, shutting down");
            state.lock().await.shutting_down = true;
        });
    }

    {
        let state = state.clone();
        let mut sig = signal(SignalKind::user_defined2()).unwrap();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("usr2-sig-recv", None, &state).await;
            loop {
                sig.recv().await;
                println!("got signal USR2");
                runtime_dump().await;
            }
        });
    }

    match &cli.command {
        Some(Commands::Run { port }) => {
            {
                let state = state.clone();

                let wsconn_processor = WSConnProcessor {
                    state: state.clone(),
                };

                let factory = Arc::new(WSConnHandlerFactory {
                    processor: Arc::new(wsconn_processor),
                });

                let server_addr = format!("127.0.0.1:{}", port+5000);
                let listener = TcpListener::bind(server_addr.clone()).await.unwrap();
                println!("pgwire listening on {}", server_addr);
                tokio::spawn(async move {
                    let _tt = TaskTrace::new("pgwire-listener", None, &state).await;
                    loop {
                        let incoming_socket = listener.accept().await.unwrap();
                        let factory_ref = factory.clone();
                        tokio::spawn(async move { pgwire::tokio::process_socket(incoming_socket.0, None, factory_ref).await });
                    }
                });
            }

            let addr = format!("0.0.0.0:{}", port);

            let sa = addr.parse().unwrap();
            let socket = TcpSocket::new_v4().unwrap();
            socket.set_reuseaddr(true).unwrap();
            socket.set_reuseport(true).unwrap();
            socket.bind(sa).expect("failed to bind");

            let listener = socket.listen(1024).unwrap();

            info!("listening on: {}", addr);

            let fd = listener.as_raw_fd();
            while !{ state.lock().await.shutting_down } {
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let pool = pool.clone();
                        let membership_pool = membership_pool.clone();
                        tokio::spawn(accept_websocket_connection(stream, state.clone(), pool, membership_pool));
                    },
                    Err(err) => {
                        println!("accept loop: {:?}", err);
                        break;
                    }
                }
            }
            unsafe { libc::shutdown(fd, libc::SHUT_RD); }

            println!("waiting some time for remaining requests to complete");
            sleep(Duration::from_millis(5000)).await;
        },

        Some(Commands::Req { msg }) => {
            let msg = Message::Text(msg.to_string());

            let client_write = Arc::new(Mutex::new(MessageSink {
                use_zlib: false,
                sink: Vec::new(),
            }));

            if handle_req(&state, &msg, &client_write, &pool, &membership_pool).await {
                incr(&state.lock().await.stats.handlereqcnt);
            }

            for r in &client_write.lock().await.sink {
                println!("{}", r);
            }

            print_status(&state.lock().await.stats, &pool, &membership_pool);
        },

        None => { },
    };

    Ok(())
}

fn make_dbconn_pool(host: &str, port: u16, username: &str, dbname: &str, size: usize) -> Pool {
    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host(host);
    pg_config.port(port);
    pg_config.user(username);
    pg_config.dbname(dbname);
    let mgr_config = ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    };
    let mgr = Manager::from_config(pg_config, NoTls, mgr_config);
    Pool::builder(mgr).max_size(size).build().unwrap()
}

async fn read_var(management_pool: &Pool, name: &str) -> Value {
    management_pool.get().await.unwrap().query_one(
        "select value from wsconnvars where name = $1", 
        &[&name]).await.unwrap().get::<_, Value>(0)
}

async fn update_management_settings(state: &Arc<Mutex<State>>, management_pool: &Pool) {
    if let Value::Bool(v) = read_var(&management_pool, "logging_enabled").await {
        state.lock().await.logging_enabled = v;
    }
    if let Value::Number(v) = read_var(&management_pool, "idle_connection_timeout").await {
        if let Some(v) = v.as_u64() {
            state.lock().await.idle_connection_timeout = v;
        }
    }
}

async fn management_task(state: Arc<Mutex<State>>, management_pool: Pool) {
    let _tt = TaskTrace::new("management_task", None, &state).await;
    let mut interval = time::interval(Duration::from_millis(1000));
    loop {
        interval.tick().await;
        update_management_settings(&state, &management_pool).await;
    }
}

async fn log_task(state: Arc<Mutex<State>>, mut logrx: mpsc::Receiver<LogEntry>, management_pool: Pool) {
    let _tt = TaskTrace::new("log_task", None, &state).await;
    let batch_size = state.lock().await.log_sender_batch_size;
    loop {
        let mut entries = Vec::new();
        while entries.len() < batch_size {
            if let Some(entry) = logrx.recv().await {
                use std::time::SystemTime;
                let now: SystemTime = SystemTime::now();
                entries.push((now, entry));
            }
        }
        let f = || async {
            let mut client = management_pool.get().await.unwrap();
            let dbtx = client.transaction().await.unwrap();
            for (t, e) in entries {
                dbtx.query("insert into wsconnlog values ($1, $2, $3, $4, $5, $6, $7)", 
                           &[&t, &e.run, &e.task, &e.tokio_task, &e.info, &e.func, &e.conn_id]).await.unwrap();
            }
            dbtx.commit().await.unwrap();
        };
        match std::panic::AssertUnwindSafe(f()).catch_unwind().await {
            Ok(v) => {},
            Err(err) => println!("log_task panic: {err:?}"),
        }
    }
}

fn print_status(
    stats: &Stats,
    pool: &Pool, 
    membership_pool: &Pool,
    ) {
    // let rt = tokio::runtime::Handle::current();
    // let m = rt.metrics();
    // dbg!(m);
    fn load(x: &AtomicI64) -> i64 { x.load(Ordering::Relaxed) }
    fn pool_status(p: &Pool) -> String { 
        let status = p.status();
        format!("max_size/size/avail/wait: {} / {} / {} / {}", status.max_size, status.size, status.available, status.waiting)
    }
    println!("conn/recv/sent/proxy/handle: {} / {} / {} / {} / {}   pool-{}   mpool-{}",
             load(&stats.connections), load(&stats.recvmsgcnt), load(&stats.sendmsgcnt), load(&stats.proxyreqcnt), load(&stats.handlereqcnt),
             pool_status(&pool), pool_status(&membership_pool),
             );
}

fn incr_by(x: &AtomicI64, by: i64) { x.fetch_add(by, Ordering::Relaxed); }
fn incr(x: &AtomicI64) { incr_by(x, 1); }
fn decr(x: &AtomicI64) { incr_by(x, -1); }

#[named]
async fn accept_websocket_connection(stream: TcpStream, state: Arc<Mutex<State>>, pool: Pool, membership_pool: Pool) {
    let conn_id = {
        let mut state = state.lock().await;
        state.conn_index += 1;
        state.conn_index
    };
    let _tt = TaskTrace::new("accept_websocket_connection", Some(conn_id), &state).await;

    // let _addr = stream.peer_addr().expect("connected streams should have a peer address");

    let ws_stream_client = tokio_tungstenite::accept_async(stream)
        .await
        .expect("Error during the websocket handshake occurred");
    let (client_write, mut client_read) = ws_stream_client.split();

    let arc_client_write = Arc::new(Mutex::new(MessageSink {
        use_zlib: false,
        sink: client_write,
    }));
    // let client_read = Arc::new(Mutex::new(client_read));

    // info!("new ws connection: {}", _addr);
    incr(&state.lock().await.stats.connections);

    let (ws_stream_backend, _) = tokio_tungstenite::connect_async("ws://127.0.0.1:8817/").await.expect("can't connect");
    let (backend_write, mut backend_read) = ws_stream_backend.split();

    let arc_backend_write = Arc::new(Mutex::new(backend_write));

    struct Cleanup<T1: Sink<Message> + Unpin + Send + 'static, T2: Sink<Message> + Unpin + Send + 'static> {
        cw: ClientWrite<T1>,
        bw: Arc<Mutex<T2>>,
        state: Arc<Mutex<State>>,
    };
    impl<T1: Sink<Message> + Unpin + Send + 'static, T2: Sink<Message> + Unpin + Send + 'static> Drop for Cleanup<T1, T2> {
        fn drop(&mut self) {
            let cw = self.cw.clone();
            let bw = self.bw.clone();
            let state = self.state.clone();
            tokio::spawn(async move {
                cw.lock().await.sink.close().await;
                bw.lock().await.close().await;
                decr(&state.lock().await.stats.connections);
                // println!("cleanup done");
                // info!("ws disconnection: {}", _addr);
            });
        }
    }
    let _cleanup = Cleanup {
        cw: arc_client_write.clone(),
        bw: arc_backend_write.clone(),
        state: state.clone(),
    };

    let running = Arc::new(Mutex::new(true));

    let t_last_msg = Arc::new(Mutex::new(get_sys_time_in_secs()));
    {
        let state = state.clone();
        let t_last_msg = t_last_msg.clone();
        let client_write = arc_client_write.clone();
        let backend_write = arc_backend_write.clone();
        let running = running.clone();
        let rfactor = rand::random::<f64>()*0.05 + 0.95;
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("close-idle-ws-connection", Some(conn_id), &state).await;
            let mut interval = time::interval(Duration::from_secs(3));
            while *running.lock().await {
                interval.tick().await;
                let t = get_sys_time_in_secs();
                let mut tl = t_last_msg.lock().await;
                let dt = t - *tl;
                if dt >= ((rfactor*(state.lock().await.idle_connection_timeout as f64)) as u64) {
                    *running.lock().await = false;
                    let _ = client_write.lock().await.sink.close().await;
                    let _ = backend_write.lock().await.close().await;
                    send_log(get_tokio_task_id(), function_name!(), json!({"event": "idle-connection-closed"}), &state).await;
                }
            }
        });
    }
    {
        let t_last_msg = t_last_msg.clone();
        let client_write = arc_client_write.clone();
        let state = state.clone();
        tokio::spawn(async move {
            let _tt = TaskTrace::new("proxy-ws-msgs", Some(conn_id), &state).await;
            while let Some(Ok(msg)) = backend_read.next().await {
                if msg.is_text() || msg.is_binary() {
                    incr(&state.lock().await.stats.sendmsgcnt);
                    client_write.lock().await.sink.send(msg.clone()).await.expect("failed to send message");
                    *t_last_msg.lock().await = get_sys_time_in_secs();
                    let mut msg_fmted: String = format!("{}", msg).chars().skip(0).take(70).collect();
                    msg_fmted.push_str("...");
                    send_log(get_tokio_task_id(), function_name!(), json!({"event": "message-proxied", "msg": msg_fmted}), &state).await;
                }
            }
            client_write.lock().await.sink.close().await.expect("client_write failed to close");
        });
    }
    
    {
        let state = state.clone();
        let client_write = arc_client_write.clone();
        let backend_write = arc_backend_write.clone();
        let pool = pool.clone();
        let membership_pool = membership_pool.clone();
        // let client_read = client_read.clone();
        let running = running.clone();
        while *running.lock().await {
            match timeout(Duration::from_secs(1), client_read.next()).await {
                Ok(None) => {
                    send_log(get_tokio_task_id(), function_name!(), json!({"event": "client-read-error"}), &state).await;
                    *running.lock().await = false;
                },
                Ok(Some(Ok(msg))) => {
                    let msg_fmted = format!("{}", msg);
                    send_log(get_tokio_task_id(), function_name!(), json!({"event": "client-message", "msg": msg_fmted}), &state).await;
                    if msg.is_text() || msg.is_binary() {
                        *t_last_msg.lock().await = get_sys_time_in_secs();
                        let r = std::panic::AssertUnwindSafe(handle_req(&state, &msg, &client_write, &pool, &membership_pool)).catch_unwind().await;
                        let handeled = match r {
                            Ok(h) => h,
                            Err(err) => {
                                println!("request handling error for: {}", msg.to_text().unwrap());
                                send_log(get_tokio_task_id(), function_name!(), json!({"event": "handle-req-error", "error": format!("{:?}", err), "msg": msg_fmted}), &state).await;
                                false
                            }
                        };
                        if handeled {
                            incr(&state.lock().await.stats.handlereqcnt);
                            send_log(get_tokio_task_id(), function_name!(), json!({"event": "handle-req-handled", "msg": msg_fmted}), &state).await;
                        } else {
                            backend_write.lock().await.send(msg).await.expect("failed to send message");
                            send_log(get_tokio_task_id(), function_name!(), json!({"event": "handle-req-not-handled", "msg": msg_fmted}), &state).await;
                            incr(&state.lock().await.stats.proxyreqcnt);
                        }
                    }
                }
                _ => { 
                    // println!("recv timeout"); 
                },
            }
        }
    }

    // println!("accept_websocket_connection exit");
}

#[named]
async fn handle_req<T: Sink<Message> + Unpin>(
    state: &Arc<Mutex<State>>, 
    msg: &Message, 
    client_write: &ClientWrite<T>, 
    pool: &Pool, 
    membership_pool: &Pool
) -> bool where <T as Sink<Message>>::Error: Debug {

    incr(&state.lock().await.stats.recvmsgcnt);

    if let Ok(d) = serde_json::from_str::<Value>(msg.to_text().unwrap()) {
        send_log(get_tokio_task_id(), function_name!(), json!({"event": "request", "request": d}), state).await;

        if Some("REQ") == d[0].as_str() {
            if let Some(subid) = d[1].as_str() {
                if let Some(funcall) = d[2]["cache"][0].as_str() {
                    // info_time!("{}", funcall);
                    // println!("{}", funcall);
                    let kwargs = &d[2]["cache"][1];
                    let fa = FunArgs {
                        state, 
                        subid, 
                        kwargs, 
                        pool, 
                        membership_pool, 
                        client_write,
                    };
                    let reqstatus = {
                        if funcall == "set_primal_protocol" {
                            if kwargs["compression"] == "zlib" {
                                let cw = &mut client_write.lock().await;
                                cw.use_zlib = true;
                            }
                            Ok(NotHandled)
                        } else if funcall == "thread_view" {
                            ReqHandlers::thread_view(&fa).await
                        } else if funcall == "scored" {
                            ReqHandlers::scored(&fa).await
                        } else if funcall == "get_default_app_settings" {
                            ReqHandlers::get_default_app_settings(&fa).await
                        } else if funcall == "get_app_releases" {
                            ReqHandlers::get_app_releases(&fa).await
                        } else if funcall == "get_bookmarks" {
                            ReqHandlers::get_bookmarks(&fa).await
                        } else if funcall == "user_infos" {
                            ReqHandlers::user_infos(&fa).await
                        } else if funcall == "server_name" {
                            ReqHandlers::server_name(&fa).await
                        } else if funcall == "get_notifications_seen" {
                            ReqHandlers::get_notifications_seen(&fa).await
                        } else if funcall == "feed" {
                            ReqHandlers::feed(&fa).await
                        } else if funcall == "mega_feed_directive" {
                            ReqHandlers::mega_feed_directive(&fa).await
                        } else {
                            Ok(NotHandled)
                        }
                    };
                    let mut handled = false;
                    match reqstatus {
                        Ok(Handled) => handled = true,
                        Ok(NotHandled) => handled = false,
                        Ok(Notice(s)) => {
                            handled = true;
                            let cw = &mut client_write.lock().await;
                            ReqHandlers::send_notice(subid, cw, s.as_str()).await;
                        },
                        Err(err) => {
                            handled = false;
                            error!("{}", err);
                        },
                    }
                    if handled { 
                        // println!("handle call: {}", funcall);
                        return true;
                    } else {
                        // println!(" proxy call: {}", funcall);
                    }
                }
            }
        }
    }

    false
}

fn get_sys_time_in_secs() -> u64 {
    match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(n) => n.as_secs(),
        Err(_) => panic!("SystemTime before UNIX EPOCH!"),
    }
}

fn zlib_compress_response(subid: &str, events: &Vec<String>) -> Result<Vec<u8>, Error> {
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
    let mut s = String::new();
    s.push_str("[\"EVENTS\",\"");
    s.push_str(subid);
    s.push_str("\",[");
    for (i, e) in events.iter().enumerate() {
        s.push_str(e);
        if i < events.len() - 1 {
            s.push(',');
        }
    }
    s.push_str("]]");
    let _ = enc.write_all(s.as_bytes());
    enc.finish()
}

impl<T: Sink<Message> + Unpin> ReqHandlers<T> where <T as Sink<Message>>::Error: Debug {

    async fn send_event_str(subid: &str, e: &str, cw: &mut MessageSink<T>) -> Result<(), ReqError> {
        let mut msg = String::from("[\"EVENT\",\"");
        msg.push_str(subid);
        msg.push_str("\",");
        msg.push_str(e);
        msg.push_str("]");
        cw.sink.send(Text(msg)).await.map_err(|_| "failed to send text event response to client")?;
        Ok(())
    }

    async fn send_eose(subid: &str, cw: &mut MessageSink<T>) -> Result<(), ReqError> {
        let mut msg = String::from("[\"EOSE\",\"");
        msg.push_str(subid);
        msg.push_str("\"]");
        cw.sink.send(Text(msg)).await.map_err(|_| "failed to send text eose response to client")?;
        Ok(())
    }

    async fn send_notice(subid: &str, cw: &mut MessageSink<T>, s: &str) -> Result<(), ReqError> {
        let mut msg = String::from("[\"NOTICE\",\"");
        msg.push_str(subid);
        msg.push_str("\",\"");
        msg.push_str(s);
        msg.push_str("\"]");
        cw.sink.send(Text(msg)).await.map_err(|_| "failed to send text notice response to client")?;
        Ok(())
    }

    async fn send_response(subid: &str, cw: &mut MessageSink<T>, res: &Vec<String>) -> Result<(), ReqError> {
        if cw.use_zlib {
            let d = zlib_compress_response(subid, &res).map_err(|_| "zlib failed")?;
            cw.sink.send(Binary(d)).await.map_err(|_| "failed to send binary response to client")?;
        } else {
            for r in res {
                Self::send_event_str(subid, r, cw).await?;
            }
        }
        Ok(())
    }

    fn rows_to_vec(rows: &Vec<tokio_postgres::Row>) -> Vec<String> {
        let mut res = Vec::new();
        for row in rows {
            if let Ok(r) = row.try_get::<_, &str>(0) {
                res.push(r.to_string().clone());
            }
        }
        res
    }

    async fn send_response_rows(subid: &str, cw: &mut MessageSink<T>, rows: &Vec<tokio_postgres::Row>) {
        Self::send_response(subid, cw, &Self::rows_to_vec(&rows)).await.unwrap();
    }

    async fn pool_get(pool: &Pool) -> Result<Client, ReqError> {
        match timeout(Duration::from_secs(POOL_GET_TIMEOUT), pool.get()).await {
            Ok(Ok(client)) => Ok(client),
            _ => req_error("pool.get() timeout, send upstream")
        }
    }

    async fn thread_view(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        let event_id = hex::decode(fa.kwargs["event_id"].as_str().ok_or("invalid event_id")?.to_string())?;
        let limit = fa.kwargs["limit"].as_i64().unwrap_or(20);
        let since = fa.kwargs["since"].as_i64().unwrap_or(0);
        let until = fa.kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = fa.kwargs["offset"].as_i64().unwrap_or(0);
        let user_pubkey = 
            if let Some(v) = fa.kwargs["user_pubkey"].as_str() {
                hex::decode(v.to_string()).ok()
            } else { fa.state.lock().await.primal_pubkey.clone() };
        
        let apply_humaness_check = true;

        let res = Self::rows_to_vec(
            &Self::pool_get(&fa.pool).await?.query(
                "select e::text from thread_view($1, $2, $3, $4, $5, $6, $7) r(e)", 
                &[&event_id, &limit, &since, &until, &offset, &user_pubkey, &apply_humaness_check]).await?);
        
        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &res).await?;
        Self::send_eose(fa.subid, cw).await?;

        Ok(Handled)
    }

    async fn scored(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        let selector = fa.kwargs["selector"].as_str().unwrap();

        let mut k = String::from("precalculated_analytics_");
        k.push_str(selector);

        let r = {
            let row = &Self::pool_get(&fa.pool).await?.query_one(
                "select value::text from cache where key = $1", 
                &[&k]).await?;
            serde_json::from_str::<Value>(row.get(0))
        };

        if let Ok(Value::Array(arr)) = r {
            let cw = &mut fa.client_write.lock().await;
            Self::send_response(fa.subid, cw, &arr.into_iter().map(|e| e.to_string()).collect()).await?;
            Self::send_eose(fa.subid, cw).await?;
            return Ok(Handled);
        }

        Ok(NotHandled)
    }

    async fn get_default_app_settings(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        let client = fa.kwargs["client"].as_str().ok_or("invalid client")?;

        const PRIMAL_SETTINGS: i64 = 10000103;

        let e = json!({
            "kind": PRIMAL_SETTINGS,
            "tags": [["d", client]],
            "content": fa.state.lock().await.default_app_settings.clone().unwrap(),
        });
        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await?;
        Self::send_eose(fa.subid, cw).await?;
        
        Ok(Handled)
    }

    async fn get_bookmarks(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        let pubkey = hex::decode(fa.kwargs["pubkey"].as_str().ok_or("invalid pubkey")?.to_string())?;

        let e = {
            let client = &Self::pool_get(&fa.pool).await?;
            if let Ok(row) = client.query_one("select event_id from bookmarks where pubkey = $1", &[&pubkey]).await {
                let eid: &[u8] = row.get(0);
                if let Ok(row) = client.query_one("select * from events where id = $1", &[&eid]).await {
                    let id: &[u8] = row.get(0);
                    let pubkey: &[u8] = row.get(1);
                    let created_at: i64 = row.get(2);
                    let kind: i64 = row.get(3);
                    let tags: Value = row.get(4);
                    let content: &str = row.get(5);
                    let sig: &[u8] = row.get(6);
                    Some(json!({
                        "id": hex::encode(id), 
                        "pubkey": hex::encode(pubkey), 
                        "created_at": created_at, 
                        "kind": kind, 
                        "tags": tags.clone(),
                        "content": content.clone(),
                        "sig": hex::encode(sig), 
                    }))
                } else { None }
            } else { None }
        };

        if let Some(e) = e {
            let cw = &mut fa.client_write.lock().await;
            Self::send_response(fa.subid, cw, &vec!(e.to_string())).await?;
            Self::send_eose(fa.subid, cw).await?;
            return Ok(Handled);
        }

        Ok(NotHandled)
    }

    async fn user_infos(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        if let Value::Array(pubkeys) = &fa.kwargs["pubkeys"] {
            // let mut s = String::from("{");
            // if pubkeys.len() > 0 {
            //     for pk in pubkeys {
            //         if let Value::String(pk) = &pk {
            //             s.push('"');
            //             s.push_str(pk.to_string().as_str());
            //             s.push('"');
            //             s.push(',');
            //         }
            //     }
            //     s.pop();
            // }
            // s.push('}');

            // let s: &str = s.as_str();

            // let res = Self::rows_to_vec(
            //     &Self::pool_get(&fa.pool).await?.query(
            //         "select e::text from user_infos(($1::text)::text[]) r(e)", 
            //         &[&s])
            //     .await?);

            let mut pks = Vec::new();
            for pk in pubkeys {
                if let Value::String(pk) = &pk {
                    if pk.len() != 64 {
                        return Ok(Notice("invalid pubkey".to_string()));
                    }
                    if let Ok(_) = hex::decode(pk) {
                        pks.push(pk);
                    } else {
                        return Ok(Notice("invalid pubkey".to_string()));
                    }
                }
            }
            let res = Self::rows_to_vec(
                &Self::pool_get(&fa.pool).await?.query(
                    "select e::text from user_infos(array(select jsonb_array_elements_text($1::jsonb))) r(e)", 
                    &[&json!(pks)])
                .await?);

            let cw = &mut fa.client_write.lock().await;
            Self::send_response(fa.subid, cw, &res).await;
            Self::send_eose(fa.subid, cw).await;
            return Ok(Handled)
        }

        Ok(NotHandled)
    }

    async fn server_name(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        let e = json!({"content": fa.state.lock().await.srv_name});

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await;
        Self::send_eose(fa.subid, cw).await;
        
        Ok(Handled)
    }

    async fn get_app_releases(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        const APP_RELEASES: i64 = 10000138;

        let e = json!({
            "kind": APP_RELEASES, 
            "content": fa.state.lock().await.app_releases.clone().unwrap(),
        });

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await;
        Self::send_eose(fa.subid, cw).await;
        
        Ok(Handled)
    }

    async fn get_notifications_seen(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        const NOTIFICATIONS_SEEN_UNTIL: i64 = 10000111;

        let pubkey: Vec<u8> = hex::decode(fa.kwargs["pubkey"].as_str().ok_or("invalid pubkey")?.to_string())?;

        let e = {
            let client = &Self::pool_get(&fa.membership_pool).await?;
            match client.query_one("select seen_until from pubkey_notifications_seen where pubkey = $1",
                                   &[&pubkey]).await {
                Ok(row) => {
                    let t: i64 = row.get(0);
                    json!({
                        "kind": NOTIFICATIONS_SEEN_UNTIL, 
                        "content": json!(t).to_string()})
                },
                Err(err) => {
                    match err.code() {
                        Some(ec) => return Err(ec.code().into()),
                        None => return Ok(Notice("unknown user".to_string())),
                    }
                }
            }
        };

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await?;
        Self::send_eose(fa.subid, cw).await?;
        
        Ok(Handled)
    }

    async fn feed(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        // dbg!(fa.kwargs);

        let limit = fa.kwargs["limit"].as_i64().unwrap_or(20);
        let since = fa.kwargs["since"].as_i64().unwrap_or(0);
        let until = fa.kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = fa.kwargs["offset"].as_i64().unwrap_or(0);
        let pubkey: Vec<u8> = hex::decode(
            fa.kwargs["pubkey"].as_str().expect("pubkey argument required")
            ).expect("pubkey should be in hex");
        let user_pubkey = 
            if let Some(v) = fa.kwargs["user_pubkey"].as_str() {
                hex::decode(v.to_string()).ok()
            } else { fa.state.lock().await.primal_pubkey.clone() };
        let notes = fa.kwargs["notes"].as_str().unwrap_or("follows");
        let include_replies = fa.kwargs["include_replies"].as_bool().unwrap_or(false) as i64;

        let send_results = {
            let pubkey = pubkey.clone();
            |pgfunc: String, include_replies: i64, apply_humaness_check: bool| async move {
                let q = format!("select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t from {}($1, $2, $3, $4, $5, $6, $7, $8) f(e) where e is not null order by t desc", pgfunc);
                let params: &[&(dyn ToSql + Sync)] = &[&pubkey, &since, &until, &include_replies, &limit, &offset, &user_pubkey, &apply_humaness_check];

                let res = Self::rows_to_vec(
                    &Self::pool_get(&fa.pool).await?.query(q.as_str(), params)
                    .await?);

                let cw = &mut fa.client_write.lock().await;
                Self::send_response(fa.subid, cw, &res).await;
                Self::send_eose(fa.subid, cw).await;

                // Ok::<ReqStatus, ReqError>::(Handled)
                Ok(Handled)
            }
        };

        if notes == "follows" {
            let r = Self::pool_get(&fa.pool).await?.query("select 1 from pubkey_followers pf where pf.follower_pubkey = $1 limit 1", 
                                                          &[&pubkey]).await?.len();
            if r > 0 {
                return send_results("feed_user_follows".to_string(), include_replies, true).await;
            }
        } else if notes == "authored" {
            return send_results("feed_user_authored".to_string(), include_replies, false).await;
        } else if notes == "replies" {
            return send_results("feed_user_authored".to_string(), 1, false).await;
        }

        Ok(NotHandled)
    }

    async fn long_form_content_feed(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        dbg!(fa.kwargs);

        let limit = fa.kwargs["limit"].as_i64().unwrap_or(20);
        let since = fa.kwargs["since"].as_i64().unwrap_or(0);
        let until = fa.kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
        let offset = fa.kwargs["offset"].as_i64().unwrap_or(0);

        let pubkey = fa.kwargs["pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok());
        let user_pubkey = 
            fa.kwargs["user_pubkey"].as_str().and_then(|v| hex::decode(v.to_string()).ok())
            .or(fa.state.lock().await.primal_pubkey.clone());

        let notes = fa.kwargs["notes"].as_str();
        let topic = fa.kwargs["topic"].as_str();
        let curation = fa.kwargs["curation"].as_str();
        let minwords = fa.kwargs["minwords"].as_i64().unwrap_or(0);

        let apply_humaness_check = true;

        let res = Self::rows_to_vec(
            &Self::pool_get(&fa.pool).await?.query(
                "select distinct e::text, e->>'created_at' from long_form_content_feed($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) f(e) where e is not null order by e->>'created_at' desc",
                &[
                &pubkey, &notes, &topic, &curation, &minwords, 
                &limit, &since, &until, &offset, 
                &user_pubkey, &apply_humaness_check,
                ]).await?);

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &res).await;
        Self::send_eose(fa.subid, cw).await;

        Ok(Handled)
    }

    async fn mega_feed_directive(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        // dbg!(fa.kwargs);
        
        let mut kwargs = fa.kwargs.as_object().unwrap().clone();
        let spec = kwargs["spec"].as_str().unwrap().to_string();
        kwargs.remove("spec");

        match serde_json::from_str::<Value>(&spec) {
            Err(_) => {
                return Ok(Notice("invalid spec format".to_string()));
            },
            Ok(Value::Object(s)) => {
                let mut skwa = s.clone();
                skwa.remove("id");
                skwa.remove("kind");

                let sg = |k: &str| -> &str {
                    s.get(k).and_then(Value::as_str).unwrap_or("")
                };

                if sg("id") == "nostr-reads-feed" {
                    return Ok(NotHandled);

                } else if sg("kind") == "reads" || sg("id") == "reads-feed" {
                    let minwords = s.get("minwords").and_then(Value::as_i64).unwrap_or(100);

                    if sg("scope") == "follows" {
                        return Ok(NotHandled);

                    } else if sg("scope") == "zappedbyfollows" {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("pubkey".to_string(), kwa.get("user_pubkey").expect("user_pubkey argument required").clone());
                        kwa.insert("notes".to_string(), json!("zappedbyfollows"));

                        return Self::long_form_content_feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;

                    } else if sg("scope") == "myfollowsinteractions" {
                        return Ok(NotHandled);

                    } else if let Some(topic) = s.get("topic") {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("topic".to_string(), topic.clone());

                        return Self::long_form_content_feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;

                    } else if let (Some(pubkey), Some(curation)) = (s.get("pubkey"), s.get("curation")) {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.insert("pubkey".to_string(), pubkey.clone());
                        kwa.insert("curation".to_string(), curation.clone());

                        return Self::long_form_content_feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;

                    } else {
                        let mut kwa = kwargs.clone();
                        kwa.insert("minwords".to_string(), json!(minwords));
                        kwa.append(&mut skwa);

                        return Self::long_form_content_feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;
                    }

                } else if sg("kind") == "notes" {
                    if sg("id") == "latest" {
                        let mut kwa = kwargs.clone();
                        kwa.insert("pubkey".to_string(), kwa.get("user_pubkey").expect("user_pubkey argument required").clone());
                        kwa.append(&mut skwa);

                        return Self::feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;

                    } else if sg("id") == "feed" {
                        let mut kwa = kwargs.clone();
                        kwa.append(&mut skwa);

                        return Self::feed(&FunArgs {kwargs: &Value::Object(kwa.clone()), ..(*fa)}).await;
                    }
                }
            },
            Ok(_) => {
                return Ok(Notice("invalid spec format".to_string()));
            },
        }

        Ok(NotHandled)
    }
}

fn req_err(description: &str) -> ReqError {
    ReqError { description: description.to_string() }
}
fn req_error<R>(description: &str) -> Result<R, ReqError> {
    Err(req_err(description))
}

use tokio::runtime::Handle;

async fn runtime_dump() {
    let handle = Handle::current();
    let mut s = String::new();
    if let Ok(dump) = timeout(Duration::from_secs(5), handle.dump()).await {
        for task in dump.tasks().iter() {
            let trace = task.trace();
            let tokio_task_id = get_tokio_task_id();
            s.push_str(format!("TASK {tokio_task_id}:\n").as_str());
            s.push_str(format!("{trace}\n\n").as_str());
        }
    }
    tokio::fs::write("tasks.txt", s).await;
}

////
use async_trait::async_trait;
use futures::stream;
use tokio::net::TcpListener;
use pgwire::api::auth::noop::NoopStartupHandler;
use pgwire::api::copy::NoopCopyHandler;
use pgwire::api::query::{PlaceholderExtendedQueryHandler, SimpleQueryHandler};
use pgwire::api::results::{DataRowEncoder, FieldFormat, FieldInfo, QueryResponse, Response, Tag};
use pgwire::api::{ClientInfo, PgWireHandlerFactory, Type};
use pgwire::error::{PgWireError, PgWireResult};
use pgwire::api::auth::DefaultServerParameterProvider;

pub struct WSConnProcessor {
    state: Arc<Mutex<State>>,
}

#[async_trait]
impl SimpleQueryHandler for WSConnProcessor {
    async fn do_query<'a, C>(
        &self,
        _client: &mut C,
        query: &'a str,
    ) -> PgWireResult<Vec<Response<'a>>>
    where
        C: ClientInfo + Unpin + Send + Sync,
    {
        println!("{:?}", query);

        // use sqlparser::dialect::GenericDialect;
        // use sqlparser::parser::Parser;
        // let dialect = GenericDialect {}; // or AnsiDialect, or your own dialect ...
        // let ast = Parser::parse_sql(&dialect, query).unwrap();
        // println!("AST:");
        // dbg!(ast);

        if query == "select * from tasks;" {

            let fields = vec![
                    FieldInfo::new(
                        "tokio_task_id".to_string(),
                        None,
                        None,
                        Type::UNKNOWN,
                        FieldFormat::Text,
                    ),
                    FieldInfo::new(
                        "task_id".to_string(),
                        None,
                        None,
                        Type::UNKNOWN,
                        FieldFormat::Text,
                    ),
                    FieldInfo::new(
                        "trace".to_string(),
                        None,
                        None,
                        Type::UNKNOWN,
                        FieldFormat::Text,
                    ),
                ];
            let fields = Arc::new(fields);

            let mut results = Vec::new();

            let handle = Handle::current();
            if let Ok(dump) = timeout(Duration::from_secs(5), handle.dump()).await {
                for task in dump.tasks().iter() {
                    let trace = task.trace();
                    let trace = format!("{trace}");

                    let tokio_task_id = parse_tokio_task_id(task.id());
                    let task_id = *self.state.lock().await.tasks.get(&tokio_task_id).unwrap_or(&(-1 as i64));

                    let mut encoder = DataRowEncoder::new(fields.clone());
                    encoder.encode_field_with_type_and_format(
                            &tokio_task_id,
                            &Type::INT8,
                            FieldFormat::Text,
                        )?;
                    encoder.encode_field_with_type_and_format(
                            &task_id,
                            &Type::INT8,
                            FieldFormat::Text,
                        )?;
                    encoder.encode_field_with_type_and_format(
                            &trace,
                            &Type::VARCHAR,
                            FieldFormat::Text,
                        )?;
                    results.push(encoder.finish());
                }
            }

            Ok(vec![Response::Query(QueryResponse::new(
                fields,
                stream::iter(results.into_iter()),
            ))])
        } else {
            Ok(vec![])
        }
    }
}

struct WSConnHandlerFactory {
    processor: Arc<WSConnProcessor>,
}

impl PgWireHandlerFactory for WSConnHandlerFactory {
    type StartupHandler = NoopStartupHandler;
    type SimpleQueryHandler = WSConnProcessor;
    type ExtendedQueryHandler = PlaceholderExtendedQueryHandler;
    type CopyHandler = NoopCopyHandler;

    fn simple_query_handler(&self) -> Arc<Self::SimpleQueryHandler> {
        self.processor.clone()
    }

    fn extended_query_handler(&self) -> Arc<Self::ExtendedQueryHandler> {
        Arc::new(PlaceholderExtendedQueryHandler)
    }

    fn startup_handler(&self) -> Arc<Self::StartupHandler> {
        Arc::new(NoopStartupHandler)
    }

    fn copy_handler(&self) -> Arc<Self::CopyHandler> {
        Arc::new(NoopCopyHandler)
    }
}
////


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_1() {
        let e = json!({
            "key1": "value1", 
        });
        println!("{:?}", e["key2"] == "value2");
    }
}

