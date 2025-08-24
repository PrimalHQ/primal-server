use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::{interval, Duration};

use crate::shared::{HandlerRequest, HandlerResponse, State, TaskTrace};
use crate::connector::process_manager::{ProcessManager, PingRequest};

pub struct HandlerManager {
    process_manager: Arc<ProcessManager<HandlerRequest, HandlerResponse>>,
    pub state: Arc<Mutex<State>>,
}

impl HandlerManager {
    pub fn new(executable_path: String, args: Vec<String>, state: Arc<Mutex<State>>) -> Self {
        let process_manager = Arc::new(ProcessManager::new(
            executable_path,
            args,
            state.clone(),
            "handler".to_string(),
        ));
        
        Self {
            process_manager,
            state,
        }
    }

    pub async fn start(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.process_manager.start().await?;
        self.start_health_check().await;
        Ok(())
    }

    async fn start_health_check(&self) {
        let process_manager = self.process_manager.clone();
        let state = self.state.clone();

        tokio::spawn(async move {
            let _tt = TaskTrace::new("handler-health-check", None, &state).await;
            let mut health_interval = interval(Duration::from_secs(5));
            
            loop {
                health_interval.tick().await;
                
                // Create a ping request using the trait implementation
                let ping_request = HandlerRequest::create_ping_request();

                // Send ping and update timestamp if successful
                let _ = process_manager.ping_process(ping_request).await;
            }
        });
    }

    pub async fn send_request(&self, request: HandlerRequest) -> Result<HandlerResponse, Box<dyn std::error::Error + Send + Sync>> {
        self.process_manager.send_request(request).await
    }
}
