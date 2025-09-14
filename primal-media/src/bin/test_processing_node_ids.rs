use std::path::PathBuf;

use clap::Parser;
use env_logger::Env;
use log::{error, info, warn};
use primal_media::{config::Config, processing_graph::{self, NodeId}};
use serde_json::Value;

#[derive(Debug, Parser)]
#[command(name = "test_processing_node_ids")] 
#[command(about = "Validate NodeId hashing matches Julia")]
struct Cli {
    /// Path to config JSON
    #[arg(long = "config", value_name = "FILE", default_value = "./primal-media.config.json")]
    config: PathBuf,
    /// Max rows to check
    #[arg(long = "limit", default_value_t = 10_000)]
    limit: usize,
    /// Include all functions (not just media import)
    #[arg(long = "all", default_value_t = false)]
    all: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let cfg = Config::from_path(cli.config.to_str().unwrap())?;
    env_logger::Builder::from_env(Env::default().default_filter_or(cfg.log_level.as_deref().unwrap_or("info"))).init();

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(10)
        .connect(&cfg.database_url())
        .await?;

    let mut rows = sqlx::query!(
        "select id, mod, func, args, kwargs, args::text as args_text, kwargs::text as kwargs_text from processing_nodes order by created_at desc limit $1",
        cli.limit as i64
    )
    .fetch_all(&pool)
    .await?;
    if !cli.all {
        let allowed = ["import_media_pn","import_media_variant_pn","import_media_fast_pn","import_preview_pn"];
        rows.retain(|r| allowed.contains(&r.func.as_str()));
    }

    let mut mismatches = 0usize;
    for r in rows {
        let idb: Vec<u8> = r.id;
        let mod_name: Option<String> = r.r#mod;
        let func: String = r.func;
        let args: Option<Value> = r.args;
        let kwargs: Option<Value> = r.kwargs;
        let args_text: Option<String> = r.args_text;
        let kwargs_text: Option<String> = r.kwargs_text;
        if idb.len() != 32 { warn!("skipping row with non-32-byte id"); continue; }
        let mut id_arr = [0u8; 32]; id_arr.copy_from_slice(&idb);
        let nid = NodeId(id_arr);

        let m = mod_name.unwrap_or_default();
        let a = args.unwrap_or(Value::Null);
        let k = kwargs.unwrap_or(Value::Null);
        let calc_j = processing_graph::node_id_juliaish(&m, &func, &a, &k);
        let calc = processing_graph::node_id(&m, &func, &a, &k);
        let calc_main = processing_graph::node_id(&format!("Main.{}", m), &func, &a, &k);
        if calc_j.0 != nid.0 {
            let calc2 = processing_graph::node_id_canonical(&m, &func, &a, &k);
            // Textual recomposition attempt
            let at = args_text.unwrap_or("null".to_string());
            let kt = kwargs_text.unwrap_or("null".to_string());
            let mut orders = Vec::new();
            let keys = ["mod","func","args","kwargs"];
            fn permute(prefix: &mut Vec<&'static str>, rest: &mut Vec<&'static str>, out: &mut Vec<Vec<&'static str>>) {
                if rest.is_empty() { out.push(prefix.clone()); return; }
                for i in 0..rest.len() {
                    let v = rest.remove(i);
                    prefix.push(v);
                    permute(prefix, rest, out);
                    prefix.pop();
                    rest.insert(i, v);
                }
            }
            let mut rest = keys.to_vec();
            let mut prefix = Vec::new();
            permute(&mut prefix, &mut rest, &mut orders);
            let mut calc_textual = String::new();
            'outer: for ord in orders.iter() {
                let mut s = String::from("{");
                for (i,key) in ord.iter().enumerate() {
                    if i>0 { s.push(','); }
                    match *key {
                        "mod" => { s.push_str(&format!("\"mod\":\"{}\"", m)); },
                        "func" => { s.push_str(&format!("\"func\":\"{}\"", func)); },
                        "args" => { s.push_str(&format!("\"args\":{}", at)); },
                        "kwargs" => { s.push_str(&format!("\"kwargs\":{}", kt)); },
                        _ => {}
                    }
                }
                s.push('}');
                let h = {
                    use sha2::{Digest, Sha256};
                    let hh = Sha256::digest(s.as_bytes());
                    let mut out = [0u8; 32];
                    out.copy_from_slice(&hh);
                    out
                };
                if h == nid.0 {
                    calc_textual = hex::encode(h);
                    break 'outer;
                } else if calc_textual.is_empty() {
                    calc_textual = hex::encode(h);
                }
            }
            mismatches += 1;
            println!(
                "MISMATCH: id={} mod={} func={}\nargs={}\nkwargs={}\ncalc_j={}\ncalc={}\ncalc_main={}\ncalc_canonical={}\ncalc_textual={}\n",
                hex::encode(nid.0),
                m,
                func,
                a,
                k,
                hex::encode(calc_j.0),
                hex::encode(calc.0),
                hex::encode(calc_main.0),
                hex::encode(calc2.0),
                hex::encode(calc_textual)
            );
            // continue checking all
        }
    }

    if mismatches > 0 {
        error!("{} mismatches found", mismatches);
        std::process::exit(1);
    } else {
        info!("all node ids matched");
    }
    Ok(())
}
