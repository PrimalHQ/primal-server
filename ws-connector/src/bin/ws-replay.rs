// ws-replay: replays a request log to ws-connector
use std::collections::HashMap;
// removed unused HashSet import
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::Parser;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::{mpsc, Mutex};
use futures_util::stream::SplitSink;

use tokio_tungstenite::{connect_async, tungstenite::Message};

/// Command line arguments for the replay tool.
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// Path to the request log file (one JSON object per line).
    #[arg(short, long)]
    log_file: String,

    /// Backend ws-connector address, e.g. ws://127.0.0.1:8008
    #[arg(short, long)]
    backend_addr: String,

    /// Replay speed multiplier (e.g., 2.0 for twice as fast)
    #[arg(short, long, default_value = "1.0")]
    speed: f64,
}

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

/// Holds a websocket connection and a map of pending subscriptions.
#[derive(Debug)]
struct WsConn {
    // Writer half of the stream used for sending messages.
    writer: Arc<Mutex<SplitSink<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, Message>>>,
    // sub_id -> channel where we forward messages for that request.
    pending: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>>,
    // Timestamp of the last request sent on this connection.
    last_used: Arc<Mutex<u64>>,
}

impl WsConn {
    async fn send_request(
        &self,
        sub_id: &str,
        funcall: &str,
        kwargs: &Value,
    ) -> Result<mpsc::UnboundedReceiver<Value>, Box<dyn std::error::Error + Send + Sync>> {
        // eprintln!("ws-replay: send_request sub_id='{}' funcall='{}' kwargs={}", sub_id, funcall, kwargs);
        
        // Convert kwargs from array of objects to single flat object
        let mut flat_args = serde_json::Map::new();
        if let Value::Array(objects) = kwargs {
            for obj in objects {
                if let Value::Object(map) = obj {
                    for (key, value) in map {
                        // Skip usepgfuncs and apply_humaness_check
                        if key == "usepgfuncs" || key == "apply_humaness_check" {
                            continue;
                        }
                        flat_args.insert(key.clone(), value.clone());
                    }
                }
            }
        }
        
        // Build request JSON: ["REQ", sub_id, {"cache": [funcall, flat_args]}]
        let req = serde_json::json!(["REQ", sub_id, {"cache": [funcall, flat_args]}]);
        let txt = req.to_string();

        // Register a channel for this sub_id.
        let (tx, rx) = mpsc::unbounded_channel();
        {
            let mut pend = self.pending.lock().await;
            pend.insert(sub_id.to_string(), tx);
            // eprintln!("ws-replay: registered sub_id '{}' with channel", sub_id);
        }

        // Send the request with error handling for closed connections.
        {
            let mut s = self.writer.lock().await;
            // eprintln!("ws-replay: sending request for sub_id '{}': {}", sub_id, txt);
            if let Err(e) = s.send(Message::Text(txt)).await {
                // Clean up the registered channel on send failure
                let mut pend = self.pending.lock().await;
                pend.remove(sub_id);
                return Err(e.into());
            }
        }
        // eprintln!("ws-replay: sent request for sub_id '{}'", sub_id);

        // Update last_used with current real time.
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        *self.last_used.lock().await = now;
        Ok(rx)
    }
}

// ---------------------------------------------------------------------------
// Log entry parsing
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct LogEntry {
    t: f64,
    funcall: String,
    kwargs: Value,
    ws: String,
}

fn parse_log_line(line: &str) -> Option<LogEntry> {
    let v: Value = serde_json::from_str(line).ok()?;
    // Extract timestamp which may be a float in the log; convert to u64 seconds.
    let t_val = v.get("t")?;
    let t_f64 = if let Some(u) = t_val.as_u64() {
        u as f64
    } else if let Some(f) = t_val.as_f64() {
        f
    } else {
        return None;
    };
    Some(LogEntry {
        t: t_f64,
        funcall: v.get("funcall")?.as_str()?.to_string(),
        kwargs: v.get("kwargs")?.clone(),
        // ws field may be missing; default to empty string
        ws: v.get("ws").and_then(|w| w.as_str()).unwrap_or("").to_string(),
    })
}

// ---------------------------------------------------------------------------
// Helper functions for binary messages
// ---------------------------------------------------------------------------

fn decompress_binary(data: &[u8]) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    use flate2::read::ZlibDecoder;
    use std::io::Read;
    let mut dec = ZlibDecoder::new(data);
    let mut s = String::new();
    dec.read_to_string(&mut s)?;
    Ok(s)
}

async fn route_response(
    val: Value,
    pending: &Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>>,
) {
    // eprintln!("ws-replay: routing response: {}", val);
    if let Value::Array(arr) = &val {
        if let Some(sub_id) = arr.get(1).and_then(|v| v.as_str()) {
            let mut map = pending.lock().await;
            if let Some(tx) = map.get(sub_id) {
                // eprintln!("ws-replay: sending to pending sub_id={}", sub_id);
                let _ = tx.send(val.clone());
            }
            // Remove completed subscriptions.
            if let Some(tag) = arr.get(0).and_then(|v| v.as_str()) {
                if tag == "EOSE" || tag == "NOTICE" {
                    // eprintln!("ws-replay: removing sub_id {} due to tag {}", sub_id, tag);
                    map.remove(sub_id);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Connection factory and idle cleanup
// ---------------------------------------------------------------------------

async fn get_or_create_conn(
    ws_id: String,
    backend: String,
    conns: &Arc<Mutex<HashMap<String, Arc<WsConn>>>>,
    conn_cnt: &Arc<Mutex<usize>>,
) -> Result<Arc<WsConn>, Box<dyn std::error::Error + Send + Sync>> {
    // eprintln!("ws-replay: get_or_create_conn called for ws_id='{}'", ws_id);

    // First check if we already have a connection for this ws identifier.
    {
        let map = conns.lock().await;
        if let Some(c) = map.get(&ws_id) {
            return Ok(c.clone());
        }
    }

    // Check connection limit to prevent too many open files
    if !true {
        let current_count = *conn_cnt.lock().await;
        if current_count >= 100 { // Limit to 100 concurrent connections
            // Find and close the oldest idle connection
            let mut map = conns.lock().await;
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
            let mut oldest_id: Option<String> = None;
            let mut oldest_time = now;
            
            for (id, conn) in map.iter() {
                let last_used = *conn.last_used.lock().await;
                let pending_count = conn.pending.lock().await.len();
                if pending_count == 0 && last_used < oldest_time {
                    oldest_time = last_used;
                    oldest_id = Some(id.clone());
                }
            }
            
            if let Some(id) = oldest_id {
                if let Some(conn) = map.remove(&id) {
                    let _ = conn.writer.lock().await.close().await;
                    eprintln!("ws-replay: closed oldest connection {} to make room", id);
                    let mut conn_cnt = conn_cnt.lock().await;
                    *conn_cnt = conn_cnt.saturating_sub(1);
                }
            } else {
                return Err("Too many active connections and none can be closed".into());
            }
        }
    }

    // Create a new websocket.
    let (stream_raw, _) = connect_async(&backend).await.map_err(|e| format!("ws connect error: {}", e))?;
    // eprintln!("ws-replay: established new websocket {} to {}", ws_id, backend);

    {
        let mut conn_cnt = conn_cnt.lock().await;
        *conn_cnt += 1;
    }

    let (write_half, read_half) = stream_raw.split();
    let writer = Arc::new(Mutex::new(write_half));
    let conn = Arc::new(WsConn {
        writer: writer.clone(),
        pending: Arc::new(Mutex::new(HashMap::new())),
        last_used: Arc::new(Mutex::new(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs())),
    });

    // Spawn a task that reads incoming messages and routes them.
    let pending_map = conn.pending.clone();
    let mut read_half = read_half;
    tokio::spawn(async move {
        loop {
            let msg_opt = read_half.next().await;
            // eprintln!("ws-replay: received message: {:?}", msg_opt);
            match msg_opt {
                Some(Ok(Message::Text(txt))) => {
                    // eprintln!("ws-replay: received Text message: {}", txt);
                    if let Ok(val) = serde_json::from_str::<Value>(&txt) {
                        route_response(val, &pending_map).await;
                    }
                }
                Some(Ok(Message::Binary(bin))) => {
                    // eprintln!("ws-replay: received Binary message of {} bytes", bin.len());
                    if let Ok(txt) = decompress_binary(&bin) {
                        if let Ok(val) = serde_json::from_str::<Value>(&txt) {
                            route_response(val, &pending_map).await;
                        }
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(e)) => {
                    eprintln!("ws-replay: websocket error: {}", e);
                }
                None => break,
            }
        }
    });

    // Insert into the shared map.
    let mut map = conns.lock().await;
    map.insert(ws_id.clone(), conn.clone());
    Ok(conn)
}

async fn idle_cleanup_task(
    conns: Arc<Mutex<HashMap<String, Arc<WsConn>>>>, 
    conn_cnt: Arc<Mutex<usize>>,
    speed: f64,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        interval.tick().await;
        let now_real = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        
        let mut map = conns.lock().await;
        let mut to_remove = Vec::new();
        for (id, conn) in map.iter() {
            let last = *conn.last_used.lock().await;
            // Check if connection has pending requests before closing
            let pending_count = conn.pending.lock().await.len();
            // Adjust idle timeout based on speed: at higher speeds, connections should be closed faster
            // 300 seconds in simulated time = 300/speed seconds in real time
            let real_timeout = (300.0 / speed) as u64;
            if now_real.saturating_sub(last) >= real_timeout && pending_count == 0 {
                to_remove.push(id.clone());
            }
        }
        for id in to_remove {
            if let Some(conn) = map.remove(&id) {
                // Attempt to close gracefully, but don't fail if already closed
                if let Err(e) = conn.writer.lock().await.close().await {
                    eprintln!("ws-replay: note: connection {} was already closed: {}", id, e);
                } else {
                    // eprintln!("ws-replay: closed idle connection {}", id);
                }
                // Decrement connection counter
                let mut cnt = conn_cnt.lock().await;
                *cnt = cnt.saturating_sub(1);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Main function
// ---------------------------------------------------------------------------

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let cli = Cli::parse();

    // Load and parse the log file.
    let content = tokio::fs::read_to_string(&cli.log_file).await?;
    let mut entries = Vec::new();
    for (_i, line) in content.lines().enumerate() {
        if let Some(e) = parse_log_line(line) {
            // eprintln!("ws-replay: parsed line {}: funcall='{}' ws='{}'", i+1, e.funcall, e.ws);
            entries.push(e);
        }
        // else silently ignore malformed lines
    }

    // Sort entries by timestamp (f64). Use partial_cmp because f64 does not implement Ord.
    entries.sort_by(|a, b| a.t.partial_cmp(&b.t).unwrap_or(std::cmp::Ordering::Equal));

    let entries_len = entries.len();
    eprintln!("ws-replay: loaded {} entries from log file '{}'", entries_len, cli.log_file);

    // Ensure speed multiplier is positive to avoid division by zero.
    if cli.speed <= 0.0 {
        eprintln!("Error: --speed must be greater than 0 (got {}).", cli.speed);
        std::process::exit(1);
    }

    let running = Arc::new(tokio::sync::Mutex::new(true));

    // on Ctrl‑C program should exit gracefully
    {
        let ctrl_c = tokio::signal::ctrl_c();
        let running = running.clone();
        tokio::spawn(async move {
            ctrl_c.await.expect("Failed to listen for Ctrl-C");
            eprintln!("ws-replay: received Ctrl-C, exiting...");
            *running.lock().await = false;
        });
    }
    
    // Statistics counters.
    let conn_cnt = Arc::new(tokio::sync::Mutex::new(0usize));
    let sent_cnt = Arc::new(tokio::sync::Mutex::new(0usize));
    let success_cnt = Arc::new(tokio::sync::Mutex::new(0usize));
    let fail_cnt = Arc::new(tokio::sync::Mutex::new(0usize));
    let simulated_elapsed = Arc::new(tokio::sync::Mutex::new(0.0));

    // Shared connections map.
    let conns: Arc<Mutex<HashMap<String, Arc<WsConn>>>> = Arc::new(Mutex::new(HashMap::new()));

    // Spawn statistics printer.
    {
        let c = conn_cnt.clone();
        let s = sent_cnt.clone();
        let ok = success_cnt.clone();
        let err = fail_cnt.clone();
        let simulated_elapsed = simulated_elapsed.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                print_stats(
                    c.lock().await.clone(), s.lock().await.clone(), ok.lock().await.clone(), err.lock().await.clone(),
                    simulated_elapsed.lock().await.clone(), cli.speed,
                ).await;
            }
        });
    }

    // Spawn idle cleanup.
    tokio::spawn(idle_cleanup_task(conns.clone(), conn_cnt.clone(), cli.speed));

    // Vector to keep response handling task handles.
    // let mut response_handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    // failed requests counter by funcall
    let failed_requests: Arc<Mutex<HashMap<String, usize>>> = Arc::new(Mutex::new(HashMap::new()));

    // succeeded requests counter by funcall
    let succeeded_requests: Arc<Mutex<HashMap<String, usize>>> = Arc::new(Mutex::new(HashMap::new()));

    // Replay loop respecting original timestamps.
    let base_real = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64();
    let first_ts = entries.first().map(|e| e.t).unwrap_or(0.0);
    for entry in entries {
        *simulated_elapsed.lock().await = entry.t - first_ts;

        if !*running.lock().await {
            break;
        }

        if entry.funcall == "is_hidden_by_content_moderation" {
            continue;
        }

        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64();
        let target = base_real + (entry.t - first_ts) / cli.speed;
        if target > now {
            tokio::time::sleep(Duration::from_secs_f64(target - now)).await;
        }
        // Update sent counter.
        {
            let mut s = sent_cnt.lock().await;
            *s += 1;
        }
        // Get or create connection.
        let conn = match get_or_create_conn(entry.ws.clone(), cli.backend_addr.clone(), &conns, &conn_cnt).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("ws-replay: failed to get connection for '{}': {}", entry.ws, e);

                // Increment fail counter and continue with next entry
                let mut fail_cnt = fail_cnt.lock().await;
                *fail_cnt += 1;

                let mut failed_requests = failed_requests.lock().await;
                failed_requests.entry(entry.funcall.clone()).and_modify(|e| *e += 1).or_insert(1);

                continue;
            }
        };

        // Unique sub_id per request.
        let sub_id = uuid::Uuid::new_v4().to_string();
        // eprintln!("ws-replay: using sub_id '{}'", sub_id);
        
        // Send request with error handling.
        let mut rx = match conn.send_request(&sub_id, &entry.funcall, &entry.kwargs).await {
            Ok(receiver) => receiver,
            Err(e) => {
                eprintln!("ws-replay: failed to send request for sub_id '{}', funcall '{}': {}", sub_id, entry.funcall, e);
                
                // If this was a SendAfterClosing error, remove the connection from the map
                // so it will be recreated on the next attempt
                if e.to_string().contains("SendAfterClosing") {
                    let mut map = conns.lock().await;
                    map.remove(&entry.ws);
                    eprintln!("ws-replay: removed closed connection '{}' from pool", entry.ws);
                }
                
                // Increment fail counter and continue with next entry
                let mut fail_cnt = fail_cnt.lock().await;
                *fail_cnt += 1;

                let mut failed_requests = failed_requests.lock().await;
                failed_requests.entry(entry.funcall.clone()).and_modify(|e| *e += 1).or_insert(1);

                continue;
            }
        };
        // Spawn task to handle responses and keep handle.
        {
            let success_cnt = success_cnt.clone();
            let fail_cnt = fail_cnt.clone();
            let entry = entry.clone();
            let failed_requests = failed_requests.clone();
            let succeeded_requests = succeeded_requests.clone();
            let _handle = tokio::spawn(async move {
                let mut got_eose = false;
                while let Some(msg) = rx.recv().await {
                    // eprintln!("ws-replay: received response for sub_id '{}': {:?}", sub_id, msg);
                    if let Value::Array(arr) = &msg {
                        match arr.get(0).and_then(|v| v.as_str()) {
                            Some("EOSE") => got_eose = true,
                            Some("NOTICE") => {
                                // eprintln!("ws-replay: NOTICE for sub_id '{}': {}: request: {:?}", sub_id, msg, entry);
                                eprintln!("ws-replay: NOTICE for sub_id '{}', funcall '{}': {}", sub_id, entry.funcall, msg);

                                let mut fail_cnt = fail_cnt.lock().await;
                                *fail_cnt += 1;

                                let mut failed_requests = failed_requests.lock().await;
                                failed_requests.entry(entry.funcall.clone()).and_modify(|e| *e += 1).or_insert(1);
                            }
                            _ => {}
                        }
                    }
                }
                if got_eose {
                    let mut success_cnt = success_cnt.lock().await;
                    *success_cnt += 1;

                    let mut succeeded_requests = succeeded_requests.lock().await;
                    succeeded_requests.entry(entry.funcall.clone()).and_modify(|e| *e += 1).or_insert(1);
                }
            });
            // response_handles.push(handle);
        }
    }

    tokio::time::sleep(Duration::from_secs(5)).await;

    // Await all response handling tasks before exiting.
    // for h in response_handles {
    //     let _ = h.await;
    // }

    {
        let c = conn_cnt.clone();
        let s = sent_cnt.clone();
        let ok = success_cnt.clone();
        let err = fail_cnt.clone();
        print_stats(
            c.lock().await.clone(), s.lock().await.clone(), ok.lock().await.clone(), err.lock().await.clone(),
            simulated_elapsed.lock().await.clone(), cli.speed,
        ).await;
    }

    // print failed requests summary
    {
        println!("");
        let failed_requests = failed_requests.lock().await;
        if !failed_requests.is_empty() {
            eprintln!("ws-replay: failed requests summary ({} of {} requests sent):", sent_cnt.lock().await, entries_len);
            let mut failed_requests_vec: Vec<_> = failed_requests.iter().collect();
            failed_requests_vec.sort_by(|a, b| b.1.cmp(&a.1));
            for (funcall, failed_cnt) in failed_requests_vec {
                let succeeded_cnt = succeeded_requests.lock().await.get(funcall).cloned().unwrap_or(0);
                eprintln!("  {:>20}: {} / {} ({:.2}%)", funcall, failed_cnt, failed_cnt + succeeded_cnt, 
                         if *failed_cnt + succeeded_cnt > 0 {
                             (*failed_cnt as f64 / (*failed_cnt + succeeded_cnt) as f64) * 100.0
                         } else {
                             0.0
                         });
            }
        } else {
            eprintln!("ws-replay: no failed requests");
        }
    }

    Ok(())

}

async fn print_stats(
    conn: usize, sent: usize, success: usize, fail: usize, 
    simulated_elapsed: f64, speed: f64
) {
    let ratio = if sent == 0 { 0.0 } else { success as f64 / sent as f64 };
    let real_elapsed = simulated_elapsed / speed;
    eprintln!("conn: {} | sent: {} | success: {} | fail: {} | success_ratio: {:.2}% | t_sim: {:.1}s (t_real: {:.1}s @ {:.1}x)", 
        conn, sent, success, fail, ratio * 100.0,
        simulated_elapsed, real_elapsed, speed,
    );
}

