use anyhow::Context;
use primal_media_macros::procnode;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::time::Duration;

// AI Service types and functions

#[derive(Debug, Serialize)]
struct TextEmbeddingRequest {
    model: String,
    keep_alive: String,
    prompt: String,
}

#[derive(Debug, Deserialize)]
struct TextEmbeddingResponse {
    embedding: Vec<f32>,
}

#[derive(Debug, Serialize, Deserialize)]
struct TextQueryMessage {
    role: String,
    content: String,
}

#[derive(Debug, Serialize)]
struct TextQueryRequest {
    model: String,
    keep_alive: String,
    options: TextQueryOptions,
    stream: bool,
    messages: Vec<TextQueryMessage>,
}

#[derive(Debug, Serialize)]
struct TextQueryOptions {
    num_predict: u32,
}

#[derive(Debug, Deserialize)]
struct TextQueryResponse {
    message: TextQueryMessage,
}

/// Call ollama embeddings API to get text embeddings
async fn text_features(
    ai_host: &str,
    text: &str,
    timeout_secs: u64,
) -> anyhow::Result<Vec<f32>> {
    let endpoint = format!("http://{}:11434/api/embeddings", ai_host);
    let model = "nomic-embed-text";

    let req = TextEmbeddingRequest {
        model: model.to_string(),
        keep_alive: "180m".to_string(),
        prompt: text.to_string(),
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .build()?;

    let resp = client
        .post(&endpoint)
        .header("Content-Type", "application/json")
        .json(&req)
        .send()
        .await
        .context("Failed to call text_features API")?;

    let status = resp.status();
    let body = resp.text().await.context("Failed to read response body")?;

    if !status.is_success() {
        anyhow::bail!(
            "Ollama embeddings API returned status {}: {}",
            status, body
        );
    }

    serde_json::from_str::<TextEmbeddingResponse>(&body)
        .context(format!(
            "Failed to parse text_features response. Status: {}, Body: {}",
            status, body
        ))
        .and_then(|data| Ok(data.embedding))
}

/// Call ollama chat API for text analysis
async fn text_query(
    ai_host: &str,
    query: &str,
    num_predict: u32,
    timeout_secs: u64,
    model: Option<&str>,
) -> anyhow::Result<String> {
    let endpoint = format!("http://{}:11434/api/chat", ai_host);
    let model = model.unwrap_or("llama3.1");

    let req = TextQueryRequest {
        model: model.to_string(),
        keep_alive: "180m".to_string(),
        options: TextQueryOptions { num_predict },
        stream: false,
        messages: vec![TextQueryMessage {
            role: "user".to_string(),
            content: query.to_string(),
        }],
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .build()?;

    let resp = client
        .post(&endpoint)
        .header("Content-Type", "application/json")
        .json(&req)
        .send()
        .await
        .context("Failed to call text_query API")?;

    let status = resp.status();
    let body = resp.text().await.context("Failed to read response body")?;

    if !status.is_success() {
        anyhow::bail!(
            "Ollama chat API returned status {}: {}",
            status, body
        );
    }

    serde_json::from_str::<TextQueryResponse>(&body)
        .context(format!(
            "Failed to parse text_query response. Status: {}, Body: {}",
            status, body
        ))
        .and_then(|data| Ok(data.message.content))
}

// Text processing functions

fn clean_text(text: &str) -> String {
    // Remove nostr mentions, URLs, and hashtags
    let mention_re = Regex::new(r"(nostr:)?nostr1[a-z0-9]+").unwrap();
    let url_re = Regex::new(r"https?://[^\s]+").unwrap();
    let hashtag_re = Regex::new(r"#[^\s]+").unwrap();

    let mut cleaned = mention_re.replace_all(text, " ").to_string();
    cleaned = url_re.replace_all(&cleaned, " ").to_string();
    cleaned = hashtag_re.replace_all(&cleaned, " ").to_string();

    cleaned
}

fn first_word(s: &str) -> Option<String> {
    s.split_whitespace()
        .next()
        .map(|w| w.trim().to_lowercase())
}

fn select_word<'a>(s: &'a str, options: &[&str]) -> Option<String> {
    for word in s.split_whitespace() {
        let word_lower = word.to_lowercase();
        if options.contains(&word_lower.as_str()) {
            return Some(word_lower);
        }
    }
    None
}

#[derive(Debug, Serialize, Deserialize)]
struct TextMetadata {
    algo: String,
    model: String,
    tstart: i64,
    dt: f64,
    clean_text: String,
    lang: Option<String>,
    sentiment: Option<String>,
    categories_unparsed: String,
    categories: Vec<String>,
}

/// Analyze text metadata using LLM
async fn analyze_text_metadata(
    ai_host: &str,
    text: &str,
    timeout_secs: u64,
) -> anyhow::Result<TextMetadata> {
    let model = &"llama3.1";

    let tstart = chrono::Utc::now().timestamp();
    let start_time = std::time::Instant::now();

    // Clean the text
    let cleaned = clean_text(text);
    let text_sample = if cleaned.chars().count() > 300 {
        cleaned.chars().take(300).collect::<String>()
    } else {
        cleaned.clone()
    };
    let text_sample = text_sample.as_str();

    // Get language
    let lang_query = format!(
        "````\n{}\n````\nin what language is this text written in? answer with just one word.",
        text_sample
    );
    let lang_response = text_query(ai_host, &lang_query, 50, timeout_secs, Some(model)).await?;
    let lang = first_word(&lang_response.to_lowercase());

    // Get sentiment
    let sentiment_query = format!(
        "````\n{}\n````\nis sentiment of this text positive, neutral, negative? answer with just one word.",
        text_sample
    );
    let sentiment_response = text_query(ai_host, &sentiment_query, 50, timeout_secs, Some(model)).await?;
    let sentiment = select_word(
        &sentiment_response.to_lowercase(),
        &["positive", "neutral", "negative"],
    );

    // Get categories
    let categories_list = vec![
        "art",
        "bitcoin",
        "finance",
        "food",
        "fun and memes",
        "gaming",
        "health and fitness",
        "human rights",
        "music",
        "news",
        "nostr",
        "philosophy",
        "photography",
        "podcasts",
        "primal",
        "sports",
        "tech",
        "travel",
    ];
    let categories_str = categories_list
        .iter()
        .map(|c| format!("`{}`", c))
        .collect::<Vec<_>>()
        .join(", ");
    let categories_query = format!(
        "````\n{}\n````\nin which categories would you classify this text? \
         possible categories are {}. \
         answer with list of categories. \
         one category name from possible categories per line. \
         each line starts with -",
        text_sample, categories_str
    );
    let categories_unparsed = text_query(ai_host, &categories_query, 500, timeout_secs, Some(model)).await?;

    // Parse categories
    let mut categories = Vec::new();
    for line in categories_unparsed.lines() {
        let cleaned_line = line.trim().trim_start_matches('-').trim();
        let normalized = cleaned_line.replace(' ', "-");
        if categories_list.contains(&cleaned_line) {
            categories.push(normalized);
        }
    }

    let dt = start_time.elapsed().as_secs_f64();

    Ok(TextMetadata {
        algo: "10".to_string(),
        model: "llama3.1".to_string(),
        tstart,
        dt,
        clean_text: text_sample.to_string(),
        lang,
        sentiment,
        categories_unparsed,
        categories,
    })
}

/// Import and analyze a text note event for embeddings and metadata
///
/// This function implements the logic from ext_event_batch in media_analysis.jl:
/// - Fetches the event by event_id
/// - Extracts text embeddings using "nomic-embed-text" model
/// - Analyzes and updates text metadata with algo "10"
/// - Stores results in event_embedding and text_metadata tables
#[procnode(module = "PrimalServer.DB", func = "import_text_event_pn")]
pub async fn import_text_event_pn(
    state: &AppState,
    event_id_hex: &String,
) -> anyhow::Result<serde_json::Value> {
    let event_id_bytes =
        hex::decode(event_id_hex).context("Failed to decode event_id hex string")?;
    if event_id_bytes.len() != 32 {
        anyhow::bail!("event_id must be 32 bytes");
    }

    // Fetch event from database
    let row = sqlx::query!(
        r#"
        select content, kind from events where id = $1 limit 1
        "#,
        &event_id_bytes
    )
    .fetch_optional(&state.pool)
    .await
    .context("Failed to fetch event from database")?;

    let row = match row {
        Some(r) => r,
        None => anyhow::bail!("Event not found: {}", event_id_hex),
    };

    let content = row.content.unwrap_or_default();
    let kind = row.kind.unwrap_or(0);

    // Only process text notes (kind 1) and long-form content (kind 30023)
    if kind != 1 && kind != 30023 {
        anyhow::bail!("Event kind {} not supported for text analysis", kind);
    }

    let ai_host = &state.config.media.ai_host;
    let timeout_secs = state.config.media.ai_timeout_secs;

    // Extract summary (first 500 chars)
    let summary = if content.chars().count() > 500 {
        content.chars().take(500).collect::<String>()
    } else {
        content.clone()
    };
    let summary = summary.as_str();

    // Get text embeddings
    let tstart_emb = chrono::Utc::now().timestamp();
    let start_time_emb = std::time::Instant::now();
    let embedding = text_features(ai_host, summary, timeout_secs)
        .await
        .context("Failed to extract text features")?;
    let dt_emb = start_time_emb.elapsed().as_secs_f64();

    // Store event embedding
    let model_emb = "nomic-embed-text";
    let md_emb = json!({
        "algo": "9",
        "model": model_emb,
        "size": embedding.len(),
        "tstart": tstart_emb,
        "dt": dt_emb
    });
    sqlx::query!(
        r#"
        insert into event_embedding (eid, model, md, emb, t)
        values ($1, $2, $3, $4::float4[]::vector, now())
        on conflict (eid, model) do update set
            md = event_embedding.md || excluded.md,
            emb = excluded.emb,
            t = excluded.t
        "#,
        &event_id_bytes,
        model_emb,
        &md_emb,
        &embedding
    )
    .execute(&state.pool)
    .await
    .context("Failed to insert event_embedding")?;

    // Analyze text metadata
    let text_md = analyze_text_metadata(ai_host, summary, timeout_secs)
        .await
        .context("Failed to analyze text metadata")?;

    // Calculate sha256 of text
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    let text_sha256: Vec<u8> = hasher.finalize().to_vec();

    // Store text metadata
    let md_json = serde_json::to_value(&text_md).context("Failed to serialize text metadata")?;

    sqlx::query!(
        r#"
        insert into text_metadata (sha256, model, md, t, text, event_id)
        values ($1, $2, $3, now(), $4, $5)
        on conflict (sha256, model) do update set
            md = text_metadata.md || excluded.md,
            t = excluded.t,
            text = excluded.text,
            event_id = excluded.event_id
        "#,
        &text_sha256,
        &text_md.model,
        &md_json,
        &content,
        &event_id_bytes
    )
    .execute(&state.pool)
    .await
    .context("Failed to insert text_metadata")?;

    // Build result
    Ok(json!({
        "event_id": event_id_hex,
        "content_length": content.len(),
        "embedding_size": embedding.len(),
        "metadata": text_md
    }))
}
