use std::error::Error;
use tokio_tungstenite::{connect_async, tungstenite::Message, WebSocketStream, MaybeTlsStream};
use tokio::net::TcpStream;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use serde_json::json;
use std::sync::atomic::{AtomicI64, Ordering};
use std::collections::HashSet;
use flate2::read::ZlibDecoder;
use std::io::Read;

/// Sends a JSON `request` over the provided WebSocket `ws_stream` and collects
/// all text responses until an `EOSE` message or a timeout.
///
/// Returns a vector of parsed `serde_json::Value` objects.
pub async fn send_request_and_get_response(
    ws_stream: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    subid: &str,
    funcall: &str,
    kwargs: &Value,
) -> Result<Vec<Value>, Box<dyn Error + Send + Sync>> {
    let request_str = json!(["REQ", subid, {"cache": [funcall, kwargs]}]).to_string();
    // eprintln!("Sending: {}", request_str);
    ws_stream.send(Message::Text(request_str)).await?;

    let mut responses = Vec::new();
    let timeout_duration = std::time::Duration::from_secs(10);

    loop {
        match tokio::time::timeout(timeout_duration, ws_stream.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                // eprintln!("Received: {}", text);
                let response: Value = serde_json::from_str(&text)?;
                let is_eose = if let Value::Array(arr) = &response {
                    arr.len() >= 2 && arr[0].as_str() == Some("EOSE")
                } else {
                    false
                };
                responses.push(response);
                if is_eose {
                    eprintln!("Received EOSE for subscription: {}", subid);
                    break;
                }
            }
            Ok(Some(Ok(Message::Binary(data)))) => {
                eprintln!("Received binary message (compressed) of {} bytes", data.len());
                
                // Decompress the binary data using zlib
                let mut decoder = ZlibDecoder::new(&data[..]);
                let mut decompressed = String::new();
                match decoder.read_to_string(&mut decompressed) {
                    Ok(_) => {
                        // eprintln!("Decompressed: {}", decompressed);
                        match serde_json::from_str::<Value>(&decompressed) {
                            Ok(response) => {
                                if let Value::Array(arr) = &response {
                                    if arr.len() >= 3 && arr[0].as_str() == Some("EVENTS") {
                                        // Handle EVENTS message - convert each event to individual EVENT messages
                                        if let Value::Array(events) = &arr[2] {
                                            for event in events {
                                                let event_response = json!(["EVENT", arr[1].clone(), event]);
                                                responses.push(event_response);
                                            }
                                        }
                                        continue;
                                    } else if arr.len() >= 2 && arr[0].as_str() == Some("EOSE") {
                                        eprintln!("Received EOSE for subscription: {}", subid);
                                        responses.push(response);
                                        break;
                                    }
                                }
                                responses.push(response);
                            }
                            Err(e) => {
                                eprintln!("Failed to parse decompressed JSON: {}", e);
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("Failed to decompress binary data: {}", e);
                    }
                }
                continue;
            }
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(err))) => {
                eprintln!("Error while processing message: {}", err);
                break;
            },
            Ok(None) => {
                eprintln!("WebSocket closed by peer");
                break;
            },
            Err(err) => {
                eprintln!("Timeout or error while waiting for response: {}", err);
                break;
            }, // Timeout
        }
    }

    Ok(responses)
}

pub fn incr_by(x: &AtomicI64, by: i64) { x.fetch_add(by, Ordering::Relaxed); }
pub fn incr(x: &AtomicI64) { incr_by(x, 1); }
pub fn decr(x: &AtomicI64) { incr_by(x, -1); }

pub async fn compare_backend_api_response(backend1_addr: &str, backend2_addr: &str, sub_id: &str, funcall: &str, kwargs: &str) -> Result<Vec<Value>, Box<dyn Error + Send + Sync>> {
    let kwargs: Value = serde_json::from_str(kwargs)?;

    let mut ws1 = connect_async(backend1_addr).await?.0;
    let mut ws2 = connect_async(backend2_addr).await?.0;

    fn canonical_json(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let mut sorted_map: Vec<_> = map.iter().collect();
                sorted_map.sort_by(|a, b| a.0.cmp(b.0));
                Value::Object(serde_json::Map::from_iter(sorted_map.into_iter().map(|(k, v)| (k.clone(), canonical_json(v)))))
            }
            Value::Array(arr) => Value::Array(arr.iter().map(canonical_json).collect()),
            _ => value.clone(),
        }
    }

    fn canonical_event_content(value: &Value) -> Value {
        let mut v = value.clone();
        if value[0].as_str() == Some("EVENT") {
            if let Some(e) = value.as_array().and_then(|arr| arr.get(2)) {
                let mut e = e.clone();
                if let (Some(Value::Number(kind)), Some(Value::String(content))) = (e.get("kind"), e.get("content")) {
                    if let Some(kind) = kind.as_i64() {
                        if kind >= 10_000_000 {
                            let content = serde_json::from_str(&content).unwrap_or(Value::Null);
                            e["content"] = Value::String(canonical_json(&content).to_string());
                        }
                    }
                }
                v[2] = e;
            }
        }
        v
    }

    let responses1: HashSet<Value> = send_request_and_get_response(&mut ws1, sub_id, funcall, &kwargs).await?.into_iter().map(|v| canonical_json(&canonical_event_content(&v))).collect();
    let responses2: HashSet<Value> = send_request_and_get_response(&mut ws2, sub_id, funcall, &kwargs).await?.into_iter().map(|v| canonical_json(&canonical_event_content(&v))).collect();

    let diff: Vec<Value> = responses1.difference(&responses2).cloned().collect();
    dbg!(&diff);

    Ok(diff)
}


use primal_cache::Event;

pub fn fixup_live_event_p_tags(e: &Event) -> Event {
    if let Ok(v) = serde_json::to_value(e) {
        if let Ok(e) = serde_json::from_str::<Event>(fixup_live_event_p_tags_str(v.to_string()).as_str()) {
            e
        } else {
            e.clone()
        }
    } else {
        e.clone()
    }
}

pub fn fixup_live_event_p_tags_str(s: String) -> String {
    if let Some(e) = serde_json::from_str::<Value>(s.as_str()).ok() {
        if let Some(e) = e.as_object() {
            if let Some(30311) = e["kind"].as_i64() {
                if let Some(tags) = e["tags"].as_array() {
                    let mut e = e.clone();
                    let mut newtags = vec![];
                    for t in tags {
                        if let Some(t) = t.as_array() {
                            let mut t = t.clone();
                            if t.len() >= 4 && t[0] == "p" {
                                if let Some(role) = t[3].as_str() {
                                    t[3] = Value::String(role.to_lowercase());
                                }
                            }
                            newtags.push(Value::Array(t));
                        }
                    }
                    e["tags"] = Value::Array(newtags);
                    let e = Value::Object(e);
                    return e.to_string();
                }
            }
        }
    }
    s
}

