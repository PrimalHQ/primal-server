use std::collections::HashMap;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, mpsc};
use tokio::time::{interval, Duration};
use serde::{Serialize, Deserialize};
use tokio::io::AsyncWriteExt;

use crate::shared::{State, TaskTrace};

/// RAII guard that ensures cleanup of active_requests entries on drop
/// This prevents request leaks when futures are cancelled
struct RequestGuard<TResponse: Send + 'static> {
    active_requests: Arc<Mutex<HashMap<String, mpsc::Sender<TResponse>>>>,
    request_id: String,
}

impl<TResponse: Send + 'static> RequestGuard<TResponse> {
    fn new(active_requests: Arc<Mutex<HashMap<String, mpsc::Sender<TResponse>>>>, request_id: String) -> Self {
        Self {
            active_requests,
            request_id,
        }
    }
}

impl<TResponse: Send + 'static> Drop for RequestGuard<TResponse> {
    fn drop(&mut self) {
        let active_requests = self.active_requests.clone();
        let request_id = self.request_id.clone();
        
        // Spawn task to avoid blocking Drop
        tokio::spawn(async move {
            let mut ar = active_requests.lock().await;
            ar.remove(&request_id);
        });
    }
}

/// Maximum number of concurrent in-flight requests per subprocess
const MAX_IN_FLIGHT_REQUESTS: usize = 10_000;

/// Common trait for request/response handling in subprocess managers
pub trait ProcessRequest: Send + Sync {
    type Response: Send + Sync;
    
    fn get_id(&self) -> &str;
}

/// Common trait for subprocess response handling
pub trait ProcessResponse: Send + Sync {
    fn get_id(&self) -> &str;
}

/// Generic subprocess wrapper
pub struct SubProcess<TRequest, TResponse>
where
    TRequest: ProcessRequest<Response = TResponse>,
    TResponse: ProcessResponse,
{
    pub process: Arc<Mutex<Child>>,
    pub stdin: Arc<Mutex<tokio::process::ChildStdin>>,
    pub version: SystemTime,
    pub active_requests: Arc<Mutex<HashMap<String, mpsc::Sender<TResponse>>>>,
    _phantom: std::marker::PhantomData<TRequest>,
}

impl<TRequest, TResponse> SubProcess<TRequest, TResponse>
where
    TRequest: ProcessRequest<Response = TResponse> + Serialize + Send + Sync + 'static,
    TResponse: ProcessResponse + for<'de> Deserialize<'de> + Send + Sync + 'static,
{
    pub async fn spawn(
        executable_path: &str, 
        args: &[String], 
        state: Option<Arc<Mutex<State>>>,
        task_name_prefix: String,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let mut process = Command::new(executable_path)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;

        let stdin = process.stdin.take().ok_or("Failed to get stdin")?;
        let stdout = process.stdout.take().ok_or("Failed to get stdout")?;
        
        let metadata = tokio::fs::metadata(executable_path).await?;
        let version = metadata.modified()?;

        let active_requests: Arc<Mutex<HashMap<String, mpsc::Sender<TResponse>>>> = Arc::new(Mutex::new(HashMap::new()));
        
        // Start the response handler task
        let active_requests_clone = active_requests.clone();
        let state_clone = state.clone();
        let task_name = format!("{}-response-handler", task_name_prefix);
        tokio::spawn(async move {
            let _tt = if let Some(ref state) = state_clone {
                Some(TaskTrace::new(&task_name, None, state).await)
            } else {
                None
            };
            use tokio::io::{AsyncBufReadExt, BufReader};
            
            let mut reader = BufReader::new(stdout);
            let mut line = String::new();
            
            loop {
                line.clear();
                match reader.read_line(&mut line).await {
                    Ok(0) => break, // EOF
                    Ok(_) => {
                        if line.trim().is_empty() {
                            continue;
                        }
                        
                        match serde_json::from_str::<TResponse>(&line) {
                            Ok(response) => {
                                let tx_opt = {
                                    let mut active_requests = active_requests_clone.lock().await;
                                    active_requests.remove(response.get_id())
                                };
                                if let Some(tx) = tx_opt {
                                    let _ = tx.send(response).await;
                                } else {
                                    eprintln!("ws-connector: Received response for unknown {} request ID: {}", task_name_prefix, response.get_id());
                                }
                            }
                            Err(err) => {
                                eprintln!("ws-connector: Failed to parse {} response: {}, line: {}", task_name_prefix, err, line);
                            }
                        }
                    }
                    Err(err) => {
                        eprintln!("ws-connector: Failed to read from {} stdout: {}", task_name_prefix, err);
                        break;
                    }
                }
            }
        });

        Ok(Self {
            process: Arc::new(Mutex::new(process)),
            stdin: Arc::new(Mutex::new(stdin)),
            version,
            active_requests,
            _phantom: std::marker::PhantomData,
        })
    }


    pub async fn is_idle(&self) -> bool {
        self.active_requests.lock().await.is_empty()
    }

    /// Clean up all pending requests by closing their channels
    pub async fn abort_pending(&self) {
        let mut active_requests = self.active_requests.lock().await;
        for (_request_id, tx) in active_requests.drain() {
            // Close the sender channel - receivers will get None
            drop(tx);
        }
    }

    pub async fn shutdown(self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.process.lock().await.kill().await.map_err(|e| format!("Failed to kill process: {}", e).into())
    }
}

/// Generic process manager for handling subprocesses with restart capability
pub struct ProcessManager<TRequest, TResponse>
where
    TRequest: ProcessRequest<Response = TResponse> + Clone,
    TResponse: ProcessResponse,
{
    pub executable_path: String,
    pub args: Vec<String>,
    pub current_process: Arc<Mutex<Option<SubProcess<TRequest, TResponse>>>>,
    pub previous_process: Arc<Mutex<Option<SubProcess<TRequest, TResponse>>>>,
    pub last_check: Arc<Mutex<SystemTime>>,
    pub state: Arc<Mutex<State>>,
    pub process_name: String,
    pub last_successful_ping: Arc<Mutex<SystemTime>>,
    pub ping_timeout_seconds: u64,
}

/// Health check trait for ping requests
pub trait PingRequest<TResponse> {
    fn create_ping_request() -> Self;
}

/// Health check trait for ping responses  
pub trait PingResponse {
    fn is_successful(&self) -> bool;
}

impl<TRequest, TResponse> ProcessManager<TRequest, TResponse>
where
    TRequest: ProcessRequest<Response = TResponse> + Clone + Serialize + Send + Sync + 'static,
    TResponse: ProcessResponse + for<'de> Deserialize<'de> + Send + Sync + 'static,
{
    pub fn new(
        executable_path: String, 
        args: Vec<String>, 
        state: Arc<Mutex<State>>,
        process_name: String,
    ) -> Self {
        Self {
            executable_path,
            args,
            current_process: Arc::new(Mutex::new(None)),
            previous_process: Arc::new(Mutex::new(None)),
            last_check: Arc::new(Mutex::new(SystemTime::UNIX_EPOCH)),
            state,
            process_name,
            last_successful_ping: Arc::new(Mutex::new(SystemTime::UNIX_EPOCH)),
            ping_timeout_seconds: 30, // Default 30 seconds timeout for health checks
        }
    }

    pub async fn start(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.spawn_initial_process().await?;
        self.start_monitoring().await;
        Ok(())
    }

    async fn spawn_initial_process(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let process = SubProcess::spawn(&self.executable_path, &self.args, Some(self.state.clone()), self.process_name.clone()).await?;
        
        let metadata = tokio::fs::metadata(&self.executable_path).await?;
        *self.last_check.lock().await = metadata.modified()?;
        
        *self.current_process.lock().await = Some(process);
        *self.last_successful_ping.lock().await = SystemTime::now();
        Ok(())
    }

    async fn start_monitoring(&self) {
        let executable_path = self.executable_path.clone();
        let args = self.args.clone();
        let current_process = self.current_process.clone();
        let previous_process = self.previous_process.clone();
        let last_check = self.last_check.clone();
        let state = self.state.clone();
        let process_name = self.process_name.clone();
        let last_successful_ping = self.last_successful_ping.clone();
        let ping_timeout_seconds = self.ping_timeout_seconds;

        tokio::spawn(async move {
            let monitoring_task_name = format!("{}-monitoring", process_name);
            let _tt = TaskTrace::new(&monitoring_task_name, None, &state).await;
            let mut interval = interval(Duration::from_secs(1));
            
            loop {
                interval.tick().await;
                
                // Check if current process is still alive
                let process_died = {
                    let current_process = current_process.lock().await;
                    if let Some(ref process) = *current_process {
                        // Try to check if the child process has exited
                        match process.process.lock().await.try_wait() {
                            Ok(Some(status)) => {
                                eprintln!("ws-connector: {} process died with exit status: {:?}", process_name, status);
                                true
                            }
                            Ok(None) => false, // Still running
                            Err(_) => {
                                eprintln!("ws-connector: Error checking {} process status, assuming it died", process_name);
                                true
                            }
                        }
                    } else {
                        true // No process exists
                    }
                };
                
                if process_died {
                    eprintln!("ws-connector: Detected dead {} process, respawning...", process_name);
                    
                    // Clean up the dead process
                    {
                        let mut current = current_process.lock().await;
                        if let Some(old_process) = current.take() {
                            old_process.abort_pending().await;
                            let _ = old_process.shutdown().await;
                        }
                    }
                    
                    // Spawn new process
                    match SubProcess::spawn(&executable_path, &args, Some(state.clone()), process_name.clone()).await {
                        Ok(new_process) => {
                            *current_process.lock().await = Some(new_process);
                            *last_successful_ping.lock().await = SystemTime::now(); // Reset ping timestamp
                            eprintln!("ws-connector: {} process respawned successfully", process_name);
                        }
                        Err(err) => {
                            eprintln!("ws-connector: Failed to respawn {} process: {}", process_name, err);
                        }
                    }
                    continue; // Skip executable update check since we just spawned a new process
                }
                
                // Check if process needs to be restarted due to ping timeout
                let needs_restart_due_to_ping = {
                    let last_ping = *last_successful_ping.lock().await;
                    let elapsed = SystemTime::now()
                        .duration_since(last_ping)
                        .unwrap_or(Duration::from_secs(u64::MAX))
                        .as_secs();
                    // eprintln!("ws-connector: {} process last, {} seconds elapsed", &process_name, elapsed);
                    elapsed > ping_timeout_seconds
                };
                
                if needs_restart_due_to_ping {
                    eprintln!("ws-connector: {} process not responding to health checks for {} seconds, restarting...", process_name, ping_timeout_seconds);
                    
                    // Clean up the unresponsive process
                    {
                        let mut current = current_process.lock().await;
                        if let Some(old_process) = current.take() {
                            old_process.abort_pending().await;
                            let _ = old_process.shutdown().await;
                        }
                    }
                    
                    // Spawn new process
                    match SubProcess::spawn(&executable_path, &args, Some(state.clone()), process_name.clone()).await {
                        Ok(new_process) => {
                            *current_process.lock().await = Some(new_process);
                            *last_successful_ping.lock().await = SystemTime::now(); // Reset ping timestamp
                            eprintln!("ws-connector: {} process restarted successfully due to ping timeout", process_name);
                        }
                        Err(err) => {
                            eprintln!("ws-connector: Failed to restart {} process: {}", process_name, err);
                        }
                    }
                    continue; // Skip executable update check since we just spawned a new process
                }
                
                // Check for executable updates
                if let Ok(metadata) = tokio::fs::metadata(&executable_path).await {
                    if let Ok(modified) = metadata.modified() {
                        let last_check_time = *last_check.lock().await;
                        
                        if modified > last_check_time {
                            eprintln!("ws-connector: {} executable updated, spawning new process", process_name);
                            
                            // Spawn new process
                            match SubProcess::spawn(&executable_path, &args, Some(state.clone()), process_name.clone()).await {
                                Ok(new_process) => {
                                    // Move current process to previous
                                    let old_process = {
                                        let mut current = current_process.lock().await;
                                        let old = current.take();
                                        *current = Some(new_process);
                                        old
                                    };
                                    
                                    if let Some(old_process) = old_process {
                                        // Replace previous_process safely and shutdown the replaced one
                                        let replaced = {
                                            let mut guard = previous_process.lock().await;
                                            guard.replace(old_process)
                                        };
                                        if let Some(prev) = replaced {
                                            let _ = prev.shutdown().await;
                                            eprintln!("ws-connector: Shutdown older previous {} process", process_name);
                                        }
                                        
                                        // Start cleanup task for previous process
                                        let previous_process_cleanup = previous_process.clone();
                                        let state_cleanup = state.clone();
                                        let process_name_cleanup = process_name.clone();
                                        tokio::spawn(async move {
                                            let cleanup_task_name = format!("{}-cleanup", process_name_cleanup);
                                            let _tt = TaskTrace::new(&cleanup_task_name, None, &state_cleanup).await;
                                            // Wait for previous process to become idle
                                            let mut cleanup_interval = tokio::time::interval(Duration::from_secs(5));
                                            for _ in 0..24 { // Wait up to 2 minutes
                                                cleanup_interval.tick().await;
                                                
                                                let should_cleanup = {
                                                    if let Some(ref process) = *previous_process_cleanup.lock().await {
                                                        process.is_idle().await
                                                    } else {
                                                        true
                                                    }
                                                };
                                                
                                                if should_cleanup {
                                                    if let Some(old_process) = previous_process_cleanup.lock().await.take() {
                                                        let r = old_process.shutdown().await;
                                                        eprintln!("ws-connector: Previous {} process clean up: {:?}", process_name_cleanup, r);
                                                    }
                                                    break;
                                                }
                                            }
                                            // Force shutdown if still present after timeout
                                            if let Some(old) = previous_process_cleanup.lock().await.take() {
                                                let _ = old.shutdown().await;
                                                eprintln!("ws-connector: Forced shutdown of previous {} process after timeout", process_name_cleanup);
                                            }
                                        });
                                    }
                                    
                                    *last_check.lock().await = modified;
                                }
                                Err(err) => {
                                    eprintln!("ws-connector: Failed to spawn new {} process: {}", process_name, err);
                                }
                            }
                        }
                    }
                }
            }
        });
    }

    pub async fn send_request(&self, request: TRequest) -> Result<TResponse, Box<dyn std::error::Error + Send + Sync>> {
        // Try the request up to 2 times (original attempt + 1 retry after restart)
        for attempt in 0..2 {
            match self.try_send_request(&request).await {
                Ok(response) => return Ok(response),
                Err(err) => {
                    // Check if this is a broken pipe error or the process has died
                    let should_restart = if let Some(io_err) = err.downcast_ref::<std::io::Error>() {
                        matches!(io_err.kind(), 
                                std::io::ErrorKind::BrokenPipe | 
                                std::io::ErrorKind::ConnectionReset |
                                std::io::ErrorKind::UnexpectedEof)
                    } else {
                        // Handle custom error messages for cases like channel closure
                        let error_str = err.to_string();
                        error_str.contains("Response channel closed")
                    };
                    
                    if should_restart && attempt == 0 {
                        eprintln!("ws-connector: {} process appears to have died ({}), attempting restart", self.process_name, err);
                        
                        // Attempt to restart the process
                        match self.restart_process().await {
                            Ok(_) => {
                                eprintln!("ws-connector: Successfully restarted {} process, retrying request", self.process_name);
                                // Continue to next iteration to retry the request
                                continue;
                            }
                            Err(restart_err) => {
                                eprintln!("ws-connector: Failed to restart {} process: {}", self.process_name, restart_err);
                                return Err(restart_err);
                            }
                        }
                    } else {
                        return Err(err);
                    }
                }
            }
        }
        
        Err(format!("Failed to send request to {} after restart attempt", self.process_name).into())
    }

    async fn try_send_request(&self, request: &TRequest) -> Result<TResponse, Box<dyn std::error::Error + Send + Sync>> {
        // Get shared references to process components to avoid holding the main lock during request
        let (stdin, active_requests) = {
            let guard = self.current_process.lock().await;
            if let Some(ref process) = *guard {
                (process.stdin.clone(), process.active_requests.clone())
            } else {
                return Err(format!("No active {} process", self.process_name).into());
            }
        };
        
        // Now send the request using the shared components without holding the main lock
        self.send_request_to_process(request, stdin, active_requests).await
    }
    
    async fn send_request_to_process(
        &self, 
        request: &TRequest, 
        stdin: Arc<Mutex<tokio::process::ChildStdin>>, 
        active_requests: Arc<Mutex<HashMap<String, mpsc::Sender<TResponse>>>>
    ) -> Result<TResponse, Box<dyn std::error::Error + Send + Sync>> {
        let request_id = request.get_id().to_string();
        
        // Create a channel for this request
        let (tx, mut rx) = mpsc::channel(1);
        
        // Track the request with max in-flight check
        {
            let mut active_requests_guard = active_requests.lock().await;
            if active_requests_guard.len() >= MAX_IN_FLIGHT_REQUESTS {
                return Err(format!("Too many concurrent in-flight requests ({}/{})", active_requests_guard.len(), MAX_IN_FLIGHT_REQUESTS).into());
            }
            active_requests_guard.insert(request_id.clone(), tx);
        }
        
        // Create guard that ensures cleanup on drop (cancellation safety)
        let _guard = RequestGuard::new(active_requests.clone(), request_id.clone());
        
        // Send the request with timeout protection
        let json = serde_json::to_string(request)?;
        {
            use tokio::time::timeout;
            let write_fut = async {
                let mut stdin = stdin.lock().await;
                stdin.write_all(json.as_bytes()).await?;
                stdin.write_all(b"\n").await?;
                stdin.flush().await?;
                Ok::<(), std::io::Error>(())
            };
            match timeout(Duration::from_secs(5), write_fut).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => return Err(e.into()),
                Err(_) => {
                    // Treat as write timeout: restart process
                    return Err("timeout writing to subprocess stdin".into());
                }
            }
        }
        
        let response = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await;
        
        // Note: No need to manually remove from active_requests - the guard will handle it
        // when this function exits (either normally or via cancellation)

        match response {
            Ok(Some(response)) => {
                Ok(response)
            },
            Ok(None) => {
                Err(format!("ws-connector: response channel for request {}, closed unexpectedly", request_id).into())
            },
            Err(err) => {
                Err(format!("ws-connector: timeout waiting for request {} response: {}", request_id, err).into())
            },
        }
    }

    /// Send a ping request to check process health and record timestamp if successful
    pub async fn ping_process(&self, ping_request: TRequest) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> 
    where
        TResponse: PingResponse,
    {
        match tokio::time::timeout(
            Duration::from_secs(10), 
            self.try_send_request(&ping_request)
        ).await {
            Ok(Ok(_response)) => {
                *self.last_successful_ping.lock().await = SystemTime::now();
                // eprintln!("ws-connector: {} health check successful - timestamp updated", self.process_name);
                Ok(true)
                // if response.is_successful() {
                //     *self.last_successful_ping.lock().await = SystemTime::now();
                //     Ok(true)
                // } else {
                //     Ok(false)
                // }
            }
            Ok(Err(_)) => {
                eprintln!("ws-connector: {} health check failed - process unresponsive", self.process_name);
                Ok(false)
            },
            Err(err) => { // Timeout
                eprintln!("ws-connector: {} health check error: {}", self.process_name, err);
                Ok(false)
            },
        }
    }

    /// Check if the process needs to be restarted based on ping timestamp
    pub async fn needs_restart_due_to_ping_timeout(&self) -> bool {
        let last_ping = *self.last_successful_ping.lock().await;
        let elapsed = SystemTime::now()
            .duration_since(last_ping)
            .unwrap_or(Duration::from_secs(u64::MAX))
            .as_secs();
        
        elapsed > self.ping_timeout_seconds
    }

    async fn restart_process(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        eprintln!("ws-connector: Restarting {} process...", self.process_name);
        
        // Kill the current process if it exists and clean up pending requests
        {
            let mut current_process = self.current_process.lock().await;
            if let Some(old_process) = current_process.take() {
                old_process.abort_pending().await;
                let _ = old_process.shutdown().await;
            }
        }
        
        // Spawn a new process
        let new_process = SubProcess::spawn(&self.executable_path, &self.args, Some(self.state.clone()), self.process_name.clone()).await?;
        
        // Update the current process and reset ping timestamp
        *self.current_process.lock().await = Some(new_process);
        *self.last_successful_ping.lock().await = SystemTime::now();
        
        eprintln!("ws-connector: {} process restarted successfully", self.process_name);
        Ok(())
    }
}
