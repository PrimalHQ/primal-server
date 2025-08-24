use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::net::TcpStream;
use futures_util::{StreamExt, SinkExt};
use tokio_tungstenite::tungstenite::Message;
use tokio::time::{timeout, Duration};
use futures::sink::Sink;
use serde_json::json;

use crate::shared::{WebSocketId, get_sys_time_in_secs, get_tokio_task_id, State, TaskTrace, send_log};
use crate::connector::router::RequestRouter;
use crate::shared::types::ReqError;
use crate::shared::utils::{incr_by, incr, decr};

pub struct MessageSink<T: Sink<Message>> {
    pub use_zlib: bool,
    pub sink: T,
}

pub type ClientWrite<T> = Arc<Mutex<MessageSink<T>>>;

#[derive(Clone)]
pub struct ConnectionManager {
    router: Arc<RequestRouter>,
    state: Arc<Mutex<State>>,
}

impl ConnectionManager {
    pub fn new(router: Arc<RequestRouter>, state: Arc<Mutex<State>>) -> Self {
        Self { router, state }
    }

    pub async fn handle_connection(
        &self,
        state: &Arc<Mutex<State>>,
        stream: TcpStream,
        conn_id: WebSocketId,
        backend_addr: String,
        idle_timeout: u64,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // eprintln!("ws-connector: New connection: {}", conn_id);

        let _tt = TaskTrace::new("handle_connection", Some(conn_id), &self.state).await;
        let ws_stream_client = tokio_tungstenite::accept_async(stream).await?;
        let (client_write, mut client_read) = ws_stream_client.split();

        let arc_client_write = Arc::new(Mutex::new(MessageSink {
            use_zlib: false,
            sink: client_write,
        }));

        let (ws_stream_backend, _) = tokio_tungstenite::connect_async(backend_addr).await?;
        let (backend_write, mut backend_read) = ws_stream_backend.split();
        let arc_backend_write = Arc::new(Mutex::new(backend_write));

        {
            let mut state = state.lock().await;
            state.websockets.insert(conn_id, arc_client_write.clone());
        }

        struct Cleanup<T1: Sink<Message> + Unpin + Send + 'static, T2: Sink<Message> + Unpin + Send + 'static> {
            conn_id: WebSocketId,
            cw: ClientWrite<T1>,
            bw: Arc<Mutex<T2>>,
            state: Arc<Mutex<State>>,
        }
        impl<T1: Sink<Message> + Unpin + Send + 'static, T2: Sink<Message> + Unpin + Send + 'static> Drop for Cleanup<T1, T2> {
            fn drop(&mut self) {
                let cw = self.cw.clone();
                let bw = self.bw.clone();
                let state = self.state.clone();
                let conn_id = self.conn_id;
                tokio::spawn(async move {
                    {
                        let mut state = state.lock().await;
                        decr(&state.shared.stats.connections);
                        state.websockets.remove(&conn_id);
                        for sub in state.ws_to_subs.remove(&conn_id).unwrap_or_default() {
                            state.subs_to_ws.remove(&(conn_id, sub.clone()));
                            state.live_events.unregister(conn_id, sub.clone());
                            state.live_events_from_follows.unregister(conn_id, sub.clone());
                        }
                    }
                    let _ = cw.lock().await.sink.close().await;
                    let _ = bw.lock().await.close().await;
                    // eprintln!("ws-connector: Connection closed clean up: {}", conn_id);
                });
            }
        }
        let _cleanup = Cleanup {
            conn_id,
            cw: arc_client_write.clone(),
            bw: arc_backend_write.clone(),
            state: state.clone(),
        };

        let running = Arc::new(Mutex::new(true));
        let t_last_msg = Arc::new(Mutex::new(get_sys_time_in_secs()));

        // Idle connection timeout handler
        {
            let running = running.clone();
            let t_last_msg = t_last_msg.clone();
            let client_write = arc_client_write.clone();
            let backend_write = arc_backend_write.clone();
            let state = self.state.clone();
            let rfactor = rand::random::<f64>() * 0.05 + 0.95;
            tokio::task::spawn(async move {
                let _tt = TaskTrace::new("close-idle-connection", Some(conn_id), &state).await;
                let mut interval = tokio::time::interval(Duration::from_secs(3));
                while *running.lock().await {
                    interval.tick().await;
                    let t = get_sys_time_in_secs();
                    let tl = t_last_msg.lock().await;
                    let dt = t - *tl;
                    if dt >= ((rfactor * (idle_timeout as f64)) as u64) {
                        *running.lock().await = false;
                        // Ensure proper lock ordering: acquire state lock first, then connection locks
                        {
                            let _state_guard = state.lock().await; // Acquire state lock first to maintain order
                            let _ = client_write.lock().await.sink.close().await;
                            let _ = backend_write.lock().await.close().await;
                        }
                        eprintln!("ws-connector: Closing idle connection: {}, last message was {} seconds ago", conn_id, dt);
                        send_log(get_tokio_task_id(), "close-idle-connection", json!({"event": "idle-connection-closed"}), &state).await;
                        break;
                    }
                }
            });
        }

        // Proxy messages from backend to client
        {
            let t_last_msg = t_last_msg.clone();
            let client_write = arc_client_write.clone();
            let state = self.state.clone();
            tokio::spawn(async move {
                let _tt = TaskTrace::new("proxy-backend-messages", Some(conn_id), &state).await;
                while let Some(Ok(msg)) = backend_read.next().await {
                    if msg.is_text() || msg.is_binary() {
                        if let Err(err) = client_write.lock().await.sink.send(msg.clone()).await {
                            eprintln!("ws-connector: Failed to send message to client: {:?}, error: {}", msg, err);
                            break;
                        }
                        *t_last_msg.lock().await = get_sys_time_in_secs();
                        incr(&state.lock().await.shared.stats.proxyreqcnt);
                    }
                }
                let _ = client_write.lock().await.sink.close().await;
            });
        }

        // Handle messages from client
        let router = self.router.clone();
        let client_write = arc_client_write.clone();
        let backend_write = arc_backend_write.clone();
        let running = running.clone();

        while *running.lock().await {
            match timeout(Duration::from_secs(1), client_read.next()).await {
                Ok(None) => {
                    // eprintln!("ws-connector: Client disconnected: {}", conn_id);
                    *running.lock().await = false;
                },
                Ok(Some(Ok(msg))) => {
                    // eprintln!("ws-connector: Received message from client: {}, msg: {:?}", conn_id, msg);
                    if msg.is_text() || msg.is_binary() {
                        *t_last_msg.lock().await = get_sys_time_in_secs();
                        incr(&state.lock().await.shared.stats.recvmsgcnt);
                        
                        let (handled, sendcnt) = router.handle_message(
                            &msg, 
                            conn_id, 
                            client_write.clone()
                        ).await.unwrap_or((false, 0));

                        incr_by(&state.lock().await.shared.stats.sendmsgcnt, sendcnt);

                        if !handled {
                            if let Err(err) = backend_write.lock().await.send(msg.clone()).await {
                                eprintln!("ws-connector: Failed to send message to backend: {:?}, error: {}", msg, err);
                                break;
                            }
                        }
                    }
                }
                Ok(Some(Err(err))) => {
                    eprintln!("ws-connector: Error reading message from client: {}, error: {}", conn_id, err);
                    *running.lock().await = false;
                }
                Err(_err) => {
                    // eprintln!("ws-connector: Timeout waiting for message from client: {}, error: {}", conn_id, err);
                }
            }
        }

        // eprintln!("ws-connector: Connection done: {}", conn_id);

        Ok(())
    }
}

pub async fn send_event_str<T: Sink<Message> + Unpin>(subid: &str, e: &str, cw: &mut MessageSink<T>) -> Result<(), ReqError> {
    let mut msg = String::from("[\"EVENT\",\"");
    msg.push_str(subid);
    msg.push_str("\",");
    msg.push_str(e);
    msg.push_str("]");
    cw.sink.send(Message::Text(msg)).await.map_err(|_| "failed to send text event response to client")?;
    Ok(())
}


