use std::io::{self, BufRead, BufReader, Write};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use tokio_postgres::NoTls;
use clap::Parser;
use tokio::signal::unix::{signal, SignalKind};
use futures_util::future::FutureExt;

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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = env_logger::try_init();
    
    let cli = Cli::parse();
    
    let pool = make_dbconn_pool("127.0.0.1", 54017, "pr", "primal1", 16, Some(30000));
    let membership_pool = make_dbconn_pool("192.168.11.7", 5432, "primal", "primal", 16, None);

    let srv_name = Some(cli.servername);
    let primal_pubkey = Some(hex::decode("532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb").unwrap());
    let default_app_settings_filename = format!("{}/default-settings.json", cli.content_moderation_root);
    let app_releases_filename = format!("{}/app-releases.json", cli.content_moderation_root);

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
                tokio::spawn(async move {
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
