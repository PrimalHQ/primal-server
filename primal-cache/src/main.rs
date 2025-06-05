#![allow(unused)]

use chrono::TimeZone;
use primal_cache::{parse_parent_eid, parse_zap_receipt, EventRow};
use primal_cache::{
    event_to_json, log, parse_event, Config, Event, EventAddr, EventId, EventReference, PubKeyId, State, Tag, set_var, get_var, 
};
use primal_cache::{Ref, insert_edge};

use serde_json::json;
use serde_json::Value;

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> anyhow::Result<()> {
    primal_cache::main_1(main_2, main_2).await
}

pub const FOLLOW_LIST: i64 = 39089;

async fn import_event(state: &State, e: &Event) -> Result<(), anyhow::Error> {
    println!("{:?} {:?} {}", e.id, e.kind, chrono::Utc.timestamp_opt(e.created_at, 0).single().unwrap_or_default().to_rfc3339());
    match e.kind {
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
                let eid_ref = e.id.get_ref(state).await?;

                let mut tx = state.cache_pool.begin().await?;
                // for r in sqlx::query!(r#"select id from follow_lists where pubkey = $1 and identifier = $2"#,
                //     e.pubkey.0, identifier,
                // ).fetch_all(&mut *tx).await? {
                //     sqlx::query!(r#"delete from edges where output_id = $1"#, r.id).execute(&mut *tx).await?;
                // }
                sqlx::query!(
                    r#"delete from follow_lists where pubkey = $1 and identifier = $2"#,
                    e.pubkey.0, identifier,
                ).execute(&mut *tx).await?;
                for pk in pks {
                    let r = sqlx::query!(r#"
                        insert into follow_lists (pubkey, identifier, follow_pubkey)
                        values ($1, $2, $3)
                        on conflict (pubkey, identifier, follow_pubkey) do nothing
                        returning (id)
                        "#,
                        e.pubkey.0,
                        identifier,
                        pk.0,
                    ).fetch_one(&mut *tx).await?;
                    // insert_edge(&mut *tx, eid_ref, r.id, None).await?;
                }
                tx.commit().await?;
            }
        }
        _ => {}
    }
    Ok(())
}

async fn main_2(config: Config, state: State) -> anyhow::Result<()> {{
    let tstart = std::time::Instant::now();

    let since = state.since;
    let until = chrono::Utc::now().timestamp() as i64;
    let mut last_created_at = since;

    for r in sqlx::query_as!(EventRow, r#"
        select * from events 
        where created_at >= $1 
          and created_at < $2 
          and kind in ($3)
        order by created_at
        "#, since, until, FOLLOW_LIST).fetch_all(&state.cache_pool).await.unwrap() {

        match parse_event(r) {
            Ok(e) => {
                let res = import_event(&state, &e).await;
                if let Err(err) = res {
                    println!("Error importing event: {err:?}");
                }
                last_created_at = e.created_at;
            }
            Err(err) => {
                println!("error parsing event: {err:?}");
            }
        }
    }

    set_var(&state.cache_pool, &config.import_latest_t_key, Value::from(last_created_at)).await.unwrap();

    dbg!(tstart.elapsed());
    Ok(())
}}

