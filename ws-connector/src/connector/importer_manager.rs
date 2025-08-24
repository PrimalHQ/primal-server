use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::{interval, Duration};
use uuid::Uuid;

use crate::shared::{
    ImporterRequest, ImporterResponse, ProcessedEventDistribution, State, TaskTrace
};
use crate::connector::process_manager::{ProcessManager, PingRequest};
use primal_cache::{Event, PubKeyId};

pub struct LiveImporterManager {
    process_manager: Arc<ProcessManager<ImporterRequest, ImporterResponse>>,
}

impl LiveImporterManager {
    pub fn new(executable_path: String, args: Vec<String>, state: Arc<Mutex<State>>) -> Self {
        let process_manager = Arc::new(ProcessManager::new(
            executable_path,
            args,
            state,
            "importer".to_string(),
        ));
        
        Self {
            process_manager,
        }
    }

    pub async fn start(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.process_manager.start().await?;
        self.start_health_check().await;
        Ok(())
    }

    async fn start_health_check(&self) {
        let process_manager = self.process_manager.clone();
        let state = self.process_manager.state.clone();

        tokio::spawn(async move {
            let _tt = TaskTrace::new("importer-health-check", None, &state).await;
            let mut health_interval = interval(Duration::from_secs(5));
            
            loop {
                health_interval.tick().await;
                
                // Create a ping request using the trait implementation
                let ping_request = ImporterRequest::create_ping_request();

                // Send ping and update timestamp if successful
                let _ = process_manager.ping_process(ping_request).await;
            }
        });
    }

    pub async fn import_event(&self, event: Event, subscribed_users: Vec<PubKeyId>) -> Result<Vec<ProcessedEventDistribution>, Box<dyn std::error::Error + Send + Sync>> {
        let request_id = Uuid::new_v4().to_string();
        let request = ImporterRequest {
            id: request_id,
            event,
            subscribed_users,
        };

        let response = self.process_manager.send_request(request).await?;
        
        if response.success {
            Ok(response.processed_events)
        } else {
            Err(response.error.unwrap_or_else(|| "Unknown error".to_string()).into())
        }
    }
}
