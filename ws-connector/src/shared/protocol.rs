use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::shared::WebSocketId;
use primal_cache::{Event, EventAddr, PubKeyId};
use crate::connector::process_manager::{ProcessRequest, ProcessResponse, PingRequest, PingResponse};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandlerRequest {
    pub id: String,
    pub msg: String,
    pub conn_id: WebSocketId,
    pub sub_id: String,
    pub kwargs: Value,
    pub funcall: String,
}

impl ProcessRequest for HandlerRequest {
    type Response = HandlerResponse;
    
    fn get_id(&self) -> &str {
        &self.id
    }
}

impl PingRequest<HandlerResponse> for HandlerRequest {
    fn create_ping_request() -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            msg: r#"["REQ","ping","ping"]"#.to_string(),
            conn_id: -1, // Special health check connection ID
            sub_id: "health-check".to_string(),
            kwargs: serde_json::json!({}),
            funcall: "ping".to_string(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub messages: Vec<String>,
    pub registrations: Vec<Registration>,
}

impl Response {
    pub fn empty() -> Self {
        Self {
            messages: Vec::new(),
            registrations: Vec::new(),
        }
    }
    pub fn messages(messages: Vec<String>) -> Self {
        Self {
            messages,
            registrations: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub enum Registration {
    LiveEvents { conn_id: i64, sub_id: String, eaddr: EventAddr, key: (PubKeyId, crate::shared::types::ContentModerationMode) },
    LiveEventsFromFollows { user_pubkey: PubKeyId, sub_id: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HandlerResponse {
    pub id: String,
    pub handled: bool,
    pub response: Response,
    pub error: Option<String>,
    pub notices: Vec<String>,
}

impl ProcessResponse for HandlerResponse {
    fn get_id(&self) -> &str {
        &self.id
    }
}

impl PingResponse for HandlerResponse {
    fn is_successful(&self) -> bool {
        self.handled && self.error.is_none()
    }
}

impl HandlerResponse {
    pub fn handled(id: String, response: Response) -> Self {
        Self {
            id,
            handled: true,
            response,
            error: None,
            notices: Vec::new(),
        }
    }

    pub fn not_handled(id: String) -> Self {
        Self {
            id,
            handled: false,
            response: Response::empty(),
            error: None,
            notices: Vec::new(),
        }
    }

    pub fn notice(id: String, notice: String) -> Self {
        Self {
            id,
            handled: true,
            response: Response::empty(),
            error: None,
            notices: vec![notice],
        }
    }

    pub fn error(id: String, error: String) -> Self {
        Self {
            id,
            handled: false,
            response: Response::empty(),
            error: Some(error),
            notices: Vec::new(),
        }
    }
}

// Importer Protocol Structs

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImporterRequest {
    pub id: String,
    pub event: Event,
    pub subscribed_users: Vec<PubKeyId>,
}

impl ProcessRequest for ImporterRequest {
    type Response = ImporterResponse;
    
    fn get_id(&self) -> &str {
        &self.id
    }
}

impl PingRequest<ImporterResponse> for ImporterRequest {
    fn create_ping_request() -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            event: Event {
                id: primal_cache::EventId(vec![0u8; 32]), // Dummy event ID for health check
                pubkey: primal_cache::PubKeyId(vec![0u8; 32]), // Dummy pubkey
                created_at: 0,
                kind: 999999, // Special health check kind
                tags: vec![],
                content: "health-check-ping".to_string(),
                sig: vec![0u8; 64].into(), // Dummy signature
            },
            subscribed_users: vec![], // Empty users for health check
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ImporterResponse {
    pub id: String,
    pub success: bool,
    pub processed_events: Vec<ProcessedEventDistribution>,
    pub error: Option<String>,
}

impl ProcessResponse for ImporterResponse {
    fn get_id(&self) -> &str {
        &self.id
    }
}

impl PingResponse for ImporterResponse {
    fn is_successful(&self) -> bool {
        self.success
    }
}

impl ImporterResponse {
    pub fn success(id: String, processed_events: Vec<ProcessedEventDistribution>) -> Self {
        Self {
            id,
            success: true,
            processed_events,
            error: None,
        }
    }

    pub fn error(id: String, error: String) -> Self {
        Self {
            id,
            success: false,
            processed_events: Vec::new(),
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessedEventDistribution {
    pub distribution_type: DistributionType,
    pub event: Event,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DistributionType {
    EventAddr { eaddr: EventAddr },
    FollowsBased { user_pubkey: PubKeyId },
}

