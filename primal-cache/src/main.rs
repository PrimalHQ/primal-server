#![allow(unused)]

use std::sync::atomic::Ordering;

use chrono::TimeZone;
use primal_cache::{parse_parent_eid, parse_zap_receipt, EventRow};
use primal_cache::{
    log, parse_event, Config, Event, EventAddr, EventId, EventReference, PubKeyId, State, Tag, set_var, get_var, 
    recent_items,
};
use primal_cache::{Ref, insert_edge};
use primal_cache::{FOLLOW_LIST, LIVE_EVENT, ZAP_RECEIPT, parse_live_event, LiveEventStatus, LiveEventParticipantType};

use serde_json::json;
use serde_json::Value;

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> anyhow::Result<()> {
    primal_cache::main_1(main_2, main_2).await
}

async fn import_event(state: &State, e: &Event) -> Result<(), anyhow::Error> {
    println!("{:?} {:?} {}", e.id, e.kind, chrono::Utc.timestamp_opt(e.created_at, 0).single().unwrap_or_default().to_rfc3339());
    // match e.kind {
    //     _ => {}
    // }
    Ok(())
}

async fn main_2(config: Config, state: State) -> anyhow::Result<()> {{
    let mut seen_events = recent_items::RecentItems::new(10000);

    let kinds = format!("{{{}}}", vec![FOLLOW_LIST, LIVE_EVENT, ZAP_RECEIPT].iter().map(|k| k.to_string()).collect::<Vec<_>>().join(","));

    let mut since = state.since;

    loop {
        if state.got_sig.load(Ordering::SeqCst) { break; }

        let until = chrono::Utc::now().timestamp() as i64;
        let mut last_created_at = since;

        for r in sqlx::query_as!(EventRow, r#"
            select * from events 
            where imported_at >= $1 
              and imported_at <= $2 
              and kind = any ($3::varchar::int[])
            order by created_at
            "#, since, until, kinds).fetch_all(&state.cache_pool).await.unwrap() {

            match parse_event(r) {
                Ok(e) => {
                    if seen_events.push(e.id.clone()) {
                        let res = import_event(&state, &e).await;
                        if let Err(err) = res {
                            println!("error importing event: {err:?}");
                        }
                        last_created_at = e.created_at;
                    }
                }
                Err(err) => {
                    println!("error parsing event: {err:?}");
                }
            }
        }

        // set_var(&state.cache_pool, &config.import_latest_t_key, Value::from(last_created_at)).await.unwrap();
        set_var(&state.cache_pool, &config.import_latest_t_key, Value::from(until)).await.unwrap();

        since = until;

        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
    }

    Ok(())
}}

