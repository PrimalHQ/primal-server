use std::io::Error;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use tokio::net::TcpSocket;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{mpsc, Mutex};
use tokio::time::{sleep, Duration};
use std::os::fd::AsRawFd;
use std::collections::HashMap;
use log::info;
use clap::{Parser, Subcommand};
use serde_json::{json, Value};

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::{NoTls, AsyncMessage};

use primal_cache::{live_importer, EventAddr, PubKeyId};
use std::sync::atomic::AtomicBool;
use futures_util::future::FutureExt;

use tokio_tungstenite::connect_async;
use ws_connector::connector::pgwire_handler::WSConnHandlerFactory;
use ws_connector::shared::utils::{compare_backend_api_response, send_request_and_get_response};
use ws_connector::{State, SharedState, Stats, LogEntry, TaskTrace, KeyedSubscriptions};
use ws_connector::connector::handler_manager::HandlerManager;
use ws_connector::connector::router::RequestRouter;
use ws_connector::connector::connection::ConnectionManager;
use ws_connector::connector::connection::send_event_str;
use ws_connector::connector::importer_manager::LiveImporterManager;
use ws_connector::shared::utils::incr;
use ws_connector::shared::task_dump::runtime_dump;
use ws_connector::shared::locking_watchdog::LockingWatchdog;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[arg(short, long, default_value="ws-connector")]
    servername: String,

    #[arg(short, long, default_value="100")]
    log_sender_batch_size: usize,

    #[arg(short, long, default_value="content-moderation")]
    content_moderation_root: String,

    #[arg(long, default_value="tmp")]
    task_dump_path: String,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Run {
        #[arg(short, long)]
        port: i32,
        #[arg(short, long)]
        backend_addr: String,
        #[arg(long, default_value="./target/release/ws-handlers")]
        handler_executable: String,
        #[arg(long, default_value="./target/release/ws-importer")]
        importer_executable: String,
    },
    Req {
        #[arg(long, required=true)]
        backend_addr: String,
        #[arg(long, default_value = "ws-connector-client")]
        sub_id: String,
        #[arg(long)]
        funcall: Option<String>,
        #[arg(long)]
        kwargs: Option<String>,
        #[arg(long)]
        req: Option<String>,
    },
    Compare {
        #[arg(long, required=true)]
        backend1_addr: String,
        #[arg(long, required=true)]
        backend2_addr: String,
        #[arg(long, default_value = "ws-connector-client")]
        sub_id: String,
        #[arg(long)]
        funcall: Option<String>,
        #[arg(long)]
        kwargs: Option<String>,
        #[arg(long)]
        req: Option<String>,
    },
}


#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> Result<(), Error> {
    let _ = env_logger::try_init();

    let cli = Cli::parse();

    let state = Arc::new(Mutex::new(State {
        shared: SharedState {
            stats: Stats {
                recvmsgcnt: AtomicI64::new(0),
                sendmsgcnt: AtomicI64::new(0),
                proxyreqcnt: AtomicI64::new(0),
                handlereqcnt: AtomicI64::new(0),
                connections: AtomicI64::new(0),
                recveventcnt: AtomicI64::new(0),
                importeventcnt: AtomicI64::new(0),
            },
            default_app_settings_filename: format!("{}/default-settings.json", cli.content_moderation_root),
            app_releases_filename: format!("{}/app-releases.json", cli.content_moderation_root),
            srv_name: Some(cli.servername.clone()),
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
        },
        websockets: HashMap::new(),
        ws_to_subs: HashMap::new(),
        subs_to_ws: HashMap::new(),
        live_events: KeyedSubscriptions::new(),
        live_events_from_follows: KeyedSubscriptions::new(),
    }));

    let management_pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 4, None);
    let pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 16, Some(30000));
    let membership_pool = make_dbconn_pool("192.168.11.7", 5432, "primal", "primal", 16, None);

    // Test database connections
    {
        management_pool.get().await.unwrap().query_one("select 1", &[]).await.unwrap().get::<_, i32>(0);
        pool.get().await.unwrap().query_one("select 1", &[]).await.unwrap().get::<_, i32>(0);
        membership_pool.get().await.unwrap().query_one("select 1", &[]).await.unwrap().get::<_, i32>(0);
    }

    // Signal handlers
    {
        let state = state.clone();
        let mut sig = signal(SignalKind::terminate()).unwrap();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("term-sig-recv", None, &state).await;
            sig.recv().await;
            eprintln!("ws-connector: got signal TERM, shutting down");
            state.lock().await.shared.shutting_down = true;
        });
    }

    {
        let state = state.clone();
        let mut sig = signal(SignalKind::user_defined1()).unwrap();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("usr1-sig-recv", None, &state).await;
            sig.recv().await;
            eprintln!("ws-connector: got signal USR1, shutting down");
            state.lock().await.shared.shutting_down = true;
        });
    }

    {
        let state = state.clone();
        let _task_dump_path = cli.task_dump_path.clone();
        let mut sig = signal(SignalKind::user_defined2()).unwrap();
        tokio::task::spawn(async move {
            let _tt = TaskTrace::new("usr2-sig-recv", None, &state).await;
            loop {
                sig.recv().await;
                eprintln!("ws-connector: got signal USR2");
                runtime_dump("ws-connector").await;
            }
        });
    }

    match &cli.command {
        Some(Commands::Run { port, backend_addr, handler_executable, importer_executable }) => {
            // Initialize run in database
            {
                let mut state = state.lock().await;
                state.shared.run = management_pool.get().await.unwrap().query_one(
                    "insert into wsconnruns values (default, now(), $1, $2) returning run", 
                    &[&state.shared.srv_name, &(0 as i64)]).await.unwrap().get::<_, i64>(0);
                eprintln!("ws-connector: run: {}", state.shared.run);
            }

            update_management_settings(&state, &management_pool).await;

            let (logtx, logrx) = mpsc::channel(10000);
            state.lock().await.shared.logtx = Some(logtx);

            tokio::task::spawn(management_task(state.clone(), management_pool.clone()));
            tokio::task::spawn(log_task(state.clone(), logrx, management_pool.clone()));

            // Status printing task
            {
                let state = state.clone();
                let pool = pool.clone();
                let membership_pool = membership_pool.clone();
                tokio::task::spawn(async move {
                    let _tt = TaskTrace::new("print-status", None, &state).await;
                    let mut interval = tokio::time::interval(Duration::from_millis(1000));
                    loop {
                        interval.tick().await;
                        print_status(&state, &pool, &membership_pool).await;
                    }
                });
            }

            // Locking watchdog
            {
                let watchdog = LockingWatchdog::new(15, cli.task_dump_path.clone());
                watchdog.start(state.clone(), "ws-connector").await;
            }

            // Initialize live importer manager (will be started later)
            let importer_manager = if let Some(Commands::Run { importer_executable, .. }) = &cli.command {
                Some(Arc::new(LiveImporterManager::new(
                    importer_executable.clone(),
                    vec![
                        "--content-moderation-root".to_string(),
                        cli.content_moderation_root.clone(),
                        "--task-dump-path".to_string(),
                        cli.task_dump_path.clone(),
                    ],
                    state.clone(),
                )))
            } else {
                None
            };
            
            // Start live importer manager
            let importer_mgr_ref = if let Some(ref importer_mgr) = importer_manager {
                importer_mgr.start().await.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
                eprintln!("ws-connector: Live importer manager started with executable: {}", importer_executable);
                Some(importer_mgr.clone())
            } else {
                None
            };

            // Start live importer with new callback
            if let Some(importer_mgr) = importer_mgr_ref {
                let imp_config = primal_cache::Config {
                    proxy: None,
                    cache_database_url: "postgresql://pr@127.0.0.1:54017/primal1?application_name=ws-connector&options=-csearch_path%3Dpublic".to_string(),
                    membership_database_url: "postgresql://primal@192.168.11.7:5432/primal?application_name=ws-connector".to_string(),
                    since: None,
                    tables: Vec::new(),
                    import_latest_t_key: "".to_string(),
                };
                use sqlx::pool::PoolOptions;
                let cache_pool = PoolOptions::new()
                    .max_connections(10)
                    .min_connections(1)
                    .connect(&imp_config.cache_database_url).await.unwrap();
                let membership_pool_sqlx = PoolOptions::new()
                    .max_connections(10)
                    .min_connections(1)
                    .connect(&imp_config.membership_database_url).await.unwrap();
                let imp_state = Arc::new(primal_cache::State {
                    config: imp_config,
                    cache_pool: cache_pool.clone(),
                    membership_pool: membership_pool_sqlx,
                    got_sig: Arc::new(AtomicBool::new(false)),
                    since: 0,
                    incremental: true,
                    one_day: false,
                    iteration_step: 0,
                    graph_coverage: 0,
                });
                let state_for_import = state.clone();
                let importer_mgr_for_callback = importer_mgr.clone();
                let cache_pool_for_callback = cache_pool.clone();
                tokio::task::spawn(async move {
                    let _tt = TaskTrace::new("live_importer", None, &state_for_import).await;
                    live_importer(imp_state, state_for_import.clone(), move |_imp_state, e, state| {
                        let importer_mgr = importer_mgr_for_callback.clone();
                        let cache_pool = cache_pool_for_callback.clone();
                        async move {
                            import_event(&importer_mgr, &cache_pool, e, state).await
                        }
                    }).await;
                });

                // Start PostgreSQL LISTEN task for primal_events
                let pg_listen_importer = importer_mgr.clone();
                let pg_listen_state = state.clone();
                let pg_listen_cache_pool = cache_pool.clone();
                tokio::task::spawn(async move {
                    let _tt = TaskTrace::new("pg-listen-primal-events", None, &pg_listen_state).await;
                    if let Err(err) = pg_listen_task(pg_listen_importer, &pg_listen_cache_pool, pg_listen_state, &pool).await {
                        eprintln!("ws-connector: PostgreSQL LISTEN task failed: {}", err);
                    }
                });
            }
            // Start pgwire server
            {
                let state = state.clone();
                let factory = Arc::new(WSConnHandlerFactory::new(state.clone()));

                let server_addr = format!("127.0.0.1:{}", port + 5000);
                use tokio::net::TcpListener;
                let listener = TcpListener::bind(server_addr.clone()).await.unwrap();
                eprintln!("ws-connector: pgwire listening on {}", server_addr);
                tokio::spawn(async move {
                    let _tt = TaskTrace::new("pgwire-listener", None, &state).await;
                    loop {
                        let incoming_socket = listener.accept().await.unwrap();
                        let factory_ref = factory.clone();
                        tokio::spawn(async move { 
                            let _ = pgwire::tokio::process_socket(incoming_socket.0, None, factory_ref).await;
                        });
                    }
                });
            }

            // Initialize handler manager
            let handler_args = vec![
                "--servername".to_string(),
                cli.servername.clone(),
                "--content-moderation-root".to_string(),
                cli.content_moderation_root.clone(),
                "--task-dump-path".to_string(),
                cli.task_dump_path.clone(),
            ];
            
            let handler_manager = Arc::new(HandlerManager::new(handler_executable.clone(), handler_args, state.clone()));
            handler_manager.start().await.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
            
            let router = Arc::new(RequestRouter::new(handler_manager));
            let connection_manager = ConnectionManager::new(router, state.clone());

            let addr = format!("0.0.0.0:{}", port);
            let sa = addr.parse().unwrap();
            let socket = TcpSocket::new_v4().unwrap();
            socket.set_reuseaddr(true).unwrap();
            socket.set_reuseport(true).unwrap();
            socket.bind(sa).expect("failed to bind");

            let listener = socket.listen(1024).unwrap();
            info!("Master process listening on: {}", addr);

            let fd = listener.as_raw_fd();
            while !{ state.lock().await.shared.shutting_down } {
                match listener.accept().await {
                    Ok((stream, _)) => {
                        let conn_id = {
                            let mut state = state.lock().await;
                            state.shared.conn_index += 1;
                            state.shared.conn_index
                        };
                        
                        incr(&state.lock().await.shared.stats.connections);
                        
                        let connection_manager = connection_manager.clone();
                        let backend_addr = backend_addr.clone();
                        let idle_timeout = state.lock().await.shared.idle_connection_timeout;
                        
                        {
                            let state = state.clone();
                            tokio::spawn(async move {
                                if let Err(err) = connection_manager.handle_connection(
                                    &state,
                                    stream,
                                    conn_id,
                                    backend_addr,
                                    idle_timeout,
                                ).await {
                                    eprintln!("ws-connector: Connection handling error: {}", err);
                                }
                            });
                        }
                    }
                    Err(err) => {
                        eprintln!("ws-connector: accept loop: {:?}", err);
                        break;
                    }
                }
            }
            
            unsafe { libc::shutdown(fd, libc::SHUT_RD); }
            eprintln!("ws-connector: waiting some time for remaining requests to complete");
            sleep(Duration::from_millis(5000)).await;
        }

        Some(Commands::Compare {backend1_addr, backend2_addr, sub_id, funcall, kwargs, req}) => {
            let (funcall, kwargs) = parse_req_arguments(funcall, kwargs, req);
            let kwargs_str = serde_json::to_string(&kwargs).unwrap();
            let diffs = compare_backend_api_response(&backend1_addr, &backend2_addr, &sub_id, &funcall, &kwargs_str).await.unwrap();
            if diffs.is_empty() {
                println!("No differences");
            } else {
                println!("Differences, events in response from 1st backend but not present in response of 2nd backend:");
                for d in diffs {
                    println!("    {}", d);
                }
            }
        }

        Some(Commands::Req {backend_addr, sub_id, funcall, kwargs, req}) => {
            let (funcall, kwargs) = parse_req_arguments(funcall, kwargs, req);
            let mut ws = connect_async(backend_addr).await.unwrap().0;
            let responses = send_request_and_get_response(&mut ws, sub_id, &funcall, &kwargs).await.unwrap();
            for r in responses {
                println!("{}", r);
            }
        }
        None => {}
    };

    Ok(())
}

pub fn parse_req_arguments(funcall: &Option<String>, kwargs: &Option<String>, req: &Option<String>) -> (String, Value) {
    if let Some(req) = req {
        let req: Value = serde_json::from_str(&req).unwrap();
        let funcall = req.get(0).and_then(Value::as_str).expect("funcall must be a string");
        let kwargs = req.get(1).unwrap_or(&json!({})).clone();
        (funcall.to_string(), kwargs)
    } else {
        let funcall = funcall.clone().expect("funcall must be provided");
        let kwargs = kwargs.as_ref().expect("kwargs must be provided");
        let kwargs: Value = serde_json::from_str(&kwargs).unwrap();
        (funcall, kwargs.clone())
    }
}

fn make_dbconn_pool(host: &str, port: u16, username: &str, dbname: &str, size: usize, statement_timeout: Option<i64>) -> Pool {
    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host(host);
    pg_config.port(port);
    pg_config.user(username);
    pg_config.dbname(dbname);
    pg_config.application_name("ws-connector");
    if let Some(timeout) = statement_timeout {
        pg_config.options(format!("--statement_timeout={}", timeout));
    }
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
        state.lock().await.shared.logging_enabled = v;
    }
    if let Value::Number(v) = read_var(&management_pool, "idle_connection_timeout").await {
        if let Some(v) = v.as_u64() {
            state.lock().await.shared.idle_connection_timeout = v;
        }
    }
}

async fn management_task(state: Arc<Mutex<State>>, management_pool: Pool) {
    let _tt = TaskTrace::new("management_task", None, &state).await;
    let mut interval = tokio::time::interval(Duration::from_millis(1000));
    loop {
        interval.tick().await;
        update_management_settings(&state, &management_pool).await;
    }
}

async fn log_task(state: Arc<Mutex<State>>, mut logrx: mpsc::Receiver<LogEntry>, management_pool: Pool) {
    let _tt = TaskTrace::new("log_task", None, &state).await;
    let batch_size = state.lock().await.shared.log_sender_batch_size;
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
            Ok(_) => {},
            Err(err) => eprintln!("ws-connector: log_task panic: {err:?}"),
        }
    }
}

async fn print_status(
    state: &Arc<Mutex<State>>,
    pool: &Pool, 
    membership_pool: &Pool,
) {
    let state = state.lock().await;
    let stats = &state.shared.stats;
    
    fn load(x: &AtomicI64) -> i64 { x.load(Ordering::Relaxed) }

    fn pool_status(p: &Pool) -> String { 
        let status = p.status();
        format!("max_size/size/avail/wait: {} / {} / {} / {}", status.max_size, status.size, status.available, status.waiting)
    }

    let live_feed_stats = format!("{}/{}/{} {}/{} {}/{}", 
        state.websockets.len(), state.ws_to_subs.len(), state.subs_to_ws.len(), 
        state.live_events.key_to_subs.len(), state.live_events.sub_to_key.len(),
        state.live_events_from_follows.key_to_subs.len(), state.live_events_from_follows.sub_to_key.len(),
        );

    eprintln!("ws-connector: {}: conn:{} recv:{} sent:{} proxy:{} handle:{} events:{}/{}   pool-{} mpool-{}   live: {}",
        chrono::Utc::now().format("%Y-%m-%d %H:%M:%S"),
        load(&stats.connections), load(&stats.recvmsgcnt), load(&stats.sendmsgcnt), load(&stats.proxyreqcnt), load(&stats.handlereqcnt), load(&stats.importeventcnt), load(&stats.recveventcnt), 
        pool_status(&pool), pool_status(&membership_pool),
        live_feed_stats,
    );
}

async fn distribute_live_event(state: &Arc<Mutex<State>>, eaddr: &EventAddr, e: &primal_cache::Event, cache_pool: &sqlx::Pool<sqlx::Postgres>) -> anyhow::Result<()> {
    let subs = state.lock().await.live_events.key_to_subs.get(eaddr).cloned().unwrap_or_default();

    let mut res = Vec::new();
    for ((ws_id, sub), (user_pubkey, content_moderation_mode)) in &subs {
        let r = sqlx::query!(r#"select live_feed_is_hidden($1, $2, live_feed_hosts($4, $5, $6), $3) as hidden"#,
            e.id.0, user_pubkey.0, content_moderation_mode, 
            eaddr.kind, eaddr.pubkey.0, eaddr.identifier,
        ).fetch_one(cache_pool).await?;
        if let Some(false) = r.hidden {
            let cw = state.lock().await.websockets.get(ws_id).map(|cw| cw.clone());
            if let Some(cw) = cw {
                let e_json = serde_json::to_string(&e)?;
                eprintln!("ws-connector: {}", e_json);
                {
                    let cw = &mut cw.lock().await;
                    if let Err(err) = send_event_str(sub, &e_json, cw).await {
                        eprintln!("ws-connector: error sending event to sub {}: {:?}", sub, err);
                    }
                }
                res.push(sub.clone());
            }
        }
    }

    if !res.is_empty() {
        eprintln!("ws-connector: sent live feed {} event {:?} to subs: {:?}", eaddr, e.id, res);
    }

    Ok(())
}

async fn distribute_live_event_from_follows(state: &Arc<Mutex<State>>, user_pubkey: &PubKeyId, e: &primal_cache::Event) -> anyhow::Result<()> {
    let subs = state.lock().await.live_events_from_follows.key_to_subs.get(user_pubkey).cloned().unwrap_or_default();

    for ((ws_id, sub), ()) in &subs {
        let cw = state.lock().await.websockets.get(ws_id).map(|cw| cw.clone());
        if let Some(cw) = cw {
            let e_json = serde_json::to_string(&e)?;
            eprintln!("ws-connector: Live event from follows {} for sub {}: {}", user_pubkey, sub, e_json);
            {
                let cw = &mut cw.lock().await;
                if let Err(err) = send_event_str(sub, &e_json, cw).await {
                    eprintln!("ws-connector: error sending event to sub {}: {:?}", sub, err);
                }
            }
        }
    }

    Ok(())
}

// New import_event function that uses LiveImporterManager and handles distribution
async fn import_event(importer_manager: &Arc<LiveImporterManager>, cache_pool: &sqlx::Pool<sqlx::Postgres>, e: primal_cache::Event, state: Arc<Mutex<State>>) -> anyhow::Result<()> {
    incr(&state.lock().await.shared.stats.recveventcnt);

    // Get subscribed users for follows-based processing
    let subscribed_users = {
        let state = state.lock().await;
        state.live_events_from_follows.sub_to_key.values().cloned().collect()
    };

    // Send event to live importer for processing
    match importer_manager.import_event(e.clone(), subscribed_users).await {
        Ok(processed_events) => {
            incr(&state.lock().await.shared.stats.importeventcnt);

            // Process the returned distribution events
            for distribution in processed_events {
                match distribution.distribution_type {
                    ws_connector::shared::DistributionType::EventAddr { eaddr } => {
                        distribute_live_event(&state, &eaddr, &distribution.event, cache_pool).await?;
                    }
                    ws_connector::shared::DistributionType::FollowsBased { user_pubkey } => {
                        distribute_live_event_from_follows(&state, &user_pubkey, &distribution.event).await?;
                    }
                }
            }
        }
        Err(err) => {
            eprintln!("ws-connector: Live importer error: {}", err);
        }
    }

    Ok(())
}


async fn pg_listen_task(
    importer_manager: Arc<LiveImporterManager>,
    cache_pool: &sqlx::Pool<sqlx::Postgres>,
    state: Arc<Mutex<State>>,
    pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    loop {
        match pg_listen_task_inner(importer_manager.clone(), cache_pool, state.clone(), pool).await {
            Ok(_) => {
                eprintln!("ws-connector: PostgreSQL LISTEN task completed unexpectedly");
            }
            Err(err) => {
                eprintln!("ws-connector: PostgreSQL LISTEN task error: {}, retrying in 5 seconds", err);
                sleep(Duration::from_millis(5000)).await;
            }
        }
    }
}

async fn pg_listen_task_inner(
    importer_manager: Arc<LiveImporterManager>,
    cache_pool: &sqlx::Pool<sqlx::Postgres>,
    state: Arc<Mutex<State>>,
    _pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Create a direct connection for LISTEN functionality
    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host("127.0.0.1");
    pg_config.port(54017);
    pg_config.user("pr");
    pg_config.dbname("primal1");
    pg_config.application_name("ws-connector-listen");
    
    let (client, mut connection) = pg_config.connect(NoTls).await?;

    tokio::spawn(async move {
        // Start listening for primal_events notifications
        let _ = client.execute("LISTEN primal_events", &[]).await;
        eprintln!("ws-connector: Started listening for PostgreSQL notifications on 'primal_events' channel");
        loop {
            if let Err(e) = client.query("SELECT pg_sleep(2)", &[]).await {
                eprintln!("ws-connector: PostgreSQL keepalive query failed: {}", e);
                break;
            }
        }
    });
    
    // Process messages using direct polling
    loop {
        eprintln!("ws-connector: Waiting for PostgreSQL notifications...");
        tokio::select! {
            // Poll for connection messages
            message = poll_next_message(&mut connection) => {
                match message {
                    Ok(AsyncMessage::Notification(notification)) => {
                        eprintln!("ws-connector: Received notification on channel '{}' with payload: '{}'", 
                            notification.channel(), notification.payload());
                        
                        // Process the notification if it's from our channel
                        if notification.channel() == "primal_events" {
                            match process_primal_event_notification(&importer_manager, cache_pool, state.clone(), &notification).await {
                                Ok(_) => {
                                    eprintln!("ws-connector: Successfully processed notification");
                                }
                                Err(e) => {
                                    eprintln!("ws-connector: Error processing notification: {}", e);
                                }
                            }
                        }
                    }
                    Ok(AsyncMessage::Notice(notice)) => {
                        eprintln!("ws-connector: PostgreSQL notice: {}", notice.message());
                    }
                    Ok(_) => {
                        // Handle other message types if needed
                    }
                    Err(e) => {
                        eprintln!("ws-connector: Error polling for messages: {}", e);
                        return Err(e);
                    }
                }
            }
            
            // // Periodic keepalive check every 3 seconds
            // _ = tokio::time::sleep(Duration::from_millis(3000)) => {
            //     // Keepalive query to ensure connection stays alive
            //     if let Err(e) = client.query("SELECT 1", &[]).await {
            //         eprintln!("ws-connector: PostgreSQL keepalive query failed: {}", e);
            //         return Err(e.into());
            //     }
            //     eprintln!("ws-connector: PostgreSQL LISTEN connection active");
            // }
        }
    }
}

// Helper function to poll for the next message from PostgreSQL connection
async fn poll_next_message(
    connection: &mut tokio_postgres::Connection<tokio_postgres::Socket, tokio_postgres::tls::NoTlsStream>
) -> Result<AsyncMessage, Box<dyn std::error::Error + Send + Sync>> {
    use std::future::Future;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    
    struct MessageFuture<'a> {
        connection: &'a mut tokio_postgres::Connection<tokio_postgres::Socket, tokio_postgres::tls::NoTlsStream>,
    }
    
    impl<'a> Future for MessageFuture<'a> {
        type Output = Result<AsyncMessage, Box<dyn std::error::Error + Send + Sync>>;
        
        fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            match self.connection.poll_message(cx) {
                Poll::Ready(Some(result)) => Poll::Ready(result.map_err(|e| e.into())),
                Poll::Ready(None) => Poll::Ready(Err("PostgreSQL connection closed".into())),
                Poll::Pending => Poll::Pending,
            }
        }
    }
    
    MessageFuture { connection }.await
}

async fn process_primal_event_notification(
    importer_manager: &Arc<LiveImporterManager>,
    cache_pool: &sqlx::Pool<sqlx::Postgres>,
    state: Arc<Mutex<State>>,
    notification: &tokio_postgres::Notification,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let payload = notification.payload();
    
    // Parse the JSON payload to extract the event
    match serde_json::from_str::<primal_cache::Event>(payload) {
        Ok(event) => {
            eprintln!("ws-connector: Processing event from PostgreSQL notification: id={:?}, kind={}, pubkey={:?}", 
                event.id, event.kind, event.pubkey);
            
            // Use the existing import_event function that handles the full workflow
            // including ws-import subprocess communication and distribution
            match import_event(importer_manager, cache_pool, event, state).await {
                Ok(_) => {
                    eprintln!("ws-connector: PostgreSQL LISTEN event processed successfully");
                }
                Err(err) => {
                    eprintln!("ws-connector: Error processing PostgreSQL LISTEN event: {}", err);
                    return Err(err.into());
                }
            }
        }
        Err(err) => {
            eprintln!("ws-connector: Failed to parse event from PostgreSQL notification payload: {}", err);
            eprintln!("ws-connector: Payload was: {}", payload);
            return Err(err.into());
        }
    }
    
    Ok(())
}

