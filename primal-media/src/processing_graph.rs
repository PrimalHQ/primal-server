use anyhow::Context;
use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::collections::{BTreeMap, HashMap};
use std::fmt;
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use std::cell::RefCell;
use tokio::task::JoinHandle;

use crate::AppState;

// Hex serde helpers for [u8; 32]
pub mod hex32 {
    use serde::{self, Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8; 32], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&hex::encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<[u8; 32], D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        let v = hex::decode(&s).map_err(serde::de::Error::custom)?;
        if v.len() != 32 {
            return Err(serde::de::Error::custom("expected 32 bytes"));
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&v);
        Ok(out)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NodeId(#[serde(with = "hex32")] pub [u8; 32]);

impl fmt::Debug for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "NodeId(\"{}\")", hex::encode(self.0))
    }
}

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", hex::encode(self.0))
    }
}

impl NodeId {
    pub fn from_hex(s: &str) -> anyhow::Result<Self> {
        let v = hex::decode(s)?;
        anyhow::ensure!(v.len() == 32, "expected 32 bytes, got {}", v.len());
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&v);
        Ok(NodeId(arr))
    }
}

// Serialization approach: Use serde_json::Map with insertion order for top-level
// and recursively, with option to canonicalize keys where necessary. We'll start
// with insertion order and add canonicalization path during validation if needed.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArgsKwargs {
    pub args: Value,
    pub kwargs: Value,
}

pub fn args_kwargs_serialize(args: &Value, kwargs: &Value) -> ArgsKwargs {
    ArgsKwargs { args: args.clone(), kwargs: kwargs.clone() }
}

pub fn node_id(mod_name: &str, func: &str, args: &Value, kwargs: &Value) -> NodeId {
    // Build object with keys in order: mod, func, args, kwargs
    let mut m = Map::new();
    m.insert("mod".to_string(), Value::String(mod_name.to_string()));
    m.insert("func".to_string(), Value::String(func.to_string()));
    m.insert("args".to_string(), args.clone());
    m.insert("kwargs".to_string(), kwargs.clone());
    let s = Value::Object(m).to_string();
    let h = Sha256::digest(s.as_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&h);
    NodeId(out)
}

fn canonicalize(v: &Value) -> Value {
    match v {
        Value::Object(map) => {
            let mut sorted = BTreeMap::new();
            for (k, vv) in map.iter() {
                sorted.insert(k.clone(), canonicalize(vv));
            }
            let mut m = Map::new();
            for (k, vv) in sorted.into_iter() {
                m.insert(k, vv);
            }
            Value::Object(m)
        }
        Value::Array(arr) => Value::Array(arr.iter().map(canonicalize).collect()),
        _ => v.clone(),
    }
}

pub fn node_id_canonical(mod_name: &str, func: &str, args: &Value, kwargs: &Value) -> NodeId {
    // Sort top-level keys and object keys recursively
    let mut top = BTreeMap::new();
    top.insert("mod".to_string(), Value::String(mod_name.to_string()));
    top.insert("func".to_string(), Value::String(func.to_string()));
    top.insert("args".to_string(), canonicalize(args));
    top.insert("kwargs".to_string(), canonicalize(kwargs));
    let mut m = Map::new();
    for (k, v) in top.into_iter() {
        m.insert(k, v);
    }
    let s = Value::Object(m).to_string();
    let h = Sha256::digest(s.as_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&h);
    NodeId(out)
}

// Julia-compatible JSON emitter (best effort):
// - Top-level object keys in order: mod, func, args, kwargs
// - Wrapper objects with keys: _ty first, then specific key like _v or _cache_sha256
// - For NamedTuple, sort _v object keys alphabetically (DB loses insertion order)
#[derive(Debug, Clone)]
pub enum AJ {
    Obj(Vec<(String, AJ)>),
    Arr(Vec<AJ>),
    Str(String),
    Num(serde_json::Number),
    Bool(bool),
    Null,
}

pub fn parse_arg(v: &Value) -> AJ {
    match v {
        Value::Null => AJ::Null,
        Value::Bool(b) => AJ::Bool(*b),
        Value::Number(n) => AJ::Num(n.clone()),
        Value::String(s) => AJ::Str(s.clone()),
        Value::Array(a) => AJ::Arr(a.iter().map(parse_arg).collect()),
        Value::Object(o) => {
            // detect wrappers
            if let Some(Value::String(ty)) = o.get("_ty") {
                match ty.as_str() {
                    "Vector{UInt8}" => {
                        let mut fields = Vec::new();
                        fields.push(("_ty".to_string(), AJ::Str(ty.clone())));
                        if let Some(vv) = o.get("_v") { fields.push(("_v".to_string(), parse_arg(vv))); }
                        if let Some(cs) = o.get("_cache_sha256") { fields.push(("_cache_sha256".to_string(), parse_arg(cs))); }
                        AJ::Obj(fields)
                    }
                    "Tuple" | "NamedTuple" | "Symbol" | "NodeId" | "PubKeyId" | "EventId" | "UUID" | "Function" | "Event" | "CacheStorage" => {
                        let mut fields = Vec::new();
                        fields.push(("_ty".to_string(), AJ::Str(ty.clone())));
                        if let Some(vv) = o.get("_v") {
                            // Special-case NamedTuple: ensure stable order for inner object by sorting keys
                            if ty == "NamedTuple" {
                                if let Value::Object(inner) = vv {
                                    let kvs: Vec<(String, AJ)> = inner.iter().map(|(k, v)| (k.clone(), parse_arg(v))).collect();
                                    fields.push(("_v".to_string(), AJ::Obj(kvs)));
                                } else {
                                    fields.push(("_v".to_string(), parse_arg(vv)));
                                }
                            } else {
                                fields.push(("_v".to_string(), parse_arg(vv)));
                            }
                        }
                        AJ::Obj(fields)
                    }
                    _ => {
                        // Unknown wrapper; preserve as-is but order _ty first
                        let mut kvs: Vec<(String, AJ)> = o.iter().map(|(k, v)| (k.clone(), parse_arg(v))).collect();
                        kvs.sort_by(|a, b| a.0.cmp(&b.0));
                        // Ensure _ty is first
                        kvs.sort_by_key(|(k, _)| if k == "_ty" { 0 } else { 1 });
                        AJ::Obj(kvs)
                    }
                }
            } else {
                // Plain object: sort keys alphabetically for stability
                let mut kvs: Vec<(String, AJ)> = o.iter().map(|(k, v)| (k.clone(), parse_arg(v))).collect();
                kvs.sort_by(|a, b| a.0.cmp(&b.0));
                AJ::Obj(kvs)
            }
        }
    }
}

pub fn write_json(buf: &mut String, v: &AJ) {
    match v {
        AJ::Null => buf.push_str("null"),
        AJ::Bool(b) => buf.push_str(if *b { "true" } else { "false" }),
        AJ::Num(n) => buf.push_str(&n.to_string()),
        AJ::Str(s) => buf.push_str(&serde_json::to_string(s).unwrap()),
        AJ::Arr(a) => {
            buf.push('[');
            for (i, el) in a.iter().enumerate() {
                if i > 0 { buf.push(','); }
                write_json(buf, el);
            }
            buf.push(']');
        }
        AJ::Obj(kvs) => {
            buf.push('{');
            for (i, (k, v)) in kvs.iter().enumerate() {
                if i > 0 { buf.push(','); }
                buf.push_str(&serde_json::to_string(k).unwrap());
                buf.push(':');
                write_json(buf, v);
            }
            buf.push('}');
        }
    }
}

fn kwargs_ordered_obj(kwargs: &Value) -> AJ {
    match kwargs {
        Value::Object(map) => {
            let kvs: Vec<(String, AJ)> = map.iter().map(|(k, v)| (k.clone(), parse_arg(v))).collect();
            AJ::Obj(kvs)
        }
        _ => parse_arg(kwargs),
    }
}

pub fn node_id_juliaish(mod_name: &str, func: &str, args: &Value, kwargs: &Value) -> NodeId {
    let mut top = Vec::new();
    top.push(("mod".to_string(), AJ::Str(mod_name.to_string())));
    top.push(("func".to_string(), AJ::Str(func.to_string())));
    top.push(("args".to_string(), parse_arg(args)));
    top.push(("kwargs".to_string(), kwargs_ordered_obj(kwargs)));
    let aj = AJ::Obj(top);
    let mut s = String::new();
    write_json(&mut s, &aj);
    let h = Sha256::digest(s.as_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&h);
    NodeId(out)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessingNodeRow {
    pub id: Vec<u8>,
    pub mod_: Option<String>,
    pub func: String,
    pub args: Option<Value>,
    pub kwargs: Option<Value>,
    pub extra: Option<Value>,
}

pub async fn update_node(
    pool: &PgPool,
    mod_name: &str,
    func: &str,
    args: &Value,
    kwargs: &Value,
    id: Option<&NodeId>,
    result: Option<&Value>,
    exception: bool,
    started_at: Option<time::OffsetDateTime>,
    finished_at: Option<time::OffsetDateTime>,
    extra: Option<&Value>,
    code_sha256: Option<&[u8; 32]>,
) -> anyhow::Result<NodeId> {
    let id = if let Some(id) = id.cloned() {
        id
    } else {
        node_id(mod_name, func, args, kwargs)
    };
    let result_json = result.cloned();
    let extra_json = extra.cloned();
    let code_bytes: Option<&[u8]> = code_sha256.map(|b| &b[..]);
    let started_at_pd: Option<time::PrimitiveDateTime> = started_at.map(|t| time::PrimitiveDateTime::new(t.date(), t.time()));
    let finished_at_pd: Option<time::PrimitiveDateTime> = finished_at.map(|t| time::PrimitiveDateTime::new(t.date(), t.time()));

    sqlx::query!(
        r#"
        insert into processing_nodes
        (id, created_at, updated_at, mod, func, args, kwargs, result, exception, started_at, finished_at, extra, code_sha256)
        values ($1, now(), now(), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        on conflict (id) do update set
            updated_at = now(),
            mod = excluded.mod,
            func = excluded.func,
            args = excluded.args,
            kwargs = excluded.kwargs,
            result = excluded.result,
            exception = excluded.exception,
            started_at = excluded.started_at,
            finished_at = excluded.finished_at,
            extra = excluded.extra,
            code_sha256 = excluded.code_sha256
        "#,
        &id.0[..],
        mod_name,
        func,
        args,
        kwargs,
        result_json,
        exception,
        started_at_pd,
        finished_at_pd,
        extra_json,
        code_bytes
    )
    .execute(pool)
    .await
    .with_context(|| "upserting processing_nodes")?;

    Ok(id)
}

pub async fn get_node(pool: &PgPool, id: &NodeId) -> anyhow::Result<Option<serde_json::Value>> {
    let row = sqlx::query!("select result from processing_nodes where id = $1 limit 1", &id.0[..])
        .fetch_optional(pool)
        .await?;
    Ok(row.and_then(|r| r.result))
}

// Registry for dynamic dispatch of procnode functions
pub type Handler = fn(AppState, NodeId, Value, Value) -> BoxFuture<'static, anyhow::Result<Value>>;
static REGISTRY: Lazy<RwLock<HashMap<(String, String), Handler>>> = Lazy::new(|| RwLock::new(HashMap::new()));

pub fn register(mod_name: &str, func: &str, handler: Handler) {
    let mut g = REGISTRY.write();
    g.insert((mod_name.to_string(), func.to_string()), handler);
}

fn get_handler(mod_name: &str, func: &str) -> Option<Handler> {
    REGISTRY.read().get(&(mod_name.to_string(), func.to_string())).copied()
}

// Task-local processing graph stack for ancestry edges
tokio::task_local! {
    static PG_STACK: RefCell<Vec<NodeId>>;
}

pub fn current_parent() -> Option<NodeId> {
    PG_STACK.try_with(|rc| rc.borrow().last().cloned()).ok().flatten()
}

pub async fn subnode(pool: &PgPool, parent: &NodeId, child: &NodeId, extra: Option<&Value>) -> anyhow::Result<()> {
    sqlx::query!(
        r#"
        insert into processing_edges (type, id1, id2, created_at, updated_at, extra)
        values ('ancestry', $1, $2, now(), now(), $3)
        on conflict (type, id1, id2) do update set updated_at = excluded.updated_at, extra = excluded.extra
        "#,
        &parent.0[..],
        &child.0[..],
        extra.cloned()
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn execute_node_by_id(
    state: &AppState,
    id: &Vec<u8>,
) -> anyhow::Result<serde_json::Value> {
    let rows = sqlx::query!(
        r#"select id, mod, func, args, kwargs, created_at from processing_nodes where id = $1"#,
        id,
    )
    .fetch_optional(&state.pool)
    .await?;

    if let Some(row) = rows {
        let mut id = [0u8; 32];
        id.copy_from_slice(&row.id);
        let nid = NodeId(id);
        let mod_name = row.r#mod.unwrap_or_default();
        let func = row.func.as_str();
        let args = row.args.unwrap_or(Value::Null);
        let kwargs = row.kwargs.unwrap_or(Value::Null);

        let started = time::OffsetDateTime::now_utc();
        let _ = update_node(&state.pool, &mod_name, func, &args, &kwargs, Some(&nid), None, false, Some(started), None, None, None).await?;

        let state_clone = state.clone();
        let func_clone = func.to_string();

        execute_node(&state_clone, &nid, &mod_name, &func_clone, &args, &kwargs).await
    } else {
        Err(anyhow::anyhow!("node id not found"))
    }
}

pub async fn execute_delayed_node(
    state: &AppState,
    func: &str,
) -> Option<JoinHandle<anyhow::Result<Vec<(NodeId, anyhow::Result<serde_json::Value>)>>>> {
    let rows = sqlx::query!(
        r#"select id, mod, args, kwargs, created_at from processing_nodes where func = $1 and started_at is null and finished_at is null order by created_at limit 1"#,
        func
    )
    .fetch_optional(&state.pool)
    .await.ok()?;

    if let Some(row) = rows {
        log::info!("{} processing lag: {}", func, time::OffsetDateTime::now_utc() - row.created_at.assume_utc());

        let mut id = [0u8; 32];
        id.copy_from_slice(&row.id);
        let nid = NodeId(id);
        let mod_name = row.r#mod.unwrap_or_default();
        let args = row.args.unwrap_or(Value::Null);
        let kwargs = row.kwargs.unwrap_or(Value::Null);

        let started = time::OffsetDateTime::now_utc();
        let _ = update_node(&state.pool, &mod_name, func, &args, &kwargs, Some(&nid), None, false, Some(started), None, None, None).await.ok()?;

        let state_clone = state.clone();
        let func_clone = func.to_string();
        return Some(tokio::spawn(async move {
            let result = match execute_node(&state_clone, &nid, &mod_name, &func_clone, &args, &kwargs).await {
                Ok(v) => (nid, Ok(v)),
                Err(e) => (nid, Err(e)),
            };
            Ok(vec![result])
        }));
    }

    None
}

pub async fn execute_node(
    state: &AppState,
    id: &NodeId,
    mod_name: &str,
    func: &str,
    args: &Value,
    kwargs: &Value,
) -> anyhow::Result<Value> {
    // dbg!((mod_name, func, id, args, kwargs));

    let started = time::OffsetDateTime::now_utc();
    let _ = update_node(&state.pool, mod_name, func, args, kwargs, Some(id), None, false, Some(started), None, None, None).await?;

    // Dynamic dispatch using registry; push this node on the task-local stack for child edges
    let fut = async {
        if let Some(handler) = get_handler(mod_name, func) {
            match handler(state.clone(), *id, args.clone(), kwargs.clone()).await {
                Ok(v) => {
                    let extra = sqlx::query!("select extra from processing_nodes where id = $1", &id.0[..])
                        .fetch_optional(&state.pool)
                        .await
                        .ok()
                        .and_then(|row| row.and_then(|r| r.extra));
                    let _ = update_node(&state.pool, mod_name, func, args, kwargs, Some(id), Some(&v), false, Some(started), Some(time::OffsetDateTime::now_utc()), extra.as_ref(), None).await?;
                    // Cleanup cached binaries in args/kwargs
                    cleanup_binary_cache_arguments(args).await;
                    cleanup_binary_cache_arguments(kwargs).await;
                    Ok(v)
                }
                Err(e) => {
                    // Extract backtrace from the anyhow::Error where it originally occurred
                    let bt = format!("{:?}", e.backtrace());
                    let result = json!({ "error": e.to_string(), "backtrace": bt });
                    let extra = sqlx::query!("select extra from processing_nodes where id = $1", &id.0[..])
                        .fetch_optional(&state.pool)
                        .await
                        .ok()
                        .and_then(|row| row.and_then(|r| r.extra));
                    let _ = update_node(&state.pool, mod_name, func, args, kwargs, Some(id), Some(&result), true, Some(started), Some(time::OffsetDateTime::now_utc()), extra.as_ref(), None).await?;
                    cleanup_binary_cache_arguments(args).await;
                    cleanup_binary_cache_arguments(kwargs).await;
                    Err(e)
                }
            }
        } else {
            let err_msg = format!("no handler for {}.{}", mod_name, func);
            let err = anyhow::anyhow!(err_msg);
            let bt = format!("{:?}", err.backtrace());
            let result = json!({ "error": err.to_string(), "backtrace": bt });
            let _ = update_node(&state.pool, mod_name, func, args, kwargs, Some(id), Some(&result), true, Some(started), Some(time::OffsetDateTime::now_utc()), None, None).await?;
            cleanup_binary_cache_arguments(args).await;
            cleanup_binary_cache_arguments(kwargs).await;
            Err(err)
        }
    };

    // Push onto stack if present; else create a scope with a fresh stack
    if PG_STACK.try_with(|rc| { rc.borrow_mut().push(*id); }).is_ok() {
        let r = fut.await;
        let _ = PG_STACK.try_with(|rc| { rc.borrow_mut().pop(); });
        r
    } else {
        PG_STACK.scope(RefCell::new(vec![*id]), fut).await
    }
}

// Binary cache similar to Julia for Vector{UInt8}
pub static BINARY_DATA_CACHE_DIR: Lazy<RwLock<String>> = Lazy::new(|| RwLock::new("./cache/procgraph".to_string()));

pub async fn read_vector_u8(v: &Value) -> Option<Vec<u8>> {
    if let Value::Object(o) = v {
        if let Some(Value::String(ty)) = o.get("_ty") {
            if ty == "Vector{UInt8}" {
                if let Some(Value::String(hexs)) = o.get("_v") {
                    return hex::decode(hexs).ok();
                }
                if let Some(Value::String(hh)) = o.get("_cache_sha256") {
                    let dir = BINARY_DATA_CACHE_DIR.read().clone();
                    if hh.len() >= 4 {
                        let path = format!("{}/{}/{}/{}", dir, &hh[0..2], &hh[2..4], hh);
                        return tokio::fs::read(path).await.ok();
                    }
                }
            }
        }
    }
    None
}

pub async fn write_vector_u8_to_cache(bytes: &[u8]) -> anyhow::Result<String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let hash = hasher.finalize();
    let hash_hex = hex::encode(hash);

    let dir = BINARY_DATA_CACHE_DIR.read().clone();
    let subdir1 = &hash_hex[0..2];
    let subdir2 = &hash_hex[2..4];
    let cache_dir = format!("{}/{}/{}", dir, subdir1, subdir2);
    tokio::fs::create_dir_all(&cache_dir).await?;

    let file_path = format!("{}/{}", cache_dir, hash_hex);
    tokio::fs::write(&file_path, bytes).await?;

    Ok(hash_hex)
}

// Extra logging helpers, mirroring Julia's E()/extralog()
pub async fn extra_merge(state: &AppState, id: &NodeId, kv: serde_json::Map<String, Value>) -> anyhow::Result<()> {
    let row = sqlx::query!("select extra from processing_nodes where id = $1", &id.0[..])
        .fetch_optional(&state.pool)
        .await?;
    let mut extra = row.and_then(|r| r.extra).unwrap_or(json!({}));
    if !extra.is_object() { extra = json!({}); }
    let obj = extra.as_object_mut().unwrap();
    for (k, v) in kv.into_iter() { obj.insert(k, v); }
    sqlx::query!("update processing_nodes set extra = $2 where id = $1", &id.0[..], extra)
        .execute(&state.pool)
        .await?;
    Ok(())
}

pub async fn extralog(state: &AppState, id: &NodeId, v: Value) -> anyhow::Result<()> {
    let row = sqlx::query!("select extra from processing_nodes where id = $1", &id.0[..])
        .fetch_optional(&state.pool)
        .await?;
    let mut extra = row.and_then(|r| r.extra).unwrap_or(json!({}));
    if !extra.is_object() { extra = json!({}); }
    let obj = extra.as_object_mut().unwrap();
    let arr = obj.entry("log").or_insert(json!([]));
    if !arr.is_array() { *arr = json!([]); }
    // Wrap in NamedTuple structure to match Julia @procnode macro behavior
    let wrapped = json!({"_ty": "NamedTuple", "_v": v});
    arr.as_array_mut().unwrap().push(wrapped);
    sqlx::query!("update processing_nodes set extra = $2 where id = $1", &id.0[..], extra)
        .execute(&state.pool)
        .await?;
    Ok(())
}

pub fn cleanup_binary_cache_arguments(v: &Value) -> BoxFuture<'_, ()> {
    Box::pin(async move {
        match v {
            Value::Object(o) => {
                if let Some(Value::String(ty)) = o.get("_ty") {
                    if ty == "Vector{UInt8}" {
                        if let Some(Value::String(hh)) = o.get("_cache_sha256") {
                            if hh.len() >= 4 {
                                let dir = BINARY_DATA_CACHE_DIR.read().clone();
                                let path = format!("{}/{}/{}/{}", dir, &hh[0..2], &hh[2..4], hh);
                                let _ = tokio::fs::remove_file(path).await;
                            }
                        }
                    }
                    if ty == "Tuple" {
                        if let Some(Value::Array(arr)) = o.get("_v") {
                            for vv in arr {
                                cleanup_binary_cache_arguments(vv).await;
                            }
                        }
                    }
                    return;
                }
                for (_, vv) in o.iter() {
                    cleanup_binary_cache_arguments(vv).await;
                }
            }
            Value::Array(arr) => {
                for vv in arr {
                    cleanup_binary_cache_arguments(vv).await;
                }
            }
            _ => {}
        }
    })
}

// ---- Macro-equivalent helpers ----

pub static CACHING_ENABLED: Lazy<RwLock<bool>> = Lazy::new(|| RwLock::new(false));

pub async fn pn_immediate(state: &AppState, mod_name: &str, func: &str, args: &Value, kwargs: &Value) -> anyhow::Result<(NodeId, Value)> {
    let id = node_id(mod_name, func, args, kwargs);
    // Link to parent if any
    if let Some(parent) = current_parent() {
        let _ = subnode(&state.pool, &parent, &id, None).await;
    }
    // Caching check: finished and not exception
    if *CACHING_ENABLED.read() {
        if let Some(row) = sqlx::query!("select result, coalesce(exception,false) as \"exception!\", finished_at from processing_nodes where id = $1 limit 1", &id.0[..])
            .fetch_optional(&state.pool)
            .await? {
            if row.finished_at.is_some() && !row.exception {
                if let Some(res) = row.result { return Ok((id, res)); }
            }
        }
    }
    let v = execute_node(state, &id, mod_name, func, args, kwargs).await?;
    Ok((id, v))
}

pub async fn pnd_delayed(state: &AppState, mod_name: &str, func: &str, args: &Value, kwargs: &Value) -> anyhow::Result<NodeId> {
    let id = node_id(mod_name, func, args, kwargs);
    // Upsert node without starting
    let _ = update_node(&state.pool, mod_name, func, args, kwargs, Some(&id), None, false, None, None, None, None).await?;
    if let Some(parent) = current_parent() {
        let _ = subnode(&state.pool, &parent, &id, None).await;
    }
    Ok(id)
}

pub async fn pnl_log(state: &AppState, v: Value) -> anyhow::Result<()> {
    if let Some(parent) = current_parent() {
        extralog(state, &parent, v).await?;
    }
    Ok(())
}

// ---- Argument helpers for building Julia-like wrappers ----

pub fn tuple_from(values: Vec<Value>) -> Value { json!({"_ty":"Tuple","_v": values}) }
pub fn namedtuple_from_pairs(pairs: Vec<(String, Value)>) -> Value {
    let mut m = serde_json::Map::new();
    for (k, v) in pairs { m.insert(k, v); }
    json!({"_ty":"NamedTuple","_v": Value::Object(m)})
}
pub fn symbol(s: &str) -> Value { json!({"_ty":"Symbol","_v": s}) }
pub fn vec_u8_from_hex(hexs: &str) -> Value { json!({"_ty":"Vector{UInt8}", "_v": hexs}) }
pub async fn vec_u8_from_bytes(bytes: &[u8]) -> anyhow::Result<Value> {
    let hash_hex = write_vector_u8_to_cache(bytes).await?;
    Ok(json!({"_ty":"Vector{UInt8}", "_cache_sha256": hash_hex}))
}
