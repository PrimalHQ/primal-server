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

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[arg(short, long)]
    servername: String,

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

    }));

    {
        let mut state = state.lock().await;
        state.default_app_settings = Some(std::fs::read_to_string("/home/pr/work/itk/primal/content-moderation/default-settings.json").unwrap());
        state.app_releases = Some(std::fs::read_to_string("/home/pr/work/itk/primal/content-moderation/app-releases.json").unwrap());
    }

    let pool = {
        let mut pg_config = tokio_postgres::Config::new();
        pg_config.host("127.0.0.1");
        pg_config.port(54017);
        pg_config.user("pr");
        pg_config.dbname("primal1");
        let mgr_config = ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        };
        let mgr = Manager::from_config(pg_config, NoTls, mgr_config);
        Pool::builder(mgr).max_size(16).build().unwrap()
    };

    let membership_pool = {
        let mut pg_config = tokio_postgres::Config::new();
        pg_config.host("192.168.11.7");
        pg_config.port(5432);
        pg_config.user("primal");
        pg_config.dbname("primal");
        let mgr_config = ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        };
        let mgr = Manager::from_config(pg_config, NoTls, mgr_config);
        Pool::builder(mgr).max_size(16).build().unwrap()
    };

    {
        let state = state.clone();
        let pool = pool.clone();
        let membership_pool = membership_pool.clone();
        tokio::task::spawn(async move {
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
            sig.recv().await;
            println!("got signal USR1, shutting down");
            state.lock().await.shutting_down = true;
        });
    }

    {
        let state = state.clone();
        let mut sig = signal(SignalKind::user_defined2()).unwrap();
        tokio::task::spawn(async move {
            loop {
                sig.recv().await;
                println!("got signal USR2");
                runtime_dump().await;
            }
        });
    }

    match &cli.command {
        Some(Commands::Run { port }) => {
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
                        tokio::spawn(accept_connection(stream, state.clone(), pool, membership_pool));
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

            handle_req(&state, &msg, &client_write, &pool, &membership_pool).await;

            for r in &client_write.lock().await.sink {
                println!("{}", r);
            }
        },

        None => { },
    };

    Ok(())
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

async fn accept_connection(stream: TcpStream, state: Arc<Mutex<State>>, pool: Pool, membership_pool: Pool) {

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
                println!("cleanup done");
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
        let t_last_msg = t_last_msg.clone();
        let client_write = arc_client_write.clone();
        let backend_write = arc_backend_write.clone();
        let running = running.clone();
        tokio::task::spawn(async move {
            let mut interval = time::interval(Duration::from_millis(5000));
            loop {
                interval.tick().await;
                let t = get_sys_time_in_secs();
                let mut tl = t_last_msg.lock().await;
                let dt = t - *tl;
                // dbg!(dt);
                if dt >= 120 {
                    *running.lock().await = false;
                    let _ = client_write.lock().await.sink.close().await;
                    let _ = backend_write.lock().await.close().await;
                    break;
                }
            }
        });
    }
    {
        let t_last_msg = t_last_msg.clone();
        let client_write = arc_client_write.clone();
        let state = state.clone();
        tokio::spawn(async move {
            while let Some(Ok(msg)) = backend_read.next().await {
                if msg.is_text() || msg.is_binary() {
                    incr(&state.lock().await.stats.sendmsgcnt);
                    client_write.lock().await.sink.send(msg).await.expect("failed to send message");
                    *t_last_msg.lock().await = get_sys_time_in_secs();
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
                    *running.lock().await = false;
                },
                Ok(Some(Ok(msg))) => {
                    if msg.is_text() || msg.is_binary() {
                        let r = std::panic::AssertUnwindSafe(handle_req(&state, &msg, &client_write, &pool, &membership_pool)).catch_unwind().await;
                        let handeled = match r {
                            Ok(h) => h,
                            Err(err) => {
                                println!("request handling error for: {}", msg.to_text().unwrap());
                                false
                            }
                        };
                        if handeled {
                            incr(&state.lock().await.stats.handlereqcnt);
                            *t_last_msg.lock().await = get_sys_time_in_secs();
                        } else {
                            backend_write.lock().await.send(msg).await.expect("failed to send message");
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

    // println!("accept_connection exit");
}

async fn handle_req<T: Sink<Message> + Unpin>(
    state: &Arc<Mutex<State>>, 
    msg: &Message, 
    client_write: &ClientWrite<T>, 
    pool: &Pool, 
    membership_pool: &Pool
) -> bool where <T as Sink<Message>>::Error: Debug {

    incr(&state.lock().await.stats.recvmsgcnt);

    if let Ok(d) = serde_json::from_str::<Value>(msg.to_text().unwrap()) {
        if Some("REQ") == d[0].as_str() {
            if let Some(subid) = d[1].as_str() {
                if let Some(funcall) = d[2]["cache"][0].as_str() {
                    info_time!("{}", funcall);
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
                            let _ = ReqHandlers::scored(&fa).await;
                            Ok(Handled)
                        } else if funcall == "get_default_app_settings" {
                            let _ = ReqHandlers::get_default_app_settings(&fa).await;
                            Ok(Handled)
                        } else if funcall == "get_app_releases" {
                            let _ = ReqHandlers::get_app_releases(&fa).await;
                            Ok(Handled)
                        } else if funcall == "get_bookmarks" {
                            let _ = ReqHandlers::get_bookmarks(&fa).await;
                            Ok(Handled)
                        } else if funcall == "user_infos" {
                            ReqHandlers::user_infos(&fa).await
                        } else if funcall == "server_name" {
                            let _ = ReqHandlers::server_name(&fa).await;
                            Ok(Handled)
                        } else if funcall == "get_notifications_seen" {
                            ReqHandlers::get_notifications_seen(&fa).await
                        } else if funcall == "feed" {
                            if let Ok(()) = ReqHandlers::feed(&fa).await {
                                Ok(Handled)
                            } else {
                                Ok(NotHandled)
                            }
                        } else if funcall == "mega_feed_directive" {
                            if let Ok(()) = ReqHandlers::mega_feed_directive(&fa).await {
                                Ok(Handled)
                            } else {
                                Ok(NotHandled)
                            }
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
                            ReqHandlers::send_notice(subid, cw, s.as_str());
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

    async fn scored(fa: &FunArgs<'_, T>) -> Result<(), ReqError> {
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
            return Ok(());
        }

        req_error("send to upstream")
    }

    async fn get_default_app_settings(fa: &FunArgs<'_, T>) -> Result<(), ReqError> {
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
        
        Ok(())
    }

    async fn get_bookmarks(fa: &FunArgs<'_, T>) -> Result<(), ReqError> {
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
            return Ok(());
        }

        req_error("send to upstream")
    }

    async fn user_infos(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        if let Value::Array(pubkeys) = &fa.kwargs["pubkeys"] {
            let mut s = String::from("{");
            if pubkeys.len() > 0 {
                for pk in pubkeys {
                    if let Value::String(pk) = &pk {
                        s.push('"');
                        s.push_str(pk.to_string().as_str());
                        s.push('"');
                        s.push(',');
                    }
                }
                s.pop();
            }
            s.push('}');

            let s: &str = s.as_str();

            let res = Self::rows_to_vec(
                &Self::pool_get(&fa.pool).await?.query(
                    "select e::text from user_infos(($1::text)::text[]) r(e)", 
                    &[&s])
                .await?);

            // let mut pks = Vec::new();
            // for pk in pubkeys {
            //     if let Value::String(pk) = &pk {
            //         if pk.len() != 64 {
            //             return Ok(Notice("invalid pubkey".to_string()));
            //         }
            //         if let Ok(pk) = hex::decode(pk) {
            //             pks.push(pk);
            //         } else {
            //             return Ok(Notice("invalid pubkey".to_string()));
            //         }
            //     }
            // }
            // let res = Self::rows_to_vec(
            //     &Self::pool_get(&fa.pool).await?.query(
            //         "select e::text from user_infos($1::text[]) r(e)", 
            //         &[&pks])
            //     .await?);

            let cw = &mut fa.client_write.lock().await;
            Self::send_response(fa.subid, cw, &res).await;
            Self::send_eose(fa.subid, cw).await;
            return Ok(Handled)
        }

        Ok(NotHandled)
    }

    async fn server_name(fa: &FunArgs<'_, T>) -> Result<(), String> {
        let e = json!({"content": fa.state.lock().await.srv_name});

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await;
        Self::send_eose(fa.subid, cw).await;
        
        Ok(())
    }

    async fn get_app_releases(fa: &FunArgs<'_, T>) -> Result<(), String> {
        const APP_RELEASES: i64 = 10000138;

        let e = json!({
            "kind": APP_RELEASES, 
            "content": fa.state.lock().await.app_releases.clone().unwrap(),
        });

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await;
        Self::send_eose(fa.subid, cw).await;
        
        Ok(())
    }

    async fn get_notifications_seen(fa: &FunArgs<'_, T>) -> Result<ReqStatus, ReqError> {
        const NOTIFICATIONS_SEEN_UNTIL: i64 = 10000111;

        let pubkey = hex::decode(fa.kwargs["pubkey"].as_str().unwrap().to_string()).ok();

        let e = {
            let client = &Self::pool_get(&fa.membership_pool).await?;
            if let Ok(row) = client.query_one("select seen_until from pubkey_notifications_seen where pubkey = $1",
                                              &[&pubkey]).await {
                let t: i64 = row.get(0);
                json!({
                    "kind": NOTIFICATIONS_SEEN_UNTIL, 
                    "content": json!(t).to_string()})
            } else {
                return Ok(Notice("unknown user".to_string()));
            }
        };

        let cw = &mut fa.client_write.lock().await;
        Self::send_response(fa.subid, cw, &vec!(e.to_string())).await?;
        Self::send_eose(fa.subid, cw).await?;
        
        Ok(Handled)
    }

    async fn feed(fa: &FunArgs<'_, T>) -> Result<(), ReqError> {
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

        let apply_humaness_check = true;

        let send_results = {
            let pubkey = pubkey.clone();
            |pgfunc: String, include_replies: i64| async move {
                let q = format!("select distinct e::text, e->>'created_at' from {}($1, $2, $3, $4, $5, $6, $7, $8) f(e) where e is not null order by e->>'created_at' desc", pgfunc);
                let params: &[&(dyn ToSql + Sync)] = &[&pubkey, &since, &until, &include_replies, &limit, &offset, &user_pubkey, &apply_humaness_check];

                // let client = fa.pool.get().await.unwrap();
                // let rows = client.query(q.as_str(), params).await.unwrap();

                let res = Self::rows_to_vec(
                    &Self::pool_get(&fa.pool).await?.query(q.as_str(), params)
                    .await?);

                let cw = &mut fa.client_write.lock().await;
                Self::send_response(fa.subid, cw, &res).await;
                Self::send_eose(fa.subid, cw).await;

                Ok::<(), ReqError>(())
            }
        };

        if notes == "follows" {
            let r = Self::pool_get(&fa.pool).await?.query("select 1 from pubkey_followers pf where pf.follower_pubkey = $1 limit 1", 
                                                          &[&pubkey]).await?.len();
            if r > 0 {
                send_results("feed_user_follows".to_string(), include_replies).await?;
            }
        } else if notes == "authored" {
            send_results("feed_user_authored".to_string(), 0).await?;
        } else if notes == "replies" {
            send_results("feed_user_authored".to_string(), 1).await?;
        } else {
            return req_error("send upstream")
        }

        return Ok(());
    }

    async fn mega_feed_directive(fa: &FunArgs<'_, T>) -> Result<(), ReqError> {
        // dbg!(fa.kwargs);
        let spec = fa.kwargs["spec"].as_str().unwrap().to_string();
        if let Ok(Value::Object(s)) = serde_json::from_str::<Value>(&spec) {
            let mut skwa = s.clone();
            skwa.remove("id");
            skwa.remove("kind");

            if s.contains_key("kind") && s.contains_key("id") && 
               s["kind"] == "notes" && (s["id"] == "feed" || s["id"] == "latest") {
                if s["id"] == "latest" {
                    skwa.insert("pubkey".to_string(), fa.kwargs["user_pubkey"].clone());
                }
                // dbg!(&skwa);

                let notes: String = match skwa.get("notes") {
                    Some(Value::String(v)) => v,
                    _ => "follows",
                }.to_string();

                if let Value::Object(kwa) = fa.kwargs {
                    let mut kwa = kwa.clone();
                    kwa.remove("spec");
                    kwa.insert("pubkey".to_string(), skwa.get("pubkey").expect("pubkey argument required").clone());
                    kwa.insert("notes".to_string(), Value::String(notes));

                    let fa2 = FunArgs {
                        kwargs: &Value::Object(kwa.clone()),
                        ..(*fa)
                    };

                    return Self::feed(&fa2).await;
                }
            }
        }

        req_error("send upstream")
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
        for (i, task) in dump.tasks().iter().enumerate() {
            let trace = task.trace();
            s.push_str(format!("TASK {i}:\n").as_str());
            s.push_str(format!("{trace}\n\n").as_str());
        }
    }
    tokio::fs::write("tasks.txt", s).await;
}

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

