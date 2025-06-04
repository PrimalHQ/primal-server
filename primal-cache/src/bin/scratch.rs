#![allow(unused)]

use primal_cache::{parse_parent_eid, parse_zap_receipt, EventRow};
use primal_cache::{
    event_to_json, log, parse_event, Config, Event, EventAddr, EventId, EventReference, PubKeyId, RollingMap, State, Tag
};

use sha2::{Sha256, Digest};
use futures::stream::{StreamExt, iter};

use std::collections::HashMap;

pub use clap::Parser;

use std::future::Future;

pub use sqlx::pool::PoolOptions;
pub use sqlx::Postgres;
pub use sqlx::Pool;

#[tokio::main(flavor = "multi_thread", worker_threads = 10)]
async fn main() -> anyhow::Result<()> {
    // CALL-SELECTED-FUNCTION-HERE
    let f = t122;
    primal_cache::main_1(f).await
}

async fn t122(config: Config, state: State) -> anyhow::Result<()> {{
    for i in 0..3 {
        println!("{i}");
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    }
    Ok(())
/*
0
1
2
*/
}}

