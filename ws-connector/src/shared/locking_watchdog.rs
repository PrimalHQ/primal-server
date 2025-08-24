use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::Duration;
use crate::shared::task_dump::runtime_dump;
use crate::get_sys_time_in_secs;

#[derive(Clone)]
pub struct LockingWatchdog {
    t_last_locking: Arc<Mutex<u64>>,
    timeout_seconds: u64,
    output_directory: String,
}

impl LockingWatchdog {
    pub fn new(timeout_seconds: u64, output_directory: String) -> Self {
        Self {
            t_last_locking: Arc::new(Mutex::new(get_sys_time_in_secs())),
            timeout_seconds,
            output_directory,
        }
    }

    pub async fn start(&self, state: Arc<Mutex<crate::State>>, process_name: &str) {
        self.start_watchdog_task(state.clone(), process_name).await;
        self.start_helper_task(state.clone()).await;
    }

    async fn start_watchdog_task(&self, state: Arc<Mutex<crate::State>>, process_name: &str) {
        let t_last_locking = self.t_last_locking.clone();
        let timeout_seconds = self.timeout_seconds;
        let process_name = process_name.to_string();
        let output_directory = self.output_directory.clone();

        tokio::task::spawn(async move {
            let _tt = crate::TaskTrace::new("locking-watchdog", None, &state).await;
            let mut interval = tokio::time::interval(Duration::from_millis(1000));
            loop {
                interval.tick().await;
                let dt = get_sys_time_in_secs() - *t_last_locking.lock().await;
                if dt >= timeout_seconds {
                    if let Err(e) = tokio::fs::create_dir_all(&output_directory).await {
                        eprintln!("Failed to create directory {}: {}", &output_directory, e);
                    } else {
                        let timestamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
                        let filename = format!("{}/locking-watchdog-tasks-{}-{}.txt", output_directory, process_name, timestamp);
                        eprintln!("{}: locking watchdog: no locking for {} seconds, dumping runtime info ({}), exiting", 
                            process_name, dt, filename);
                        runtime_dump(filename.as_str()).await;
                    }
                    std::process::exit(1);
                }
            }
        });
    }

    async fn start_helper_task(&self, state: Arc<Mutex<crate::State>>) {
        let t_last_locking = self.t_last_locking.clone();
        
        tokio::task::spawn(async move {
            let _tt = crate::TaskTrace::new("locking-watchdog-helper", None, &state).await;
            let mut interval = tokio::time::interval(Duration::from_millis(1000));
            loop {
                let _ = state.lock().await;
                *t_last_locking.lock().await = get_sys_time_in_secs();
                interval.tick().await;
            }
        });
    }
}
