use std::sync::Arc;
use tokio_tungstenite::tungstenite::Message;
use serde_json::Value;
use uuid::Uuid;
use futures::sink::Sink;
use futures_util::SinkExt;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use std::io::prelude::Write;

use crate::shared::{HandlerRequest, WebSocketId, Registration, register_subscription};
use crate::connector::handler_manager::HandlerManager;
use crate::connector::connection::{ClientWrite, MessageSink};
use crate::shared::utils::incr;

pub struct RequestRouter {
    handler_manager: Arc<HandlerManager>,
}

impl RequestRouter {
    pub fn new(handler_manager: Arc<HandlerManager>) -> Self {
        Self { handler_manager }
    }

    pub async fn handle_message<T: Sink<Message, Error = E> + Unpin + Send + 'static, E: std::fmt::Debug + Send + Sync + 'static>(
        &self,
        msg: &Message,
        conn_id: WebSocketId,
        client_write: ClientWrite<T>,
    ) -> Result<(bool, i64), Box<dyn std::error::Error + Send + Sync>>
    {
        let mut sendcnt = 0;
        if let Ok(d) = serde_json::from_str::<Value>(msg.to_text().unwrap()) {
            if Some("REQ") == d[0].as_str() {
                if let Some(sub_id) = d[1].as_str() {
                    if let Some(funcall) = d[2]["cache"][0].as_str() {
                        let kwargs = &d[2]["cache"][1];
                        
                        // Handle compression setting locally
                        if funcall == "set_primal_protocol" {
                            let mut cw = client_write.lock().await;
                            if kwargs["compression"] == "zlib" {
                                cw.use_zlib = true;
                            }
                            // Send EOSE response for set_primal_protocol
                            let eose_msg = format!("[\"EOSE\",\"{}\"]", sub_id);
                            let _ = send_ws_text(&mut cw, eose_msg, "Failed to send EOSE for set_primal_protocol", &mut sendcnt).await;
                            return Ok((true, sendcnt)); // Handled locally
                        }

                        let request = HandlerRequest {
                            id: Uuid::new_v4().to_string(),
                            msg: msg.to_text().unwrap().to_string(),
                            conn_id,
                            sub_id: sub_id.to_string(),
                            kwargs: kwargs.clone(),
                            funcall: funcall.to_string(),
                        };

                        match self.handler_manager.send_request(request).await {
                            Ok(resp) => {
                                let use_zlib = client_write.lock().await.use_zlib;
                                
                                if resp.handled {
                                    if use_zlib {
                                        // Use zlib compression - format as EVENTS array like the webapp expects
                                        let events_json = format!("[{}]", resp.response.messages.join(","));
                                        let events_msg = format!("[\"EVENTS\",\"{}\",{}]", sub_id, events_json);
                                        
                                        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());

                                        if encoder.write_all(events_msg.as_bytes()).is_ok() {
                                            if let Ok(compressed_data) = encoder.finish() {
                                                let mut cw = client_write.lock().await;
                                                if let Err(err) = cw.sink.send(Message::Binary(compressed_data)).await {
                                                    eprintln!("ws-connector: Failed to send compressed events to client: {:?}", err);
                                                }
                                            }
                                        }
                                    } else {
                                        // Send response back to client (uncompressed)
                                        let mut cw = client_write.lock().await;
                                        for event_str in &resp.response.messages {
                                            let event_msg = format!("[\"EVENT\",\"{}\",{}]", sub_id, event_str);
                                            let _ = send_ws_text(&mut cw, event_msg, "Failed to send event to client", &mut sendcnt).await;
                                        }
                                    }

                                    {
                                        let mut cw = client_write.lock().await;

                                        // Send notices (uncompressed for now)
                                        for notice in &resp.notices {
                                            let notice_msg = format!("[\"NOTICE\",\"{}\",\"{}\"]", sub_id, notice);
                                            if send_ws_text(&mut cw, notice_msg, "Failed to send notice to client", &mut sendcnt).await.is_err() {
                                                break;
                                            }
                                        }

                                        // Send EOSE if response was handled successfully
                                        if resp.error.is_none() {
                                            let eose_msg = format!("[\"EOSE\",\"{}\"]", sub_id);
                                            let _ = send_ws_text(&mut cw, eose_msg, "Failed to send EOSE to client", &mut sendcnt).await;
                                        }
                                    }

                                    for registration in &resp.response.registrations {
                                        match registration {
                                            Registration::LiveEvents { conn_id, sub_id, eaddr, key } => {
                                                let mut state = self.handler_manager.state.lock().await;
                                                state.live_events.register(*conn_id, sub_id.clone(), eaddr.clone(), key.clone());
                                                register_subscription(&mut state, *conn_id, sub_id.clone());
                                            }
                                            Registration::LiveEventsFromFollows { user_pubkey, sub_id } => {
                                                let mut state = self.handler_manager.state.lock().await;
                                                state.live_events_from_follows.register(conn_id, sub_id.clone(), user_pubkey.clone(), ());
                                                register_subscription(&mut state, conn_id, sub_id.clone());
                                            }
                                        }
                                    }
                                }                                                

                                if let Some(error) = &resp.error {
                                    eprintln!("ws-connector: Handler request error: {}", error);
                                }
                                
                                incr(&self.handler_manager.state.lock().await.shared.stats.handlereqcnt);

                                return Ok((resp.handled, sendcnt));
                            }
                            Err(err) => {
                                eprintln!("ws-connector: Failed to send request to handler: {}", err);
                                return Ok((false, sendcnt));
                            }
                        }
                    }
                }
            }
        }

        Ok((false, sendcnt))
    }

}

async fn send_ws_text<T>(
    cw: &mut MessageSink<T>,
    payload: String,
    err_context: &str,
    sendcnt: &mut i64,
) -> Result<(), <T as Sink<Message>>::Error>
where
    T: Sink<Message> + Unpin,
    <T as Sink<Message>>::Error: std::fmt::Debug,
{
    match cw.sink.send(Message::Text(payload)).await {
        Ok(_) => {
            *sendcnt += 1;
            Ok(())
        }
        Err(err) => {
            eprintln!("ws-connector: {}: {:?}", err_context, err);
            Err(err)
        }
    }
}

