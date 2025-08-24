use tokio::runtime::Handle;
use tokio::time::Duration;
// use std::path::Path;

pub async fn runtime_dump(process_name: &str) {
    let handle = Handle::current();

    let mut s = String::new();
    if let Ok(dump) = tokio::time::timeout(Duration::from_secs(5), handle.dump()).await {
        for task in dump.tasks().iter() {
            let trace = task.trace();
            let tokio_task_id = crate::shared::parse_tokio_task_id(task.id());
            s.push_str(format!("TASK {tokio_task_id}:\n").as_str());
            s.push_str(format!("{trace}\n\n").as_str());
        }
    }

    eprintln!("task dump for {}:", process_name);
    eprintln!("{}", s);
}

