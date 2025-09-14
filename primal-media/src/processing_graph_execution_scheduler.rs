use std::sync::Arc;

use log::{info, warn};
use tokio::time::{self, Duration};

use crate::{processing_graph, AppState};

const TASK_NAMES: &[&str] = &[
    // "import_media_fast_pn_2",
    "import_media_fast_pn",
    // "block_media",
    // "purge_media_",
    // "import_upload_3",
    "import_media_pn",
    "import_preview_pn",
    "import_media_hls_pn",
    "import_text_event_pn",
];

pub async fn task_execute(state: Arc<AppState>) {
    let _ntasks = state.config.tasks.ntasks as usize;
    let _limit = state.config.tasks.limit;
    let max_concurrent = state.config.tasks.max_concurrent_per_name;

    for name in TASK_NAMES {
        let name_str = name.to_string();

        // Collect finished handles and check running count
        let finished_handles = {
            let mut tasks_map = state.tasks.lock();

            // Get or create the task list for this name
            let task_list = tasks_map.entry(name_str.clone()).or_insert_with(Vec::new);

            // Find finished tasks and collect them
            let mut finished = Vec::new();
            let mut i = 0;
            while i < task_list.len() {
                if task_list[i].is_finished() {
                    finished.push(task_list.swap_remove(i));
                } else {
                    i += 1;
                }
            }

            finished
        };

        // Await finished tasks outside the lock
        for handle in finished_handles {
            match handle.await {
                Ok(Ok(rs)) => {
                    let executed = rs.iter().filter(|(_, r)| r.is_ok()).count();
                    let failed = rs.len() - executed;
                    if executed + failed > 0 {
                        info!("task_execute | {} executed={} failed={}", name_str, executed, failed);
                    }
                }
                Ok(Err(e)) => warn!("task {} error: {}", name_str, e),
                Err(e) => warn!("task {} join error: {}", name_str, e),
            }
        }

        // Check if we can spawn more tasks
        loop {
            let running_count = {
                let tasks_map = state.tasks.lock();
                tasks_map.get(&name_str).map(|v| v.len()).unwrap_or(0)
            };

            if running_count >= max_concurrent {
                break;
            }

            // Spawn new task (outside of lock)
            let state_clone = state.clone();
            let name_str_clone = name_str.clone();
            let handle = processing_graph::execute_delayed_node(&state_clone, &name_str_clone).await;

            if let Some(handle) = handle {
                // Reacquire lock to add the handle
                let mut tasks_map = state.tasks.lock();
                let task_list = tasks_map.entry(name_str.clone()).or_insert_with(Vec::new);
                task_list.push(handle);
                let new_count = task_list.len();
                drop(tasks_map);
                info!("task_execute | {} spawned new task (running: {}/{})", name_str, new_count, max_concurrent);
            } else {
                // No more pending tasks available
                break;
            }
        }
    }
}

pub async fn run_scheduler_loop(state: Arc<AppState>) -> anyhow::Result<()> {
    for name in TASK_NAMES {
        let result = sqlx::query!("
            update processing_nodes set started_at = null 
            where created_at >= now() - interval '2d' 
              and func = $1 
              and started_at is not null 
              and finished_at is null
            ", &name).execute(&state.pool).await?;
        let updated_rows_count = result.rows_affected();
        info!("scheduler: reset {} stuck tasks for {}", updated_rows_count, name);
    }

    let period = state.config.scheduler.period_ms;
    let mut interval = time::interval(Duration::from_millis(period));
    info!("scheduler: starting with period={}ms", period);
    loop {
        interval.tick().await;
        let s = state.clone();
        task_execute(s).await;
    }
}
