use std::io::{self, BufRead, BufReader, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::fs::OpenOptions;
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::NoTls;
use clap::Parser;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::Mutex;
use tokio::time::{Duration, Instant};
use futures_util::future::FutureExt;
use serde_json::{json, Value};

use ws_connector::shared::{HandlerRequest, HandlerResponse, ReqStatus};
use ws_connector::shared::task_dump::runtime_dump;
use ws_connector::handlers::handlers::ReqHandlers;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[arg(short, long)]
    servername: String,

    #[arg(short, long, default_value="content-moderation")]
    content_moderation_root: String,

    #[arg(long, default_value="tmp")]
    task_dump_path: String,

    #[arg(long)]
    log_request: Option<String>,
}

fn make_dbconn_pool(host: &str, port: u16, username: &str, dbname: &str, size: usize, statement_timeout: Option<i64>) -> Pool {
    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host(host);
    pg_config.port(port);
    pg_config.user(username);
    pg_config.dbname(dbname);
    pg_config.application_name("ws-handlers");
    if let Some(timeout) = statement_timeout {
        pg_config.options(format!("--statement_timeout={}", timeout));
    }
    let mgr_config = ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    };
    let mgr = Manager::from_config(pg_config, NoTls, mgr_config);
    Pool::builder(mgr).max_size(size).build().unwrap()
}

// Struct to hold metrics logging state
struct MetricsLogger {
    file: Option<Mutex<std::fs::File>>,
    enabled: AtomicBool,
    min_request_duration: AtomicU64, // stores f64 bits
}

impl MetricsLogger {
    fn new(log_path: Option<String>) -> Self {
        let file = log_path.and_then(|path| {
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| eprintln!("ws-handlers: Failed to open log file {}: {}", path, e))
                .ok()
                .map(Mutex::new)
        });
        Self {
            file,
            enabled: AtomicBool::new(false),
            min_request_duration: AtomicU64::new(0f64.to_bits()),
        }
    }

    fn is_enabled(&self) -> bool {
        self.file.is_some() && self.enabled.load(Ordering::Relaxed)
    }

    fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
    }

    fn get_min_request_duration(&self) -> f64 {
        f64::from_bits(self.min_request_duration.load(Ordering::Relaxed))
    }

    fn set_min_request_duration(&self, duration: f64) {
        self.min_request_duration.store(duration.to_bits(), Ordering::Relaxed);
    }

    async fn log(&self, entry: &Value) {
        if let Some(ref file) = self.file {
            let mut f = file.lock().await;
            if let Ok(json_str) = serde_json::to_string(entry) {
                let _ = writeln!(f, "{}", json_str);
            }
        }
    }

    async fn flush(&self) {
        if let Some(ref file) = self.file {
            use std::io::Write;
            let mut f = file.lock().await;
            let _ = f.flush();
        }
    }
}

async fn read_metrics_logging_enabled(pool: &Pool) -> bool {
    match pool.get().await {
        Ok(client) => {
            match client.query_one(
                "select value from wsconnvars where name = $1",
                &[&"metrics_logging_enabled"]
            ).await {
                Ok(row) => {
                    let value: Value = row.get(0);
                    value.as_bool().unwrap_or(false)
                }
                Err(_) => false
            }
        }
        Err(_) => false
    }
}

async fn read_metrics_logging_min_request_duration(pool: &Pool) -> f64 {
    match pool.get().await {
        Ok(client) => {
            match client.query_one(
                "select value from wsconnvars where name = $1",
                &[&"metrics_logging_min_request_duration"]
            ).await {
                Ok(row) => {
                    let value: Value = row.get(0);
                    value.as_f64().unwrap_or(0.0)
                }
                Err(_) => 0.0
            }
        }
        Err(_) => 0.0
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = env_logger::try_init();

    let cli = Cli::parse();

    let pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 16, Some(30000));
    let membership_pool = make_dbconn_pool("192.168.11.7", 5432, "primal", "primal", 16, None);
    let management_pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 4, None);

    let srv_name = Some(cli.servername);
    let primal_pubkey = Some(hex::decode("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb").unwrap());
    let default_app_settings_filename = format!("{}/default-settings.json", cli.content_moderation_root);
    let app_releases_filename = format!("{}/app-releases.json", cli.content_moderation_root);

    // Initialize metrics logger
    let metrics_logger = Arc::new(MetricsLogger::new(cli.log_request));

    // Test database connections
    pool.get().await.unwrap().query_one("select 1", &[]).await.unwrap().get::<_, i32>(0);
    membership_pool.get().await.unwrap().query_one("select 1", &[]).await.unwrap().get::<_, i32>(0);

    // Signal handler for SIGUSR2
    {
        let _task_dump_path = cli.task_dump_path.clone();
        let mut sig = signal(SignalKind::user_defined2()).unwrap();
        tokio::task::spawn(async move {
            loop {
                sig.recv().await;
                eprintln!("ws-handlers: got signal USR2");
                runtime_dump("ws-handlers").await;
            }
        });
    }

    // Periodic task to check metrics_logging settings from database and flush log file
    {
        let metrics_logger = metrics_logger.clone();
        let management_pool = management_pool.clone();
        tokio::task::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                let enabled = read_metrics_logging_enabled(&management_pool).await;
                let min_duration = read_metrics_logging_min_request_duration(&management_pool).await;
                metrics_logger.set_enabled(enabled);
                metrics_logger.set_min_request_duration(min_duration);
                if enabled {
                    metrics_logger.flush().await;
                }
            }
        });
    }

    let stdin = io::stdin();
    let reader = BufReader::new(stdin.lock());

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        match serde_json::from_str::<HandlerRequest>(&line) {
            Ok(request) => {
                let pool = pool.clone();
                let membership_pool = membership_pool.clone();
                let srv_name = srv_name.clone();
                let primal_pubkey = primal_pubkey.clone();
                let default_app_settings_filename = default_app_settings_filename.clone();
                let app_releases_filename = app_releases_filename.clone();
                let metrics_logger = metrics_logger.clone();
                tokio::spawn(async move {
                    // Capture request info for logging before moving request
                    let log_funcall = request.funcall.clone();
                    let log_kwargs = request.kwargs.clone();
                    let log_conn_id = request.conn_id;
                    let log_sub_id = request.sub_id.clone();
                    let should_log = metrics_logger.is_enabled();

                    let start_time = Instant::now();
                    let response = match std::panic::AssertUnwindSafe(ReqHandlers::handle_request(
                        request.conn_id,
                        &request.sub_id,
                        &request.funcall,
                        &request.kwargs,
                        &pool,
                        &membership_pool,
                        &srv_name,
                        &primal_pubkey,
                        &default_app_settings_filename,
                        &app_releases_filename,
                    )).catch_unwind().await {
                        Ok(r) => {
                            match r {
                                Ok((ReqStatus::Handled, resp)) => {
                                    HandlerResponse::handled(request.id, resp)
                                }
                                Ok((ReqStatus::NotHandled, _)) => {
                                    HandlerResponse::not_handled(request.id)
                                }
                                Ok((ReqStatus::Notice(notice), _)) => {
                                    HandlerResponse::notice(request.id, notice)
                                }
                                Err(err) => {
                                    HandlerResponse::error(request.id, err.description)
                                }
                            }
                        },
                        Err(err) => {
                            eprintln!("ws-handlers: sub_id: {}, funcall: {}, panic: {err:?}", request.sub_id, request.funcall);
                            HandlerResponse::error(request.id.to_string(), format!("handler error: {:?}", err))
                        }
                    };
                    let elapsed = start_time.elapsed();

                    // Log request metrics if enabled and duration exceeds minimum
                    let elapsed_secs = elapsed.as_secs_f64();
                    let min_duration = metrics_logger.get_min_request_duration();
                    if should_log && response.handled && elapsed_secs >= min_duration {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        let timestamp = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64())
                            .unwrap_or(0.0);

                        let log_entry = json!({
                            "t": timestamp,
                            "time": elapsed_secs,
                            "funcall": log_funcall,
                            "kwargs": log_kwargs,
                            "ws": format!("{}", log_conn_id),
                            "subid": log_sub_id,
                        });

                        metrics_logger.log(&log_entry).await;
                    }

                    if let Ok(response_json) = serde_json::to_string(&response) {
                        {
                            let mut stdout = io::stdout().lock();
                            stdout.write_all(format!("{}\n", response_json).as_bytes()).unwrap();
                            stdout.flush().unwrap();
                        }
                    }
                });
            }
            Err(err) => {
                eprintln!("ws-handlers: Failed to parse request: {}", err);
                let error_response = HandlerResponse::error("unknown".to_string(), format!("Parse error: {}", err));
                let response_json = serde_json::to_string(&error_response)?;
                {
                    let mut stdout = io::stdout().lock();
                    stdout.write_all(format!("{}\n", response_json).as_bytes()).unwrap();
                    stdout.flush().unwrap();
                }
            }
        }
    }

    Ok(())
}
