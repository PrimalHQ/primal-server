use std::io::{self, BufRead, BufReader, Write};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use clap::Parser;
use tokio::signal::unix::{signal, SignalKind};
// use tokio::time::Duration;
// use futures_util::future::FutureExt;

use primal_cache::{Event, EventAddr, PubKeyId, Tag, LIVE_EVENT, ZAP_RECEIPT, FOLLOW_LIST, LiveEventStatus, LiveEventParticipantType, parse_zap_receipt, parse_live_event};
use ws_connector::shared::{ImporterRequest, ImporterResponse, ProcessedEventDistribution, DistributionType};
use ws_connector::shared::task_dump::runtime_dump;

use serde_json::json;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[arg(short, long, default_value="content-moderation")]
    content_moderation_root: String,

    #[arg(long, default_value="tmp")]
    task_dump_path: String,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = env_logger::try_init();
    
    let cli = Cli::parse();
    
    // Initialize the import state similar to connector process
    let imp_config = primal_cache::Config {
        proxy: None,
        cache_database_url: "postgresql://pr@127.0.0.1:54017/primal1?application_name=ws-importer&options=-csearch_path%3Dpublic".to_string(),
        membership_database_url: "postgresql://primal@192.168.11.7:5432/primal?application_name=ws-importer".to_string(),
        since: None,
        tables: Vec::new(),
        import_latest_t_key: "".to_string(),
    };
    
    use sqlx::pool::PoolOptions;
    let cache_pool = PoolOptions::new()
        .max_connections(10)
        .min_connections(1)
        .connect(&imp_config.cache_database_url).await?;
    let membership_pool_sqlx = PoolOptions::new()
        .max_connections(10)
        .min_connections(1)
        .connect(&imp_config.membership_database_url).await?;
        
    let imp_state = Arc::new(primal_cache::State {
        config: imp_config,
        cache_pool,
        membership_pool: membership_pool_sqlx,
        got_sig: Arc::new(AtomicBool::new(false)),
        since: 0,
        incremental: true,
        one_day: false,
        iteration_step: 0,
        graph_coverage: 0,
    });

    // Signal handler for SIGUSR2
    {
        let _task_dump_path = cli.task_dump_path.clone();
        let mut sig = signal(SignalKind::user_defined2()).unwrap();
        tokio::task::spawn(async move {
            loop {
                sig.recv().await;
                eprintln!("ws-importer: got signal USR2");
                runtime_dump("ws-importer").await;
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

        match serde_json::from_str::<ImporterRequest>(&line) {
            Ok(request) => {
                let response = match process_event_import(&imp_state, &request.event, &request.subscribed_users).await {
                    Ok(processed_events) => {
                        ImporterResponse::success(request.id, processed_events)
                    }
                    Err(err) => {
                        ImporterResponse::error(request.id, format!("Import error: {}", err))
                    }
                };

                let response_json = serde_json::to_string(&response)?;
                {
                    let mut stdout = io::stdout().lock();
                    stdout.write_all(format!("{}\n", response_json).as_bytes()).unwrap();
                    stdout.flush().unwrap();
                }
            }
            Err(err) => {
                eprintln!("ws-importer: Failed to parse request: {}", err);
                let error_response = ImporterResponse::error("unknown".to_string(), format!("Parse error: {}", err));
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

async fn process_event_import(
    imp_state: &Arc<primal_cache::State>,
    e: &Event,
    subscribed_users: &Vec<PubKeyId>,
) -> anyhow::Result<Vec<ProcessedEventDistribution>> {
    // eprintln!("ws-importer: Processing event: {}, kind: {}, created_at: {:?}", 
    //     e.id, e.kind, chrono::DateTime::from_timestamp(e.created_at as i64, 0));

    let mut distributions = Vec::new();

    // Process event addresses from tags
    for t in &e.tags {
        match t {
            Tag::EventAddr(eaddr, _) => {
                distributions.push(ProcessedEventDistribution {
                    distribution_type: DistributionType::EventAddr { eaddr: eaddr.clone() },
                    event: e.clone(),
                });
            }
            _ => {}
        }
    }

    match e.kind {
        LIVE_EVENT => {
            if let Some(le) = parse_live_event(&e) {
                match le.status {
                    LiveEventStatus::Live => {
                        let mut tx = imp_state.cache_pool.begin().await?;
                        sqlx::query!(r#"
                            delete from live_event_participants where kind = $1 and pubkey = $2 and identifier = $3
                            "#, e.kind, e.pubkey.0, le.identifier,
                        ).execute(&mut *tx).await?;
                        let mut pks = Vec::new();
                        pks.push(e.pubkey.clone());
                        for (pk, ptype) in &le.participants {
                            if *ptype == LiveEventParticipantType::Host {
                                pks.push(pk.clone());
                            }
                        }
                        for pk in pks {
                            sqlx::query!(r#"
                                insert into live_event_participants (kind, pubkey, identifier, participant_pubkey, event_id, created_at)
                                values ($1, $2, $3, $4, $5, $6)
                                on conflict do nothing
                                "#,
                                e.kind, e.pubkey.0, le.identifier, pk.0,
                                e.id.0, e.created_at, 
                            ).execute(&mut *tx).await?;
                        }
                        tx.commit().await?;
                    },
                    LiveEventStatus::Ended => {
                        sqlx::query!(r#"
                            delete from live_event_participants where kind = $1 and pubkey = $2 and identifier = $3
                            "#, e.kind, e.pubkey.0, le.identifier,
                        ).execute(&imp_state.cache_pool).await?;
                    },
                    LiveEventStatus::Unknown => { }
                }

                // Process main live event
                {
                    let eaddr = EventAddr::new(le.kind, le.pubkey.clone(), le.identifier.clone());
                    distributions.push(ProcessedEventDistribution {
                        distribution_type: DistributionType::EventAddr { eaddr },
                        event: e.clone(),
                    });
                }

                // Process follows-based distribution
                {
                    let mut participants = Vec::new();
                    participants.push(le.pubkey.clone());
                    for (pk, ptype) in le.participants {
                        if ptype == primal_cache::LiveEventParticipantType::Host {
                            participants.push(pk);
                        }
                    }
                    let participants_arr = format!("{{{}}}", participants.iter().map(|pk| format!("\\\\x{}", hex::encode(pk))).collect::<Vec<_>>().join(","));

                    let users_arr = format!("{{{}}}", subscribed_users.iter().map(|pk| format!("\\\\x{}", hex::encode(pk))).collect::<Vec<_>>().join(","));

                    for r in sqlx::query!(r#"
                        select distinct pf.follower_pubkey from pubkey_followers pf
                        where pf.follower_pubkey = any($1::varchar::bytea[])
                          and pf.pubkey = any($2::varchar::bytea[])
                        "#,
                        &users_arr, &participants_arr,
                    ).fetch_all(&imp_state.cache_pool).await? {
                        if let Some(user_pubkey) = r.follower_pubkey {
                            let user_pubkey = PubKeyId(user_pubkey);
                            distributions.push(ProcessedEventDistribution {
                                distribution_type: DistributionType::FollowsBased { user_pubkey },
                                event: e.clone(),
                            });
                        }
                    }
                }

                // report live event to cache storage listener
                sqlx::query!(
                    r#"select pg_notify('cache_storage', $1::varchar)
                        "#, json!({
                            "type": "live_event",
                            "kind": le.kind,
                            "pubkey": le.pubkey,
                            "identifier": le.identifier,
                        }).to_string()).execute(&imp_state.cache_pool).await?;
            }
        },

        FOLLOW_LIST => {
            let mut pks = vec![];
            let mut identifier = None;
            for t in &e.tags {
                match t {
                    Tag::PubKeyId(pk, _) => {
                        pks.push(pk);
                    }
                    Tag::Any(fields) if fields.len() >= 2 && fields[0] == "d" => {
                        identifier = Some(fields[1].clone());
                    }
                    _ => {}
                }
            }
            if let Some(identifier) = identifier {
                let mut tx = imp_state.cache_pool.begin().await?;
                sqlx::query!(
                    r#"delete from follow_lists where pubkey = $1 and identifier = $2"#,
                    e.pubkey.0, identifier,
                ).execute(&mut *tx).await?;
                for pk in pks {
                    sqlx::query!(r#"
                        insert into follow_lists (pubkey, identifier, follow_pubkey)
                        values ($1, $2, $3)
                        on conflict (pubkey, identifier, follow_pubkey) do update set
                        follow_pubkey = excluded.follow_pubkey
                        "#,
                        e.pubkey.0,
                        identifier,
                        pk.0,
                    ).execute(&mut *tx).await?;
                }
                tx.commit().await?;
            }
        }

        ZAP_RECEIPT => {
            if let Some(zr) = parse_zap_receipt(e) {
                // eprintln!("ws-importer: eid: {}, invoice: {}", e.id, zr.invoice);
                sqlx::query!(r#"
                    insert into zap_receipt_invoices (zap_receipt_eid, invoice)
                    values ($1, $2) on conflict do nothing
                    "#,
                    e.id.0, zr.invoice,
                ).execute(&imp_state.cache_pool).await?;
            } else {
                eprintln!("ws-importer: error parsing zap receipt: {}", e.id);
            }
        }

        _ => {}
    }

    Ok(distributions)
}

