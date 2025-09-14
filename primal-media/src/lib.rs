pub mod config;
pub mod nostr;
pub mod processing_graph;
pub mod processing_graph_execution_scheduler;
pub mod media;
pub mod cache_storage_media;
pub mod pn_wrappers;
pub mod hls_providers;
pub mod media_analysis;

use config::Config;
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;
use parking_lot::Mutex;
use tokio::task::JoinHandle;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Config,
    pub tasks: Arc<Mutex<HashMap<String, Vec<JoinHandle<anyhow::Result<Vec<(processing_graph::NodeId, anyhow::Result<serde_json::Value>)>>>>>>>, // track running task handles by task name
    pub media_env: media::MediaEnv,
}

pub fn register_builtin_nodes() {
    use processing_graph as pg;

    // Nodes using #[procnode] macro - registration generated automatically
    media::register_media_variants_pn();
    media::register_media_variant_fast_pn();
    cache_storage_media::register_import_media_fast_pn();
    cache_storage_media::register_import_preview_pn();

    // Nodes with complex Julia-style parameter parsing - inline registration until refactored
    pg::register("PrimalServer.Media", "transcode_video_pn",
        |state, id, args, kwargs| Box::pin(async move { media::handler_transcode_video_pn(&state, &id, args, kwargs).await }));
    pg::register("PrimalServer.Media", "media_video_variants_pn",
        |state, id, args, kwargs| Box::pin(async move { media::handler_media_video_variants_pn(&state, &id, args, kwargs).await }));

    pg::register("PrimalServer.DB", "import_media_pn",
        |state, id, args, kwargs| Box::pin(async move { cache_storage_media::handler_import_media_pn(&state, &id, args, kwargs).await }));
    pg::register("PrimalServer.DB", "import_media_variant_pn",
        |state, _id, args, kwargs| Box::pin(async move { cache_storage_media::handler_import_media_variant_pn(&state, args, kwargs).await }));

    // Alias for import_media_fast_pn
    pg::register("PrimalServer.DB", "import_media_fast_pn_2",
        |state, _id, args, _kwargs| Box::pin(async move { cache_storage_media::handler_import_media_fast_pn(&state, &_id, args, _kwargs).await }));

    pg::register("PrimalServer.DB", "import_media_video_variants_pn",
        |state, _id, args, kwargs| Box::pin(async move { cache_storage_media::handler_import_media_video_variants_pn(&state, args, kwargs).await }));
    pg::register("PrimalServer.DB", "import_media_hls_pn",
        |state, id, args, kwargs| Box::pin(async move { cache_storage_media::handler_import_media_hls_pn(&state, &id, args, kwargs).await }));

    // Handler using #[procnode] macro
    media_analysis::register_import_text_event_pn();
}

// A convenience macro to call procnodes with Julia-like tuple/kwargs wrappers
#[macro_export]
macro_rules! procnode_call {
    // With kwargs as pairs of (string key => value)
    ($state:expr, $mod:expr, $func:expr, [ $( $arg:expr ),* ], { $( $k:expr => $v:expr ),* $(,)? }) => {{
        let mut args_vec = Vec::<serde_json::Value>::new();
        $( args_vec.push(serde_json::json!($arg)); )*
        let args_val = $crate::processing_graph::tuple_from(args_vec);
        let mut kvs = Vec::<(String, serde_json::Value)>::new();
        $( kvs.push(($k.to_string(), serde_json::json!($v))); )*
        let kwargs_val = $crate::processing_graph::namedtuple_from_pairs(kvs);
        $crate::processing_graph::pn_immediate($state, $mod, $func, &args_val, &kwargs_val).await
    }};
    // No kwargs
    ($state:expr, $mod:expr, $func:expr, [ $( $arg:expr ),* ]) => {{
        let mut args_vec = Vec::<serde_json::Value>::new();
        $( args_vec.push(serde_json::json!($arg)); )*
        let args_val = $crate::processing_graph::tuple_from(args_vec);
        let kwargs_val = serde_json::json!({});
        $crate::processing_graph::pn_immediate($state, $mod, $func, &args_val, &kwargs_val).await
    }};
}
