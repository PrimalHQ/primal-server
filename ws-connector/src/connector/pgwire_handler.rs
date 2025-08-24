use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::{timeout, Duration};
use tokio::runtime::Handle;
use async_trait::async_trait;

use pgwire::api::auth::noop::NoopStartupHandler;
use pgwire::api::copy::NoopCopyHandler;
use pgwire::api::query::{PlaceholderExtendedQueryHandler, SimpleQueryHandler};
use pgwire::api::results::{DataRowEncoder, FieldFormat, FieldInfo, QueryResponse, Response};
use pgwire::api::{ClientInfo, PgWireHandlerFactory, Type};
use pgwire::error::PgWireResult;

use crate::shared::State;

pub struct WSConnProcessor {
    state: Arc<Mutex<State>>,
}

impl WSConnProcessor {
    pub fn new(state: Arc<Mutex<State>>) -> Self {
        Self { state }
    }
}

#[async_trait]
impl SimpleQueryHandler for WSConnProcessor {
    async fn do_query<'a, C>(
        &self,
        _client: &mut C,
        query: &'a str,
    ) -> PgWireResult<Vec<Response<'a>>>
    where
        C: ClientInfo + Unpin + Send + Sync,
    {
        eprintln!("{:?}", query);

        if query == "select * from tasks;" {
            let fields = vec![
                FieldInfo::new(
                    "tokio_task_id".to_string(),
                    None,
                    None,
                    Type::UNKNOWN,
                    FieldFormat::Text,
                ),
                FieldInfo::new(
                    "task_id".to_string(),
                    None,
                    None,
                    Type::UNKNOWN,
                    FieldFormat::Text,
                ),
                FieldInfo::new(
                    "trace".to_string(),
                    None,
                    None,
                    Type::UNKNOWN,
                    FieldFormat::Text,
                ),
            ];
            let fields = Arc::new(fields);

            let mut results = Vec::new();

            let handle = Handle::current();
            if let Ok(dump) = timeout(Duration::from_secs(5), handle.dump()).await {
                for task in dump.tasks().iter() {
                    let trace = task.trace();
                    let tokio_task_id = crate::shared::parse_tokio_task_id(task.id());
                    let state = self.state.lock().await;
                    let task_id = state.shared.tasks.get(&tokio_task_id).map_or_else(|| -1, |x| *x);
                    
                    let mut encoder = DataRowEncoder::new(fields.clone());
                    encoder.encode_field(&Some(tokio_task_id.to_string()))?;
                    encoder.encode_field(&Some(task_id.to_string()))?;
                    encoder.encode_field(&Some(trace.to_string()))?;
                    results.push(encoder.finish());
                }
            }
            
            use futures_util::stream;
            let stream = stream::iter(results.into_iter());
            Ok(vec![Response::Query(QueryResponse::new(fields, stream))])
        } else {
            Ok(vec![])
        }
    }
}

pub struct WSConnHandlerFactory {
    processor: Arc<WSConnProcessor>,
}

impl WSConnHandlerFactory {
    pub fn new(state: Arc<Mutex<State>>) -> Self {
        Self {
            processor: Arc::new(WSConnProcessor::new(state)),
        }
    }
}

impl PgWireHandlerFactory for WSConnHandlerFactory {
    type StartupHandler = NoopStartupHandler;
    type SimpleQueryHandler = WSConnProcessor;
    type ExtendedQueryHandler = PlaceholderExtendedQueryHandler;
    type CopyHandler = NoopCopyHandler;

    fn simple_query_handler(&self) -> Arc<Self::SimpleQueryHandler> {
        self.processor.clone()
    }

    fn extended_query_handler(&self) -> Arc<Self::ExtendedQueryHandler> {
        Arc::new(PlaceholderExtendedQueryHandler)
    }

    fn startup_handler(&self) -> Arc<Self::StartupHandler> {
        Arc::new(NoopStartupHandler)
    }

    fn copy_handler(&self) -> Arc<Self::CopyHandler> {
        Arc::new(NoopCopyHandler)
    }
}
