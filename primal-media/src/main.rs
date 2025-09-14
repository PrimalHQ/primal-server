use std::path::PathBuf;
use std::sync::Arc;
use std::collections::HashMap;

use anyhow::{Context, anyhow};
use clap::{Parser, Subcommand};
use chrono::{DateTime, Utc};
use env_logger::Env;
use log::{error, info};
use parking_lot::Mutex;
use primal_media::{config::Config, processing_graph_execution_scheduler, processing_graph, AppState};
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use tokio::signal::unix::{signal, SignalKind};
use tokio::runtime::Handle;
use tokio::time::{timeout, Duration};

#[derive(Debug, Parser)]
#[command(name = "primal-media")]
#[command(about = "Media processing scheduler (Rust)")]
struct Cli {
    /// Path to config JSON
    #[arg(long = "config", value_name = "FILE", default_value = "./primal-media.config.json", env = "PRIMAL_MEDIA_CONFIG_FILE")]
    config: PathBuf,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Execute a specific processing node by its ID
    ExecuteNode {
        /// Hex-encoded node ID
        #[arg(long = "id", value_name = "HEX_NODE_ID")]
        id: String,
    },
    /// Import media HLS transcoding - convert video URL to HLS using configured providers
    ImportMediaHls {
        /// Event ID in hex format
        #[arg(long = "event-id", value_name = "HEX_EVENT_ID")]
        event_id: String,
        /// Video URL to transcode
        #[arg(long = "url", value_name = "URL")]
        url: String,
        /// Cached Video URL to transcode
        #[arg(long = "media_url", value_name = "MEDIA_URL")]
        media_url: Option<String>,
    },
    /// Delete all HLS resources for a specific event
    DeleteEventHlsResources {
        /// Event ID in hex format
        #[arg(long = "event-id", value_name = "HEX_EVENT_ID")]
        event_id: Option<String>,
        /// Delete HLS resources for events created since this datetime (e.g., "2025-02-03 11:11", "yesterday", "3 days ago")
        #[arg(long = "since", value_name = "DATETIME")]
        since: Option<String>,
    },
    /// Import and analyze a text event (embeddings and metadata)
    ImportTextEvent {
        /// Event ID in hex format
        #[arg(long = "event-as", value_name = "EVENT_ID_HEX")]
        event_as: String,
    },
    /// Import media processing node with media analysis
    ImportMedia {
        /// Event ID in hex format (optional)
        #[arg(long = "event-id", value_name = "EVENT_ID_HEX")]
        event_id: Option<String>,
        /// Media URL to import
        #[arg(long = "url", value_name = "URL")]
        url: String,
        /// Skip media analysis step
        #[arg(long = "no-media-analysis")]
        no_media_analysis: bool,
    },
    /// Import preview from URL for a specific event
    ImportPreview {
        /// Event ID in hex format
        #[arg(long = "event-id", value_name = "HEX_EVENT_ID")]
        event_id: String,
        /// URL to import preview from
        #[arg(long = "url", value_name = "URL")]
        url: String,
    },
    /// Print tree of processing nodes connected through processing edges
    ProcessingNodeTree {
        /// Node ID in hex format
        #[arg(long = "node-id", value_name = "NODE-ID-HEX")]
        node_id: String,
        #[arg(long = "no-pretty-print", value_name = "NO_PRETTY_PRINT", default_value = "false")]
        no_pretty_print: bool,
    },
    /// Delete tree of processing nodes and their edges
    DeleteProcessingNodeTree {
        /// Node ID in hex format
        #[arg(long = "node-id", value_name = "NODE-ID-HEX")]
        node_id: String,
        /// Dry run - only show what would be deleted
        #[arg(long = "dry-run")]
        dry_run: bool,
    },
    /// Run the processing graph execution scheduler loop
    RunProcessingGraphScheduler,
}

/// Parse a datetime string in various formats using the dateparser crate.
/// Supports formats like:
/// - "2025-02-03 11:11" - explicit datetime
/// - "2025-02-03" - date only
/// - "yesterday" - yesterday
/// - "3 days ago" - 3 days ago from now
/// - "1 hour ago", "2 hours ago" - hours ago
/// - and many more natural language formats
fn parse_datetime(input: &str) -> anyhow::Result<DateTime<Utc>> {
    dateparser::parse(input)
        .with_context(|| format!("Unable to parse datetime: '{}'. Try formats like '2025-02-03 11:11', 'yesterday', or '3 days ago'", input))
}

async fn runtime_dump(filename: &str) {
    let handle = Handle::current();
    let mut s = String::new();
    if let Ok(dump) = timeout(Duration::from_secs(100), handle.dump()).await {
        for task in dump.tasks().iter() {
            let trace = task.trace();
            let tokio_task_id = format!("{}", task.id());
            s.push_str(format!("TASK {tokio_task_id}:\n").as_str());
            s.push_str(format!("{trace}\n\n").as_str());
        }
    } else {
        s.push_str("Timeout waiting for runtime dump\n");
    }
    // Output to stderr
    // eprintln!("{}", s);
    // Write to file
    if let Err(e) = tokio::fs::write(filename, &s).await {
        eprintln!("Failed to write runtime dump to {}: {}", filename, e);
    } else {
        eprintln!("Runtime dump written to {}", filename);
    }
}

fn collect_tree_nodes_recursive<'a>(
    pool: &'a sqlx::PgPool,
    node_id: &'a [u8],
    visited: &'a mut std::collections::HashSet<Vec<u8>>,
    nodes: &'a mut Vec<Vec<u8>>,
    edges: &'a mut Vec<(String, Vec<u8>, Vec<u8>)>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + 'a>> {
    Box::pin(async move {
        // Skip if already visited (handles cycles)
        if visited.contains(node_id) {
            return Ok(());
        }
        visited.insert(node_id.to_vec());
        nodes.push(node_id.to_vec());

        // Query for child nodes and edges, ordered by child node's created_at
        let child_rows = sqlx::query!(
            r#"
            SELECT pe.type, pe.id1, pe.id2 FROM processing_edges pe
            JOIN processing_nodes pn ON pe.id2 = pn.id
            WHERE pe.type = 'ancestry' AND pe.id1 = $1
            ORDER BY pn.created_at ASC
            "#,
            node_id
        )
        .fetch_all(pool)
        .await?;

        for child_row in child_rows {
            edges.push((child_row.r#type, child_row.id1.to_vec(), child_row.id2.to_vec()));
            collect_tree_nodes_recursive(pool, &child_row.id2, visited, nodes, edges).await?;
        }

        Ok(())
    })
}

async fn collect_tree_nodes(
    pool: &sqlx::PgPool,
    node_id_hex: &str,
) -> anyhow::Result<(Vec<Vec<u8>>, Vec<(String, Vec<u8>, Vec<u8>)>)> {
    // Decode initial node ID
    let node_id_bytes = hex::decode(node_id_hex)
        .with_context(|| format!("failed to decode hex node ID: {}", node_id_hex))?;

    // Check that the root node exists
    let row = sqlx::query!(
        "SELECT id FROM processing_nodes WHERE id = $1 LIMIT 1",
        &node_id_bytes[..]
    )
    .fetch_optional(pool)
    .await?;

    if row.is_none() {
        return Err(anyhow::anyhow!(
            "Node with ID {} not found",
            node_id_hex
        ));
    }

    // Recursively collect all node IDs and edges in the tree
    let mut collected_nodes = Vec::new();
    let mut collected_edges = Vec::new();
    let mut visited = std::collections::HashSet::new();

    collect_tree_nodes_recursive(pool, &node_id_bytes, &mut visited, &mut collected_nodes, &mut collected_edges).await?;

    Ok((collected_nodes, collected_edges))
}

async fn delete_processing_node_tree(
    pool: &sqlx::PgPool,
    node_id_hex: &str,
    dry_run: bool,
) -> anyhow::Result<serde_json::Value> {
    use serde_json::json;

    // Collect all nodes and edges in the tree
    let (node_ids, edges) = collect_tree_nodes(pool, node_id_hex).await?;

    info!("Found {} nodes and {} edges in tree", node_ids.len(), edges.len());

    if dry_run {
        // Just report what would be deleted
        let node_ids_hex: Vec<String> = node_ids.iter().map(|id| hex::encode(id)).collect();
        return Ok(json!({
            "dry_run": true,
            "nodes_to_delete": node_ids_hex.len(),
            "edges_to_delete": edges.len(),
            "nodes": node_ids_hex,
            "edges": edges.iter().map(|(edge_type, id1, id2)| {
                json!([
                    edge_type,
                    hex::encode(id1),
                    hex::encode(id2),
                ])
            }).collect::<Vec<serde_json::Value>>(),
        }));
    }

    // Delete processing edges that connect nodes in this tree
    let mut edges_deleted = 0;
    for (edge_type, id1, id2) in edges {
        let result = sqlx::query!(
            "DELETE FROM processing_edges WHERE type = $1 AND id1 = $2 AND id2 = $3",
            &edge_type,
            &id1[..],
            &id2[..]
        )
        .execute(pool)
        .await?;
        edges_deleted += result.rows_affected();
    }

    info!("Deleted {} edges", edges_deleted);

    // Delete all processing nodes in the tree
    let mut nodes_deleted = 0;
    for node_id in &node_ids {
        let result = sqlx::query!(
            "DELETE FROM processing_nodes WHERE id = $1",
            &node_id[..]
        )
        .execute(pool)
        .await?;
        nodes_deleted += result.rows_affected();
    }

    info!("Deleted {} nodes", nodes_deleted);

    Ok(json!({
        "dry_run": false,
        "nodes_deleted": nodes_deleted,
        "edges_deleted": edges_deleted,
        "total_nodes_in_tree": node_ids.len()
    }))
}

fn print_node_recursive_impl<'a>(
    pool: &'a sqlx::PgPool,
    node_id: &'a [u8],
    indent: usize,
    no_pretty_print: bool,
    visited: &'a mut std::collections::HashSet<Vec<u8>>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + 'a>> {
    Box::pin(async move {
        // Skip if already visited (handles cycles)
        if visited.contains(node_id) {
            let node_id_display = hex::encode(node_id);
            let indent_str = "  ".repeat(indent);
            println!("{}├─ [CIRCULAR REFERENCE: {}]", indent_str, node_id_display);
            return Ok(());
        }
        visited.insert(node_id.to_vec());

        // Query node details
        let row = sqlx::query!(
            r#"SELECT id, mod, func, args, kwargs, result, exception, started_at, finished_at, extra, progress, created_at, updated_at
               FROM processing_nodes WHERE id = $1 LIMIT 1"#,
            node_id
        )
        .fetch_optional(pool)
        .await?;

        if let Some(row) = row {
            let mod_name = row.r#mod.unwrap_or_else(|| "Unknown".to_string());
            let func = row.func;
            let indent_str = "  ".repeat(indent);

            // Status indicator
            let status = if row.exception {
                "❌ EXCEPTION"
            } else if row.finished_at.is_some() {
                "✓ DONE"
            } else if row.started_at.is_some() {
                "⏳ RUNNING"
            } else {
                "○ PENDING"
            };

            println!("{}├─ {}::{} [{}]", indent_str, mod_name, func, status);

            // Show node ID
            let node_id_display = hex::encode(node_id);
            println!("{}│  ID: {}", indent_str, node_id_display);

            // Show created_at and updated_at
            println!("{}│  Created: {}", indent_str, row.created_at);
            println!("{}│  Updated: {}", indent_str, row.updated_at);

            // Show args if present (full, no truncation)
            if let Some(args) = &row.args {
                let args_str = if no_pretty_print { serde_json::to_string(args) } else { serde_json::to_string_pretty(args) }.unwrap_or_else(|_| "???".to_string());
                for (i, line) in args_str.lines().enumerate() {
                    if i == 0 {
                        println!("{}│  Args:", indent_str);
                    }
                    println!("{}│    {}", indent_str, line);
                }
            }

            // Show kwargs if present (full, no truncation)
            if let Some(kwargs) = &row.kwargs {
                let kwargs_str = if no_pretty_print { serde_json::to_string(kwargs) } else { serde_json::to_string_pretty(kwargs) }.unwrap_or_else(|_| "???".to_string());
                for (i, line) in kwargs_str.lines().enumerate() {
                    if i == 0 {
                        println!("{}│  Kwargs:", indent_str);
                    }
                    println!("{}│    {}", indent_str, line);
                }
            }

            // Show result if present (full, no truncation)
            if let Some(result) = &row.result {
                let result_str = if no_pretty_print { serde_json::to_string(result) } else { serde_json::to_string_pretty(result) }.unwrap_or_else(|_| "???".to_string());
                for (i, line) in result_str.lines().enumerate() {
                    if i == 0 {
                        println!("{}│  Result:", indent_str);
                    }
                    println!("{}│    {}", indent_str, line);
                }
            }

            // Show extra column if present (full, no truncation)
            if let Some(extra) = &row.extra {
                let extra_str = if no_pretty_print { serde_json::to_string(extra) } else { serde_json::to_string_pretty(extra) }.unwrap_or_else(|_| "???".to_string());
                for (i, line) in extra_str.lines().enumerate() {
                    if i == 0 {
                        println!("{}│  Extra:", indent_str);
                    }
                    println!("{}│    {}", indent_str, line);
                }
            }

            // Show progress if present
            if let Some(progress) = row.progress {
                println!("{}│  Progress: {:.2}%", indent_str, progress * 100.0);
            }

            // Show timing info
            if let (Some(started), Some(finished)) = (row.started_at, row.finished_at) {
                let duration = finished - started;
                println!("{}│  Duration: {:.2}s", indent_str, duration.whole_milliseconds() as f64 / 1000.0);
            } else if let Some(started) = row.started_at {
                println!("{}│  Started at: {}", indent_str, started);
            } else if let Some(finished) = row.finished_at {
                println!("{}│  Finished at: {}", indent_str, finished);
            }

            println!("{}│", indent_str);

            // Query for child nodes, ordered by child node's created_at
            let child_rows = sqlx::query!(
                r#"
                SELECT pn.id FROM processing_edges pe
                JOIN processing_nodes pn ON pe.id2 = pn.id
                WHERE pe.type = 'ancestry' AND pe.id1 = $1
                ORDER BY pn.created_at ASC
                "#,
                node_id
            )
            .fetch_all(pool)
            .await?;

            // Recursively process each child
            for child_row in child_rows {
                print_node_recursive_impl(pool, &child_row.id, indent + 1, no_pretty_print, visited).await?;
            }
        }

        Ok(())
    })
}

fn print_node_recursive<'a>(
    pool: &'a sqlx::PgPool,
    node_id: &'a [u8],
    indent: usize,
    no_pretty_print: bool,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + 'a>> {
    Box::pin(async move {
        let mut visited = std::collections::HashSet::new();
        print_node_recursive_impl(pool, node_id, indent, no_pretty_print, &mut visited).await
    })
}

async fn build_processing_node_tree(
    pool: &sqlx::PgPool,
    node_id_hex: &str,
    no_pretty_print: bool,
) -> anyhow::Result<()> {
    // Decode initial node ID
    let node_id_bytes = hex::decode(node_id_hex)
        .with_context(|| format!("failed to decode hex node ID: {}", node_id_hex))?;

    // Check that the root node exists
    let row = sqlx::query!(
        r#"SELECT id FROM processing_nodes WHERE id = $1 LIMIT 1"#,
        &node_id_bytes[..]
    )
    .fetch_optional(pool)
    .await?;

    if row.is_none() {
        return Err(anyhow::anyhow!(
            "Node with ID {} not found",
            node_id_hex
        ));
    }

    // Start recursive tree printing from root node
    print_node_recursive(pool, &node_id_bytes, 0, no_pretty_print).await?;

    Ok(())
}

async fn delete_event_hls_resources(
    state: &Arc<AppState>,
    event_id_hex: &str,
) -> anyhow::Result<serde_json::Value> {
    use serde_json::json;

    // Decode event ID
    let event_id_bytes = hex::decode(event_id_hex)
        .with_context(|| format!("failed to decode event ID: {}", event_id_hex))?;

    // Query database for all HLS resources for this event
    let rows = sqlx::query!(
        "SELECT provider, url, hls_url, extra FROM event_hls_media WHERE event_id = $1",
        &event_id_bytes[..]
    )
    .fetch_all(&state.pool)
    .await?;

    if rows.is_empty() {
        info!("No HLS resources found for event {}", event_id_hex);
        return Ok(json!({
            "event_id": event_id_hex,
            "resources_found": 0,
            "deleted": [],
            "errors": []
        }));
    }

    info!("Found {} HLS resources for event {}", rows.len(), event_id_hex);

    // Create HTTP client for provider API calls
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let mut deleted = Vec::new();
    let mut errors = Vec::new();

    // Process each resource
    for row in rows {
        let provider_name = row.provider;
        let url = row.url;
        let hls_url = row.hls_url;

        // Extract provider_asset_id from extra jsonb field
        let asset_id = if let Some(extra) = row.extra {
            extra.get("provider_asset_id")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        } else {
            None
        };

        if asset_id.is_none() {
            let error_msg = format!("No provider_asset_id found in extra field");
            log::warn!("provider={}, url={}: {}", provider_name, url, error_msg);
            errors.push(json!({
                "provider": provider_name,
                "url": url,
                "error": error_msg
            }));
            continue;
        }

        let asset_id = asset_id.unwrap();

        info!("Deleting {} asset {} (url: {})", provider_name, asset_id, url);

        // Find matching provider config
        let provider_config = state.config.media.hls_providers.iter()
            .find(|p| p.provider_type == provider_name);

        if provider_config.is_none() {
            let error_msg = format!("Provider '{}' not found in configuration", provider_name);
            log::warn!("{}", error_msg);
            errors.push(json!({
                "provider": provider_name,
                "url": url,
                "asset_id": asset_id,
                "error": error_msg
            }));
            continue;
        }

        let provider_config = provider_config.unwrap();

        // Create provider instance
        match primal_media::hls_providers::create_provider(provider_config, http_client.clone()).await {
            Ok(provider) => {
                // Delete the asset
                match provider.delete_asset(&asset_id).await {
                    Ok(_) => {
                        info!("Successfully deleted {} asset {}", provider_name, asset_id);
                        deleted.push(json!({
                            "provider": provider_name,
                            "url": url,
                            "asset_id": asset_id,
                            "hls_url": hls_url
                        }));

                        // Delete from database
                        let delete_result = sqlx::query!(
                            "DELETE FROM event_hls_media WHERE event_id = $1 AND url = $2 AND provider = $3",
                            &event_id_bytes[..],
                            url,
                            provider_name
                        ).execute(&state.pool).await;

                        match delete_result {
                            Ok(_) => {
                                info!("Deleted database record for {} asset {}", provider_name, asset_id);
                            }
                            Err(e) => {
                                log::warn!("Failed to delete database record: {}", e);
                            }
                        }
                    }
                    Err(e) => {
                        dbg!(&e);
                        let error_msg = format!("Failed to delete asset: {}", e);
                        log::error!("provider={}, asset_id={}: {}", provider_name, asset_id, error_msg);
                        errors.push(json!({
                            "provider": provider_name,
                            "url": url,
                            "asset_id": asset_id,
                            "error": error_msg
                        }));
                    }
                }
            }
            Err(e) => {
                let error_msg = format!("Failed to create provider: {}", e);
                log::error!("provider={}: {}", provider_name, error_msg);
                errors.push(json!({
                    "provider": provider_name,
                    "url": url,
                    "asset_id": asset_id,
                    "error": error_msg
                }));
            }
        }
    }

    Ok(json!({
        "event_id": event_id_hex,
        "resources_found": deleted.len() + errors.len(),
        "deleted": deleted,
        "errors": errors,
        "success_count": deleted.len(),
        "error_count": errors.len()
    }))
}

async fn delete_event_hls_resources_since(
    state: &Arc<AppState>,
    since: DateTime<Utc>,
) -> anyhow::Result<serde_json::Value> {
    use serde_json::json;

    info!("Querying events with HLS resources since {}", since);

    // Convert datetime to Unix timestamp (i64) as that's what's stored in the database
    let since_timestamp = since.timestamp();

    // Query database for all unique event_ids with HLS resources since the given datetime
    let rows = sqlx::query!(
        r#"
        SELECT DISTINCT event_id
        FROM event_hls_media
        WHERE created_at >= $1
        "#,
        since_timestamp
    )
    .fetch_all(&state.pool)
    .await?;

    if rows.is_empty() {
        info!("No HLS resources found since {}", since);
        return Ok(json!({
            "since": since.to_rfc3339(),
            "events_found": 0,
            "events_processed": 0,
            "total_deleted": 0,
            "total_errors": 0,
            "results": []
        }));
    }

    info!("Found {} events with HLS resources since {}", rows.len(), since);

    let mut results = Vec::new();
    let mut total_deleted = 0;
    let mut total_errors = 0;

    // Process each event
    for row in &rows {
        let event_id_hex = hex::encode(&row.event_id);
        info!("Processing event {}", event_id_hex);

        match delete_event_hls_resources(state, &event_id_hex).await {
            Ok(result) => {
                if let Some(deleted_count) = result.get("success_count").and_then(|v| v.as_u64()) {
                    total_deleted += deleted_count;
                }
                if let Some(error_count) = result.get("error_count").and_then(|v| v.as_u64()) {
                    total_errors += error_count;
                }
                results.push(result);
            }
            Err(e) => {
                let error_result = json!({
                    "event_id": event_id_hex,
                    "error": format!("Failed to process event: {}", e)
                });
                total_errors += 1;
                results.push(error_result);
            }
        }
    }

    Ok(json!({
        "since": since.to_rfc3339(),
        "events_found": rows.len(),
        "events_processed": results.len(),
        "total_deleted": total_deleted,
        "total_errors": total_errors,
        "results": results
    }))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Set up USR1 signal handler to dump tokio tasks
    // Register signal handler synchronously before spawning to avoid race condition
    let mut sig_usr1 = signal(SignalKind::user_defined1()).expect("failed to register USR1 signal handler");
    tokio::task::spawn(async move {
        loop {
            sig_usr1.recv().await;
            eprintln!("got signal USR1, dumping tokio tasks");
            let timestamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
            let filename = format!("tokio-tasks-{}.txt", timestamp);
            runtime_dump(&filename).await;
        }
    });

    let cli = Cli::parse();

    let cfg = Config::from_path(cli.config.to_str().unwrap())?;
    let log_level = cfg
        .log_level
        .as_deref()
        .unwrap_or("info");
    env_logger::Builder::from_env(Env::default().default_filter_or(log_level)).init();

    // Initialize BINARY_DATA_CACHE_DIR from config
    *processing_graph::BINARY_DATA_CACHE_DIR.write() = cfg.media.binary_data_cache_dir.clone();
    info!("binary data cache directory: {}", cfg.media.binary_data_cache_dir);

    let db_url = cfg.database_url();
    let db_cfg = cfg.database.clone().unwrap_or_default();
    info!("connecting to {}", db_url);

    // Parse the database URL and add statement_timeout option
    let connect_options: PgConnectOptions = db_url.parse()
        .with_context(|| format!("parsing database URL: {}", db_url))?;
    let connect_options = connect_options
        .options([("statement_timeout", &format!("{}s", db_cfg.statement_timeout_secs))]);

    info!("database statement_timeout: {}s, acquire_timeout: {}s",
          db_cfg.statement_timeout_secs, db_cfg.acquire_timeout_secs);

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(db_cfg.acquire_timeout_secs))
        .connect_with(connect_options)
        .await
        .with_context(|| format!("connecting to {}", db_url))?;

    let media_env = primal_media::media::MediaEnv::new(cfg.media.clone())
        .context("Failed to initialize MediaEnv")?;

    let state = Arc::new(AppState {
        pool,
        config: cfg,
        tasks: Arc::new(Mutex::new(HashMap::new())),
        media_env,
    });

    // Register handlers for proc nodes
    primal_media::register_builtin_nodes();

    // Handle subcommands
    match cli.command {
        Some(Commands::ExecuteNode { id }) => {
            // Decode hex ID to bytes
            let id_bytes = hex::decode(&id)
                .with_context(|| format!("failed to decode hex ID: {}", id))?;

            info!("executing node with ID: {}", id);
            let result = processing_graph::execute_node_by_id(&state, &id_bytes).await?;

            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::ImportMediaHls { event_id, url, media_url }) => {
            use serde_json::json;

            info!("importing media HLS for event_id={}, url={}", event_id, url);

            let media_url = media_url.unwrap_or_else(|| url.clone());

            // Build args tuple: (CacheStorage, EventId, url, media_url)
            let args = json!({
                "_ty": "Tuple",
                "_v": [
                    {"_ty": "CacheStorage"},
                    {"_ty": "EventId", "_v": event_id},
                    url,
                    media_url,
                ]
            });
            let kwargs = json!({});

            // Generate node ID
            let node_id = processing_graph::node_id("PrimalServer.DB", "import_media_hls_pn", &args, &kwargs);

            info!("executing import_media_hls_pn with node_id: {}", hex::encode(node_id.0));

            // Insert node record
            let _ = processing_graph::update_node(
                &state.pool,
                "PrimalServer.DB",
                "import_media_hls_pn",
                &args,
                &kwargs,
                Some(&node_id),
                None,
                false,
                None,
                None,
                None,
                None,
            ).await;

            // Execute node with full lifecycle handling (persistence, timing, error handling)
            let result = processing_graph::execute_node_by_id(&state, &node_id.0.to_vec()).await?;

            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::DeleteEventHlsResources { event_id, since }) => {
            match (event_id, since) {
                (Some(event_id), None) => {
                    // Delete HLS resources for a specific event
                    info!("deleting HLS resources for event_id={}", event_id);
                    let result = delete_event_hls_resources(&state, &event_id).await?;
                    println!("{}", serde_json::to_string_pretty(&result)?);
                    Ok(())
                }
                (None, Some(since_str)) => {
                    // Delete HLS resources for events since a specific datetime
                    let since_dt = parse_datetime(&since_str)
                        .with_context(|| format!("Failed to parse --since parameter: {}", since_str))?;

                    info!("deleting HLS resources for events since {}", since_dt);
                    let result = delete_event_hls_resources_since(&state, since_dt).await?;
                    println!("{}", serde_json::to_string_pretty(&result)?);
                    Ok(())
                }
                (Some(_), Some(_)) => {
                    Err(anyhow!("Cannot specify both --event-id and --since parameters. Use one or the other."))
                }
                (None, None) => {
                    Err(anyhow!("Must specify either --event-id or --since parameter"))
                }
            }
        }
        Some(Commands::ImportTextEvent { event_as }) => {
            use serde_json::json;

            info!("importing text event for event_id={}", event_as);

            // Build args tuple: (EventId,)
            let args = json!({
                "_ty": "Tuple",
                "_v": [
                    {"_ty": "EventId", "_v": event_as},
                ]
            });
            let kwargs = json!({});

            // Generate node ID
            let node_id = processing_graph::node_id("PrimalServer.DB", "import_text_event_pn", &args, &kwargs);

            info!("executing import_text_event_pn with node_id: {}", hex::encode(node_id.0));

            // Insert node record
            let _ = processing_graph::update_node(
                &state.pool,
                "PrimalServer.DB",
                "import_text_event_pn",
                &args,
                &kwargs,
                Some(&node_id),
                None,
                false,
                None,
                None,
                None,
                None,
            ).await;

            // Execute node with full lifecycle handling (persistence, timing, error handling)
            let result = processing_graph::execute_node_by_id(&state, &node_id.0.to_vec()).await?;

            println!("node_id: {}", hex::encode(node_id.0));
            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::ImportMedia { event_id, url, no_media_analysis }) => {
            use serde_json::json;

            info!("importing media for event_id={:?}, url={}, no_media_analysis={}", event_id, url, no_media_analysis);

            // Build args tuple: (CacheStorage, EventId or null, url)
            let event_id_value = match event_id {
                Some(eid) => json!({"_ty": "EventId", "_v": eid}),
                None => json!(null),
            };

            let args = json!({
                "_ty": "Tuple",
                "_v": [
                    {"_ty": "CacheStorage"},
                    event_id_value,
                    url,
                ]
            });
            let kwargs = json!({
                "no_media_analysis": no_media_analysis
            });

            // Generate node ID
            let node_id = processing_graph::node_id("PrimalServer.DB", "import_media_pn", &args, &kwargs);

            info!("executing import_media_pn with node_id: {}", hex::encode(node_id.0));

            // Insert node record
            let _ = processing_graph::update_node(
                &state.pool,
                "PrimalServer.DB",
                "import_media_pn",
                &args,
                &kwargs,
                Some(&node_id),
                None,
                false,
                None,
                None,
                None,
                None,
            ).await;

            // Execute node with full lifecycle handling (persistence, timing, error handling)
            let result = processing_graph::execute_node_by_id(&state, &node_id.0.to_vec()).await?;

            println!("node_id: {}", hex::encode(node_id.0));
            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::ImportPreview { event_id, url }) => {
            use serde_json::json;

            info!("importing preview for event_id={}, url={}", event_id, url);

            // Build args tuple: (CacheStorage, EventId, url)
            let args = json!({
                "_ty": "Tuple",
                "_v": [
                    {"_ty": "CacheStorage"},
                    {"_ty": "EventId", "_v": event_id},
                    url,
                ]
            });
            let kwargs = json!({});

            // Generate node ID
            let node_id = processing_graph::node_id("PrimalServer.DB", "import_preview_pn", &args, &kwargs);

            info!("executing import_preview_pn with node_id: {}", hex::encode(node_id.0));

            // Insert node record
            let _ = processing_graph::update_node(
                &state.pool,
                "PrimalServer.DB",
                "import_preview_pn",
                &args,
                &kwargs,
                Some(&node_id),
                None,
                false,
                None,
                None,
                None,
                None,
            ).await;

            // Execute node with full lifecycle handling (persistence, timing, error handling)
            let result = processing_graph::execute_node_by_id(&state, &node_id.0.to_vec()).await?;

            println!("node_id: {}", hex::encode(node_id.0));
            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::ProcessingNodeTree { node_id, no_pretty_print }) => {
            info!("building processing node tree for node_id={}", node_id);
            build_processing_node_tree(&state.pool, &node_id, no_pretty_print).await?;
            Ok(())
        }
        Some(Commands::DeleteProcessingNodeTree { node_id, dry_run }) => {
            if dry_run {
                info!("dry-run: checking what would be deleted for node_id={}", node_id);
            } else {
                info!("deleting processing node tree for node_id={}", node_id);
            }
            let result = delete_processing_node_tree(&state.pool, &node_id, dry_run).await?;
            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Commands::RunProcessingGraphScheduler) => {
            // Run scheduler loop until interrupted
            if let Err(e) = processing_graph_execution_scheduler::run_scheduler_loop(state.clone()).await {
                error!("scheduler exited with error: {}", e);
            }
            Ok(())
        }
        None => {
            Err(anyhow!("No command specified. Use --help for usage information."))
        }
    }
}
