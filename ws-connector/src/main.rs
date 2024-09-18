use std::{env, io::Error};
use std::time::{SystemTime};
use std::net::SocketAddr;
use tokio::time;

use futures_util::{future, StreamExt, SinkExt, TryStreamExt};
use futures_util::stream::SplitSink;
use log::info;
use tokio::net::{TcpListener, TcpStream, TcpSocket};
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;
use tokio::signal::unix::{signal, SignalKind};
use tokio::time::{sleep, Duration};
use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::sync::atomic::Ordering;
use std::os::fd::AsRawFd;

use serde_json::Value;
use serde_json::json;

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::NoTls;

use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message::Text;
use tokio_tungstenite::tungstenite::Message;

use measure_time::info_time;

struct Stats {
    recvmsgcnt: AtomicI64,
    sendmsgcnt: AtomicI64,
    proxyreqcnt: AtomicI64,
    handlereqcnt: AtomicI64,
    connections: AtomicI64,
}

static mut stats: Stats = Stats {
    recvmsgcnt: AtomicI64::new(0),
    sendmsgcnt: AtomicI64::new(0),
    proxyreqcnt: AtomicI64::new(0),
    handlereqcnt: AtomicI64::new(0),
    connections: AtomicI64::new(0),
};

struct State {
    default_app_settings: Option<String>,
    app_releases: Option<String>,

    srv_name: Option<String>,

    shutting_down: bool,
}

static mut state: State = State {
    default_app_settings: None,
    app_releases: None,

    srv_name: None,

    shutting_down: false,
};

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
// #[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    let _ = env_logger::try_init();

    let addr = env::args().nth(1).unwrap_or_else(|| "0.0.0.0:9001".to_string());
    unsafe {
        state.srv_name = Some(env::args().nth(2).unwrap_or_else(|| "333".to_string()));
    };

    let sa = addr.parse().unwrap();
    let socket = TcpSocket::new_v4().unwrap();
    socket.set_reuseaddr(true).unwrap();
    socket.set_reuseport(true).unwrap();
    socket.bind(sa).expect("failed to bind");

    let listener = socket.listen(1024).unwrap();

    // let try_socket = TcpListener::bind(&addr).await;
    info!("listening on: {}", addr);

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

    unsafe {
        state.default_app_settings = Some(std::fs::read_to_string("/home/pr/work/itk/primal/content-moderation/default-settings.json").unwrap());
        state.app_releases = Some(std::fs::read_to_string("/home/pr/work/itk/primal/content-moderation/app-releases.json").unwrap());
    }

    tokio::task::spawn(async {
        let mut interval = time::interval(Duration::from_millis(2000));
        loop {
            interval.tick().await;
            print_msgcnts();
        }
    });

    let mut sig = signal(SignalKind::user_defined1()).unwrap();
    tokio::task::spawn(async move {
        sig.recv().await;
        println!("got signal USR1, shutting down");
        unsafe { state.shutting_down = true; }
    });

    let fd = listener.as_raw_fd();
    while unsafe { !state.shutting_down } {
        match listener.accept().await {
            Ok((stream, _)) => {
                let pool = pool.clone();
                let membership_pool = membership_pool.clone();
                tokio::spawn(accept_connection(stream, pool, membership_pool));
            },
            Err(err) => {
                println!("accept loop: {:?}", err);
                break;
            }
        }
    }
    unsafe { libc::shutdown(fd, libc::SHUT_RD); }

    println!("waiting some time for remaining requests to complete");
    sleep(Duration::from_millis(10000)).await;

    Ok(())
}

fn print_msgcnts() {
    unsafe {
        fn load(x: &AtomicI64) -> i64 { x.load(Ordering::Relaxed) }
        println!("conn/recv/sent/proxy/handle: {} / {} / {} / {} / {}",
                 load(&stats.connections), load(&stats.recvmsgcnt), load(&stats.sendmsgcnt), load(&stats.proxyreqcnt), load(&stats.handlereqcnt));
    }
}

fn incr_by(x: &AtomicI64, by: i64) { x.fetch_add(by, Ordering::Relaxed); }
fn incr(x: &AtomicI64) { incr_by(x, 1); }
fn decr(x: &AtomicI64) { incr_by(x, -1); }

async fn accept_connection(stream: TcpStream, pool: Pool, membership_pool: Pool) {

    let addr = stream.peer_addr().expect("connected streams should have a peer address");

    let ws_stream_client = tokio_tungstenite::accept_async(stream)
        .await
        .expect("Error during the websocket handshake occurred");
    let (client_write, mut client_read) = ws_stream_client.split();

    let arc_client_write = Arc::new(Mutex::new(client_write));

    // info!("new ws connection: {}", addr);
    unsafe { incr(&stats.connections); }

    let (ws_stream_backend, _) = tokio_tungstenite::connect_async("ws://127.0.0.1:8817/").await.expect("Can't connect");
    let (mut backend_write, mut backend_read) = ws_stream_backend.split();

    let client_write_1 = arc_client_write.clone();
    tokio::spawn(async move {
        while let Some(Ok(msg)) = backend_read.next().await {
            if msg.is_text() || msg.is_binary() {
                unsafe { incr(&stats.sendmsgcnt); }
                client_write_1.lock().await.send(msg).await.expect("failed to send message");
            }
        }
        client_write_1.lock().await.close().await.expect("client_write_1 failed to close");
    });
    
    let client_write_2 = arc_client_write.clone();
    while let Some(Ok(msg)) = client_read.next().await {
        if msg.is_text() || msg.is_binary() {
            unsafe { incr(&stats.recvmsgcnt); }
            if let Ok(d) = serde_json::from_str::<Value>(msg.to_text().unwrap()) {
                if Some("REQ") == d[0].as_str() {
                    if let Some(subid) = d[1].as_str() {
                        if let Some(funcall) = d[2]["cache"][0].as_str() {
                            // println!("{}", funcall);
                            let kwargs = &d[2]["cache"][1];
                            let mut handled = false;
                            if funcall == "thread_view" {
                                thread_view(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "scored" {
                                scored(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "get_default_app_settings" {
                                get_default_app_settings(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "get_app_releases" {
                                get_app_releases(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "get_bookmarks" {
                                get_bookmarks(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "user_infos" {
                                user_infos(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "server_name" {
                                server_name(subid, kwargs, pool.clone(), &client_write_2).await;
                                handled = true;
                            } else if funcall == "get_notifications_seen" {
                                get_notifications_seen(subid, kwargs, membership_pool.clone(), &client_write_2).await;
                                handled = true;
                            }
                            if handled { 
                                // println!("{}", funcall);
                                unsafe { incr(&stats.handlereqcnt); }
                                continue; 
                            }
                        }
                    }
                }
            }
            backend_write.send(msg).await.expect("failed to send message");
            unsafe { incr(&stats.proxyreqcnt); }
        }
    }
    backend_write.close().await.expect("backend_write failed to close");

    // info!("ws disconnection: {}", addr);
    unsafe { decr(&stats.connections); }
}

fn get_sys_time_in_secs() -> u64 {
    match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(n) => n.as_secs(),
        Err(_) => panic!("SystemTime before UNIX EPOCH!"),
    }
}

async fn send_event_str(subid: &str, e: &str, cw: &mut tokio::sync::MutexGuard<'_, SplitSink<WebSocketStream<TcpStream>, Message>>) {
    let mut msg = String::from("[\"EVENT\",\"");
    msg.push_str(subid);
    msg.push_str("\",");
    msg.push_str(e);
    msg.push_str("]");
    cw.send(Text(msg)).await.expect("failed to send message");
}

async fn send_event(subid: &str, e: &Value, cw: &mut tokio::sync::MutexGuard<'_, SplitSink<WebSocketStream<TcpStream>, Message>>) {
    send_event_str(subid, e.to_string().as_str(), cw).await;
}

async fn send_eose(subid: &str, cw: &mut tokio::sync::MutexGuard<'_, SplitSink<WebSocketStream<TcpStream>, Message>>) {
    let mut msg = String::from("[\"EOSE\",\"");
    msg.push_str(subid);
    msg.push_str("\"]");
    cw.send(Text(msg)).await.expect("failed to send message");
}

async fn thread_view(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    // info_time!("thread_view");
    let event_id = hex::decode(kwargs["event_id"].as_str().unwrap().to_string()).ok();
    let limit = kwargs["event_id"].as_i64().unwrap_or(20);
    let since = kwargs["since"].as_i64().unwrap_or(0);
    let until = kwargs["until"].as_i64().unwrap_or(get_sys_time_in_secs().try_into().unwrap());
    let offset = kwargs["offset"].as_i64().unwrap_or(0);
    let user_pubkey = hex::decode(kwargs["user_pubkey"].as_str().unwrap().to_string()).ok();
    let apply_humaness_check = true;

    let client = pool.get().await.unwrap();
    let rows = client.query("select e::text from thread_view($1, $2, $3, $4, $5, $6, $7) r(e)", 
                            &[&event_id, &limit, &since, &until, &offset, &user_pubkey, &apply_humaness_check]).await.unwrap();
    let mut cw = client_write.lock().await;
    for row in &rows {
        if let Ok(r) = row.try_get::<_, &str>(0) {
            send_event_str(subid, r, &mut cw).await;
        }
    }
    send_eose(subid, &mut cw).await;
}

async fn scored(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    // info_time!("scored");
    let selector = kwargs["selector"].as_str().unwrap();

    let client = pool.get().await.unwrap();

    let mut k = String::from("precalculated_analytics_");
    k.push_str(selector);

    let row = client.query_one("select value::text from cache where key = $1", &[&k]).await.unwrap();
    let r: &str = row.get(0);

    if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(r) {
        let mut cw = client_write.lock().await;
        for e in arr {
            send_event(subid, &e, &mut cw).await;
        }
        send_eose(subid, &mut cw).await;
    }
}

async fn get_default_app_settings(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    // info_time!("get_default_app_settings");

    let client = kwargs["client"].as_str().unwrap();

    const PRIMAL_SETTINGS: i64 = 10000103;

    let mut cw = client_write.lock().await;

    let e = unsafe { 
        json!({
            "kind": PRIMAL_SETTINGS, 
            "tags": [["d", client]],
            "content": state.default_app_settings.clone().unwrap()})
    };
    send_event(subid, &e, &mut cw).await;

    send_eose(subid, &mut cw).await;
}

async fn get_bookmarks(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    // info_time!("get_bookmarks");

    let pubkey = hex::decode(kwargs["pubkey"].as_str().unwrap().to_string()).ok();

    let client = pool.get().await.unwrap();

    let mut cw = client_write.lock().await;

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
            let e = json!({
                    "id": hex::encode(id), 
                    "pubkey": hex::encode(pubkey), 
                    "created_at": created_at, 
                    "kind": kind, 
                    "tags": tags,
                    "content": content,
                    "sig": hex::encode(sig), 
            });
            send_event(subid, &e, &mut cw).await;
        }
    }

    send_eose(subid, &mut cw).await;
}

async fn user_infos(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    // info_time!("user_infos");

    let mut cw = client_write.lock().await;

    if let Value::Array(pubkeys) = &kwargs["pubkeys"] {
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

        let client = pool.get().await.unwrap();
        let rows = client.query("select e::text from user_infos(($1::text)::text[]) r(e)", 
                                &[&s]).await.unwrap();
        for row in &rows {
            if let Ok(r) = row.try_get::<_, &str>(0) {
                send_event_str(subid, r, &mut cw).await;
            }
        }
    }

    send_eose(subid, &mut cw).await;
}

async fn server_name(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    let mut cw = client_write.lock().await;

    let e = unsafe { json!({"content": state.srv_name}) };
    send_event(subid, &e, &mut cw).await;

    send_eose(subid, &mut cw).await;
}

async fn get_app_releases(subid: &str, kwargs: &Value, pool: Pool, client_write: &Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>) {
    const APP_RELEASES: i64 = 10000138;

    let mut cw = client_write.lock().await;

    let e = unsafe { 
        json!({
            "kind": APP_RELEASES, 
            "content": state.app_releases.clone().unwrap()})
    };
    send_event(subid, &e, &mut cw).await;

    send_eose(subid, &mut cw).await;
}

type ClientWrite = Arc<Mutex<SplitSink<WebSocketStream<TcpStream>, Message>>>;

async fn get_notifications_seen(subid: &str, kwargs: &Value, pool: Pool, client_write: &ClientWrite) {
    const NOTIFICATIONS_SEEN_UNTIL: i64 = 10000111;

    let pubkey = hex::decode(kwargs["pubkey"].as_str().unwrap().to_string()).ok();

    let mut cw = client_write.lock().await;

    let client = pool.get().await.unwrap();
    if let Ok(row) = client.query_one("select seen_until from pubkey_notifications_seen where pubkey = $1", 
                            &[&pubkey]).await {
        let t: i64 = row.get(0);
        let e = json!({
            "kind": NOTIFICATIONS_SEEN_UNTIL, 
            "content": json!(t).to_string()});
        send_event(subid, &e, &mut cw).await;
    }

    send_eose(subid, &mut cw).await;
}

