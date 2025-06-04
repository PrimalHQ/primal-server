#![allow(unused)]

use chrono::TimeZone;
use primal_cache::{parse_parent_eid, parse_zap_receipt, EventRow};
use primal_cache::{
    event_to_json, log, parse_event, Config, Event, EventAddr, EventId, EventReference, PubKeyId, State, Tag
};

use serde_json::json;

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> anyhow::Result<()> {
    primal_cache::main_1(main_2).await
}

pub const FOLLOW_LIST: i64 = 39089;

async fn update_id_table(state: &State, id: i64, table_name: &str) -> anyhow::Result<()> {
    sqlx::query!(r#"
        insert into cache.id_table (id, table_name) values ($1, $2)
        on conflict (id, table_name) do nothing
        "#, id, table_name).execute(&state.cache_pool).await?;
    Ok(())
}

trait Ref {
    fn to_ref(&self) -> serde_json::Value;

    async fn get_ref(&self, state: &State) -> anyhow::Result<i64> {
        let rf = self.to_ref();
        if let Some(r) = sqlx::query!(r#"
            select id from cache.refs where ref = $1
            "#, &rf).fetch_optional(&state.cache_pool).await? 
        {
            return Ok(r.id);
        }
        let r = sqlx::query!(r#"
            insert into cache.refs (ref) values ($1)
            on conflict (ref) do update set ref = excluded.ref
            returning (id)
            "#, &rf).fetch_one(&state.cache_pool).await?;
        Ok(r.id)
    }
}

impl Ref for EventId {
    fn to_ref(&self) -> serde_json::Value {
        json!({"table": "events", "key": {"id": self}})
    }
}
impl Ref for EventAddr {
    fn to_ref(&self) -> serde_json::Value {
        json!({"table": "parametrized_replaceable_events", "key": {"kind": self.kind, "pubkey": self.pubkey, "identifier": self.identifier}})
    }
}

async fn get_edgetype(state: &State, name: &str) -> anyhow::Result<i64> {
    let r = sqlx::query!(r#"
        insert into cache.edgetypes (name) values ($1)
        on conflict (name) do nothing
        returning (id)
        "#, name).fetch_one(&state.cache_pool).await?;
    Ok(r.id)
}

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
                for r in sqlx::query!(r#"select id from cache.follow_lists where pubkey = $1 and identifier = $2"#,
                    e.pubkey.0, identifier,
                ).fetch_all(&mut *tx).await? {
                    sqlx::query!(r#"delete from cache.edges where output_id = $1"#, r.id).execute(&mut *tx).await?;
                }
                sqlx::query!(
                    r#"delete from cache.follow_lists where pubkey = $1 and identifier = $2"#,
                    e.pubkey.0, identifier,
                ).execute(&mut *tx).await?;
                for pk in pks {
                    let r = sqlx::query!(r#"
                        insert into cache.follow_lists (pubkey, identifier, follow_pubkey)
                        values ($1, $2, $3)
                        on conflict (pubkey, identifier, follow_pubkey) do nothing
                        returning (id)
                        "#,
                        e.pubkey.0,
                        identifier,
                        pk.0,
                    ).fetch_one(&mut *tx).await?;
                    sqlx::query!(r#"insert into cache.edges (input_id, output_id) values ($1, $2)"#,
                        eid_ref,
                        r.id,
                    ).execute(&mut *tx).await?;
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
    for r in sqlx::query_as!(EventRow, r#"
        select * from events 
        where created_at >= $1 
          and created_at < $2 
          and kind in ($3)
        order by created_at
        "#, since, until, FOLLOW_LIST).fetch_all(&state.cache_pool).await.unwrap() {

        match parse_event(r).await {
            Ok(e) => {
                let res = import_event(&state, &e).await;
                if let Err(err) = res {
                    println!("Error importing event: {err:?}");
                }
            }
            Err(err) => {
                println!("error parsing event: {err:?}");
            }
        }
    }
    dbg!(tstart.elapsed());
    Ok(())
}}

