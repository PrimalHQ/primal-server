use std::time::Duration;
use tokio::process::{Command, Child};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use futures_util::SinkExt;
use serde_json::{json, Value};
use ws_connector::shared::utils::{send_request_and_get_response, compare_backend_api_response};
use sqlx::{Pool, Postgres};

const TEST_PUBKEY: &str = "88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079";
const TEST_EVENT_ID: &str = "fe687531a6654c7235655469862290ce350d492a98ec49c35af2e35073caf77b";
const TEST_CLIENT: &str = "test-client";
const LIVE_FEED_KIND: i64 = 30311;
const LIVE_FEED_IDENTIFIER: &str = "1752870546";

// Database helper functions
async fn get_database_pool() -> Result<Pool<Postgres>, Box<dyn std::error::Error + Send + Sync>> {
    use sqlx::pool::PoolOptions;
    
    let database_url = "postgresql://pr@127.0.0.1:54017/primal1?application_name=integration_tests";
    let pool = PoolOptions::new()
        .max_connections(2)
        .min_connections(1)
        .connect(database_url).await?;
    Ok(pool)
}

async fn wait_for_event_import(event_id: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pool = get_database_pool().await?;
    let max_attempts = 50;
    let poll_interval = Duration::from_millis(200);

    for attempt in 0..max_attempts {
        let query = sqlx::query_scalar!(
            "SELECT EXISTS(SELECT 1 FROM events WHERE id = DECODE($1, 'hex'))",
            event_id
        );

        let event_exists = query.fetch_one(&pool).await?;

        if let Some(true) = event_exists {
            eprintln!("Event {} imported after {} attempts", event_id, attempt + 1);
            return Ok(());
        }

        if attempt < max_attempts - 1 {
            tokio::time::sleep(poll_interval).await;
        }
    }

    Err(format!("Event {} not imported within {} attempts", event_id, max_attempts).into())
}

async fn find_available_port() -> Result<u16, Box<dyn std::error::Error + Send + Sync>> {
    use tokio::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

fn count_event_kinds(responses: &[Value]) -> std::collections::HashMap<i64, usize> {
    let mut kind_counts: std::collections::HashMap<i64, usize> = std::collections::HashMap::new();
    
    for response in responses {
        if let Value::Array(arr) = response {
            if arr.len() >= 3 && arr[0].as_str() == Some("EVENT") {
                if let Some(event) = arr[2].as_object() {
                    if let Some(kind_value) = event.get("kind") {
                        if let Some(kind) = kind_value.as_i64() {
                            *kind_counts.entry(kind).or_insert(0) += 1;
                        }
                    }
                }
            }
        }
    }
    
    kind_counts
}

fn print_event_kind_counts(responses: &[Value]) {
    let kind_counts = count_event_kinds(responses);
    
    if !kind_counts.is_empty() {
        eprintln!("Event kind counts:");
        let mut kind_counts: Vec<(i64, usize)> = kind_counts.into_iter().collect();
        kind_counts.sort_by(|a, b| a.0.cmp(&b.0));
        for (kind, count) in kind_counts {
            eprintln!("  Kind {}: {} events", kind, count);
        }
    }
}

fn assert_expected_event_kinds(responses: &[Value], expected_kinds: &[i64]) {
    let kind_counts = count_event_kinds(responses);
    for kind in expected_kinds.iter() {
        assert!(kind_counts.contains_key(kind), "Should contain event of kind {}", kind);
    }
}


struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        // Terminate the process regardless of outcome
        if let Some(pid) = self.0.id() {
            unsafe { libc::kill(pid as i32, libc::SIGKILL); }
        } else {
            let _ = self.0.kill();
        }
    }
}

async fn run_single_test<F, Fut>(test_name: &str, test_fn: F) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    F: FnOnce(tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>) -> Fut,
    Fut: std::future::Future<Output = Result<(), Box<dyn std::error::Error + Send + Sync>>>,
{
    eprintln!("\n=== Running {} ===", test_name);
    
    // Create a unique directory for this test
    let dir_name = format!("test-content-moderation-{}", test_name);
    std::fs::create_dir_all(&dir_name)?;
    // Write configuration files into that directory
    std::fs::write(format!("{}/default-settings.json", dir_name), r#"{\"theme\": \"dark\"}"#)?;
    std::fs::write(format!("{}/app-releases.json", dir_name), r#"{\"version\": \"1.0.0\"}"#)?;
    
    // Build the binary if necessary
    let build_output = Command::new("cargo").args(&["build", "--release", "--all-targets"]).output().await?;
    if !build_output.status.success() {
        return Err("Build failed".into());
    }
    
    // Start the connector process with the test-specific config directory
    let port = find_available_port().await?;
    let mut process = ChildGuard(Command::new("./target/release/ws-connector")
        .args(&[
            "--servername", "test-server",
            "--content-moderation-root", dir_name.as_str(),
            "run",
            "--port", &port.to_string(),
            "--backend-addr", "ws://127.0.0.1:8817",
        ])
        .spawn()?);
    
    // Wait until the server is ready
    let mut attempts = 0;
    let max_attempts = 50;
    loop {
        match tokio_tungstenite::connect_async(&format!("ws://127.0.0.1:{}", port)).await {
            Ok(_) => break,
            Err(_) if attempts < max_attempts => {
                attempts += 1;
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
            Err(e) => return Err(format!("Server failed to start within 10 seconds: {}", e).into()),
        }
    }
    
    // Ensure the process hasn't exited prematurely
    if let Some(status) = process.0.try_wait()? {
        return Err(format!("Process exited early: {}", status).into());
    }
    
    // Run the test logic against the running server
    let result = async {
        let (ws_stream, _) = connect_async(&format!("ws://127.0.0.1:{}", port)).await?;
        test_fn(ws_stream).await
    }.await;

    drop(process); // Ensure the process is killed when the test completes
    
    // Clean up the test directory
    let _ = std::fs::remove_dir_all(&dir_name);
    
    eprintln!("=== Finished {} ===\n", test_name);
    
    result
}


#[tokio::test]
async fn test_set_primal_protocol() {
    run_single_test("set_primal_protocol", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_protocol", "set_primal_protocol", &json!({ "compression": "zlib" })).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        
        let has_eose = responses.iter().any(|r| {
            if let Value::Array(arr) = r {
                arr.len() >= 2 && arr[0].as_str() == Some("EOSE")
            } else { false }
        });
        
        assert!(has_eose, "Should receive EOSE");
        
        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_protocol", "set_primal_protocol", &json!({ "compression": "zlib" }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_get_default_app_settings() {
    run_single_test("get_default_app_settings", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_settings", "get_default_app_settings", &json!({"client": TEST_CLIENT})).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[10000103]);
        
        let has_valid_response = responses.iter().any(|r| {
            if let Value::Array(arr) = r {
                arr.len() >= 2 && matches!(arr[0].as_str(), Some("EVENT") | Some("NOTICE") | Some("EOSE"))
            } else { false }
        });
        
        assert!(has_valid_response, "Should receive valid response");
        
        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_settings", "get_default_app_settings", &json!({"client": TEST_CLIENT}).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test] 
async fn test_get_app_releases() {
    run_single_test("get_app_releases", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_releases", "get_app_releases", &json!({})).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[10000138]);
        
        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_releases", "get_app_releases", &json!({}).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_thread_view() {
    run_single_test("thread_view", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_thread", "thread_view", &json!({
            "event_id": TEST_EVENT_ID,
            "limit": 5,
            "user_pubkey": TEST_PUBKEY
        })).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[0, 1, 10063, 10000100, 10000108, 10000113, 10000115, 10000119, 10000141, 10000158, 10000168, 10000169]);
        
        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_thread", "thread_view", &json!({
            "event_id": TEST_EVENT_ID,
            "limit": 5,
            "user_pubkey": TEST_PUBKEY
        }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_feed() {
    run_single_test("feed", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_feed", "feed", &json!({
            "pubkey": TEST_PUBKEY,
            "user_pubkey": TEST_PUBKEY,
            "limit": 3,
            "notes": "authored"
        })).await?;

        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[0, 1, 10063, 30311, 10000100, 10000108, 10000113, 10000119, 10000141, 10000158, 10000168, 10000169]);
        
        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_feed", "feed", &json!({
            "pubkey": TEST_PUBKEY,
            "user_pubkey": TEST_PUBKEY,
            "limit": 3,
            "notes": "authored"
        }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_live_feed() {
    run_single_test("live_feed", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_live", "live_feed", &json!({
            "kind": LIVE_FEED_KIND,
            "pubkey": TEST_PUBKEY,
            "identifier": LIVE_FEED_IDENTIFIER,
            "user_pubkey": TEST_PUBKEY
        })).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[7, 1311, 10000176]);
        
        // // Compare backend responses to ensure no differences
        // let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_live", "live_feed", &json!({
        //     "kind": LIVE_FEED_KIND,
        //     "pubkey": TEST_PUBKEY,
        //     "identifier": LIVE_FEED_IDENTIFIER,
        //     "user_pubkey": TEST_PUBKEY
        // }).to_string()).await?;
        // assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_user_infos() {
    run_single_test("user_infos", |mut ws_stream| async move {
        let responses = send_request_and_get_response(&mut ws_stream, "test_users", "user_infos", &json!({ "pubkeys": [TEST_PUBKEY] })).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should receive responses");
        assert_expected_event_kinds(&responses, &[0, 10063, 10000108, 10000119, 10000133, 10000158, 10000168, 10000169]);

        // Compare backend responses to ensure no differences
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_users", "user_infos", &json!({ "pubkeys": [TEST_PUBKEY] }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends: {:?}", diffs);

        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_invalid_request() {
    run_single_test("invalid_request", |mut ws_stream| async move {
        // Send invalid JSON
        ws_stream.send(Message::Text("invalid json".to_string())).await?;
        
        // Then send valid request
        let responses = send_request_and_get_response( &mut ws_stream, "test_valid", "get_app_releases", &json!({})).await?;
        
        print_event_kind_counts(&responses);
        
        assert!(!responses.is_empty(), "Should still work after invalid request");
        assert_expected_event_kinds(&responses, &[10000138]);
        
        Ok(())
    }).await.expect("Test failed");
}

#[tokio::test]
async fn test_compression_workflow() {
    run_single_test("compression", |mut ws_stream| async move {
        // First set compression protocol
        let compression_responses = send_request_and_get_response(&mut ws_stream, "test_compression", "set_primal_protocol", &json!({ "compression": "zlib" })).await?;
        
        assert!(!compression_responses.is_empty(), "Should receive compression protocol response");
        
        let has_eose = compression_responses.iter().any(|r| {
            if let Value::Array(arr) = r {
                arr.len() >= 2 && arr[0].as_str() == Some("EOSE")
            } else { false }
        });
        assert!(has_eose, "Should receive EOSE for compression protocol");
        
        // Compare backend responses for compression protocol setup
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_compression", "set_primal_protocol", &json!({ "compression": "zlib" }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends for compression setup: {:?}", diffs);
        
        // Now make a data request that should use compression
        let feed_responses = send_request_and_get_response(&mut ws_stream, "test_compressed_feed", "feed", &json!({
            "pubkey": TEST_PUBKEY,
            "user_pubkey": TEST_PUBKEY,
            "limit": 5,
            "notes": "authored"
        })).await?;
        
        eprintln!("Received {} responses from compressed feed request", feed_responses.len());
        
        assert!(!feed_responses.is_empty(), "Should receive compressed feed responses");
        
        // Verify we get proper event responses
        let event_count = feed_responses.iter().filter(|r| {
            if let Value::Array(arr) = r {
                arr.len() >= 2 && arr[0].as_str() == Some("EVENT")
            } else { false }
        }).count();
        
        eprintln!("Received {} EVENT messages", event_count);
        assert!(event_count > 0, "Should receive at least one EVENT message");
        
        // Compare backend responses for compressed feed request
        let diffs = compare_backend_api_response("ws://127.0.0.1:8817", "ws://127.0.0.1:9001", "test_compressed_feed", "feed", &json!({
            "pubkey": TEST_PUBKEY,
            "user_pubkey": TEST_PUBKEY,
            "limit": 5,
            "notes": "authored"
        }).to_string()).await?;
        assert!(diffs.is_empty(), "Should have no differences between backends for compressed feed: {:?}", diffs);
        
        Ok(())
    }).await.expect("Compression test failed");
}

async fn wait_for_mute_list_import(user_pubkey: &nostr_sdk::PublicKey, mute_pk: Option<&nostr_sdk::PublicKey>, event_id: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    wait_for_event_import(&event_id).await?;

    let pool = get_database_pool().await?;
    let user_pubkey_bytes = hex::decode(user_pubkey.to_hex())?;
    let max_attempts = 50;
    let poll_interval = Duration::from_millis(200);

    for attempt in 0..max_attempts {
        if let Some(muted_pk) = mute_pk {
            let muted_pubkey_bytes = hex::decode(muted_pk.to_hex())?;

            let is_hidden = sqlx::query_scalar!(
                "SELECT is_pubkey_hidden($1, 'content'::cmr_scope, $2)",
                user_pubkey_bytes,
                muted_pubkey_bytes
            ).fetch_one(&pool).await?;

            if let Some(true) = is_hidden {
                eprintln!("Mute list successfully updated after {} attempts", attempt + 1);
                return Ok(());
            }
        } else {
            eprintln!("Unmute event processed after {} attempts", attempt + 1);
            return Ok(());
        }

        if attempt < max_attempts - 1 {
            tokio::time::sleep(poll_interval).await;
        }
    }

    Err(format!("Mute list not updated within {} attempts", max_attempts).into())
}
    
async fn setup_mute_list(client: &nostr_sdk::Client, qauser_sk: &nostr_sdk::Keys, mute_pk: Option<&nostr_sdk::PublicKey>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use nostr_sdk::prelude::*;
    
    let mut mute_event = EventBuilder::new(Kind::MuteList, "");
    if let Some(pk) = mute_pk {
        mute_event = mute_event.tag(Tag::public_key(*pk));
    }
    
    let sent_event = client.send_event(&mute_event.sign(qauser_sk).await.unwrap()).await?;

    wait_for_mute_list_import(&qauser_sk.public_key(), mute_pk, &sent_event.id().to_hex()).await?;

    Ok(())
}

async fn create_and_send_live_event(client: &nostr_sdk::Client, sk: &nostr_sdk::Keys, content: &str) -> Result<nostr_sdk::Event, Box<dyn std::error::Error + Send + Sync>> {
    use nostr_sdk::prelude::*;
    
    let event = EventBuilder::new(Kind::LiveEventMessage, format!("{} at {}", content, chrono::Local::now().format("%Y-%m-%d %H:%M:%S")))
        .tag(Tag::coordinate(Coordinate::new(Kind::LiveEvent, PublicKey::parse(TEST_PUBKEY)?).identifier(LIVE_FEED_IDENTIFIER), None))
        .sign(sk).await.unwrap();
    
    client.send_event(&event).await?;
    
    wait_for_event_import(&event.id.to_hex()).await?;

    tokio::time::sleep(Duration::from_secs(5)).await;

    Ok(event)
}

async fn check_event_received(ws_stream: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, moderation_mode: &str, expected_event: &nostr_sdk::Event, should_receive: bool, content: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let responses = send_request_and_get_response(ws_stream, "test_live", "live_feed", &json!({
        "kind": LIVE_FEED_KIND,
        "pubkey": TEST_PUBKEY,
        "identifier": LIVE_FEED_IDENTIFIER,
        "user_pubkey": TEST_PUBKEY,
        "content_moderation_mode": moderation_mode,
    })).await?;

    let events = responses.iter().filter_map(response_to_event).collect::<Vec<_>>();
    dbg!(events.len());

    let received = events.iter().any(|e| e.id.to_hex() == expected_event.id.to_hex());
    
    if should_receive {
        assert!(received, "Should receive live event message that was sent from test user: {}", content);
    } else {
        assert!(!received, "Should NOT receive live event message that was sent from test user: {}", content);
    }
    
    Ok(())
}

#[tokio::test]
#[ignore]
async fn test_live_feed_content_moderation() {
    run_single_test("live_feed_content_moderation", |mut ws_stream| async move {
        use nostr_sdk::prelude::*;

        rustls::crypto::ring::default_provider().install_default().unwrap();

        let qauser_sk = Keys::parse(&std::fs::read_to_string("../../../qauser.nsec")?.trim()).unwrap();
        assert!(qauser_sk.public_key().to_hex() == TEST_PUBKEY, "QA user public key should match the test public key");

        const PRIVATE_KEY: &str = "5091363c16f8466901027c7c706a315ff0d5ccd85164a8713bb0ba1803dd9427"; // pubkey: 4bcc0a31e6f30b0d630bafb608ad5c2a60113c1360ec28706573722746ce45b0
        let sk = Keys::parse(PRIVATE_KEY)?;
        let pk = sk.public_key();
        let client = Client::new(sk.clone());
        client.add_relay("wss://relay.primal.net").await?;
        client.connect().await;

        // Test 1: Unmuted user with moderated mode - should receive message
        let content1 = "čekić check unmuted moderated";
        setup_mute_list(&client, &qauser_sk, None).await?;
        let event1 = create_and_send_live_event(&client, &sk, content1).await?;
        check_event_received(&mut ws_stream, "moderated", &event1, true, content1).await?;

        // Test 2: Muted user with moderated mode - should NOT receive message  
        let content2 = "čekić check muted moderated";
        setup_mute_list(&client, &qauser_sk, Some(&pk)).await?;
        let event2 = create_and_send_live_event(&client, &sk, content2).await?;
        check_event_received(&mut ws_stream, "moderated", &event2, false, content2).await?;
        
        // Test 3: Muted user with unmoderated mode - should receive message
        let content3 = "čekić check muted unmoderated";
        setup_mute_list(&client, &qauser_sk, Some(&pk)).await?;
        let event3 = create_and_send_live_event(&client, &sk, content3).await?;
        check_event_received(&mut ws_stream, "all", &event3, true, content3).await?;
        
        Ok(())
    }).await.expect("Content moderation test failed");
}

fn response_to_event(r: &Value) -> Option<primal_cache::Event> {
    if let Value::Array(arr) = r {
        if arr.len() >= 3 && arr[0].as_str() == Some("EVENT") {
            if let Some(event) = arr.get(2) {
                if let Ok(e) = serde_json::from_value::<primal_cache::Event>(event.clone()) {
                    return Some(e);
                }
            }
        }
    }
    None
}

