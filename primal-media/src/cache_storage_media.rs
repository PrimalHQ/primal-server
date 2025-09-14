use crate::{AppState, media, processing_graph};
use primal_media_macros::procnode;
use sha2::Digest;
use sqlx::PgPool;
use serde_json::{json, Value};

// Helper to generate all_variants JSON (equivalent to Main.Media.all_variants in Julia)
fn all_variants_json() -> Value {
    let sizes = ["original", "small", "medium", "large"];
    let mut variants = Vec::new();
    for size in sizes {
        for animated in [true, false] {
            variants.push(json!({
                "_ty": "Tuple",
                "_v": [
                    {"_ty": "Symbol", "_v": size},
                    animated
                ]
            }));
        }
    }
    json!({"_ty": "Vector", "_v": variants})
}

// Helpers to decode common wrappers
fn as_tuple(v: &Value) -> anyhow::Result<&Vec<Value>> {
    if let Value::Object(o) = v {
        if let Some(Value::String(ty)) = o.get("_ty") {
            if ty == "Tuple" {
                if let Some(Value::Array(a)) = o.get("_v") {
                    return Ok(a);
                }
            }
        }
    }
    anyhow::bail!("expected Tuple wrapper")
}

fn as_symbol(v: &Value) -> Option<String> {
    if let Value::Object(o) = v {
        if o.get("_ty") == Some(&Value::String("Symbol".into())) {
            return o.get("_v").and_then(|s| s.as_str()).map(|s| s.to_string());
        }
    }
    None
}

fn as_event_id_hex(v: &Value) -> Option<String> {
    if let Value::Object(o) = v {
        if o.get("_ty") == Some(&Value::String("EventId".into())) {
            return o.get("_v").and_then(|s| s.as_str()).map(|s| s.to_string());
        }
    }
    None
}

// Helper to check if URL is likely a video based on extension
fn is_video_url(url: &str) -> bool {
    let url_lower = url.to_lowercase();
    url_lower.ends_with(".mp4") || url_lower.ends_with(".mov") ||
    url_lower.ends_with(".webm") || url_lower.ends_with(".avi") ||
    url_lower.ends_with(".mkv") || url_lower.ends_with(".m4v") ||
    url_lower.ends_with(".flv") || url_lower.ends_with(".wmv")
}

pub async fn handler_import_media_pn(
    state: &AppState,
    id: &crate::processing_graph::NodeId,
    args: Value,
    kwargs: Value,
) -> anyhow::Result<Value> {
    log::debug!("handler_import_media_pn ENTRY - args: {}, kwargs: {}", args, kwargs);
    let a = as_tuple(&args)?;
    if a.len() < 3 { anyhow::bail!("invalid args length"); }
    let eid_hex = as_event_id_hex(&a[1]);
    let eid_opt = eid_hex.as_deref();
    let url = a[2].as_str().ok_or_else(|| anyhow::anyhow!("missing url"))?.to_string();

    // Extract variant_specs from args[3] if present (Julia passes this as 4th argument)
    let variant_specs_from_args = if a.len() >= 4 {
        Some(a[3].clone())
    } else {
        None
    };

    // Extract no_media_analysis flag from kwargs (defaults to false)
    let no_media_analysis = kwargs.get("no_media_analysis")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    log::debug!("Parsed args - eid_hex: {:?}, url: {}, no_media_analysis: {}, variant_specs provided: {}",
                eid_hex, url, no_media_analysis, variant_specs_from_args.is_some());

    // Set root-level Extra metadata fields (matches Julia E(; ...) at line 21)
    let mut extra_root = serde_json::Map::new();
    extra_root.insert("url".to_string(), json!(url));
    if let Some(eh) = eid_opt {
        extra_root.insert("eid".to_string(), json!(eh));
    }
    let _ = processing_graph::extra_merge(state, id, extra_root).await;

    // If eid present, check low_trust_user against event's pubkey
    if let Some(eh) = eid_opt {
        let id_bytes = hex::decode(eh)?;
        if let Some(row) = sqlx::query!("select pubkey from events where id = $1 limit 1", &id_bytes[..])
            .fetch_optional(&state.pool)
            .await? {
            if let Some(pubkey) = row.pubkey {
                if low_trust_user(&state.pool, &pubkey).await? {
                    let _ = processing_graph::extralog(state, id, json!({"step":"low_trust_user:block","eid":eh})).await;
                    return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"}));
                }
            } else {
                let _ = processing_graph::extralog(state, id, json!({"step":"low_trust_user:block","reason":"no_pubkey","eid":eh})).await;
                return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"}));
            }
        }
    }

    // For videos, use video-specific variant specs (only original/animated)
    // For other media, use variant specs from args or kwargs
    let mut modified_kwargs = kwargs.clone();

    // First, check if variant_specs were provided in args (highest priority)
    if let Some(ref vs) = variant_specs_from_args {
        log::debug!("Using variant_specs from args");
        modified_kwargs.as_object_mut().map(|o| {
            o.insert("variant_specs".to_string(), vs.clone());
        });
    } else if is_video_url(&url) && !kwargs.as_object().and_then(|o| o.get("variant_specs")).is_some() {
        // For videos without explicit variant_specs, use video-specific specs
        log::debug!("Detected video URL - using video-specific variant_specs");
        modified_kwargs.as_object_mut().map(|o| {
            o.insert("variant_specs".to_string(), json!({
                "_ty": "Vector",
                "_v": [
                    {
                        "_ty": "Tuple",
                        "_v": [
                            {"_ty": "Symbol", "_v": "original"},
                            true
                        ]
                    }
                ]
            }));
        });
    }
    // Otherwise, kwargs may already contain variant_specs, or defaults will be used

    // Get variants via Media.media_variants_pn
    // Construct args tuple: [est, url] (new signature expects just url after est)
    log::debug!("Calling media_variants_pn");
    let media_variants_args = processing_graph::tuple_from(vec![
        serde_json::Value::Null, // est placeholder
        serde_json::Value::String(url.clone()),
    ]);
    let (_nid_mv, vr) = processing_graph::pn_immediate(
        state,
        "PrimalServer.Media",
        "media_variants_pn",
        &media_variants_args,
        &modified_kwargs,
    ).await?;
    log::debug!("media_variants_pn returned: {}", vr);
    let variants = vr.get("variants").and_then(|x| x.as_array()).cloned().unwrap_or_default();
    if variants.is_empty() {
        log::debug!("No variants found - RETURNING NULL");
        return Ok(Value::Null);
    }
    log::debug!("Got {} variants", variants.len());

    // Insert event_media AFTER getting variants (matches Julia line 28-31)
    if let Some(eh) = eid_opt {
        let id_bytes = hex::decode(eh)?;
        let _ = processing_graph::extralog(state, id, json!({
            "op":"insert",
            "table":"event_media",
            "eid":{"_ty":"EventId","_v":eh},
            "url":url
        })).await;
        sqlx::query!("insert into event_media values ($1, $2, nextval('event_media_rowid_seq')) on conflict do nothing", &id_bytes[..], url)
            .execute(&state.pool)
            .await?;
    }

    // Determine original variant and compute orig sha (Julia lines 33-43)
    let mut orig_media_url = url.clone();
    for v in &variants {
        if let (Some(size), Some(anim)) = (v.get("size").and_then(|s| s.as_str()), v.get("animated").and_then(|b| b.as_bool())) {
            if size == "original" && anim {
                if let Some(u) = v.get("media_url").and_then(|s| s.as_str()) { orig_media_url = u.to_string(); }
                break;
            }
        }
    }
    let mut orig_data_cache_hash: Option<String> = None;
    let mut orig_sha_arr: Option<[u8; 32]> = None;
    log::debug!("Attempting to download original media: {}", orig_media_url);
    if let Ok(d) = media::download(&state.media_env, &orig_media_url, None, None, None).await {
        log::debug!("Downloaded original media - {} bytes", d.len());
        let sha = sha2::Sha256::digest(&d);
        let mut arr = [0u8; 32]; arr.copy_from_slice(&sha);
        orig_sha_arr = Some(arr);
        // Write to cache immediately and drop from memory
        if let Ok(cache_hash) = processing_graph::write_vector_u8_to_cache(&d).await {
            orig_data_cache_hash = Some(cache_hash);
            log::debug!("Original data written to cache, memory freed");
        }
        // d is dropped here - freeing memory
        if let Some(ref sha_arr) = orig_sha_arr {
            log::debug!("Original SHA256: {}", hex::encode(sha_arr));
            let _ = processing_graph::extralog(state, id, json!({
                "orig_sha256":hex::encode(sha_arr)
            })).await;
        }
    } else {
        log::debug!("Failed to download from orig_media_url, trying fallback url: {}", url);
        if let Ok(d) = media::download(&state.media_env, &url, None, None, None).await {
            log::debug!("Downloaded fallback media - {} bytes", d.len());
            let sha = sha2::Sha256::digest(&d);
            let mut arr = [0u8; 32]; arr.copy_from_slice(&sha);
            orig_sha_arr = Some(arr);
            // Write to cache immediately and drop from memory
            if let Ok(cache_hash) = processing_graph::write_vector_u8_to_cache(&d).await {
                orig_data_cache_hash = Some(cache_hash);
                log::debug!("Fallback data written to cache, memory freed");
            }
            // d is dropped here - freeing memory
            if let Some(ref sha_arr) = orig_sha_arr {
                log::debug!("Fallback SHA256: {}", hex::encode(sha_arr));
                let _ = processing_graph::extralog(state, id, json!({
                    "orig_sha256":hex::encode(sha_arr)
                })).await;
            }
        } else {
            log::debug!("Failed to download from both URLs");
        }
    }

    // Import each variant via import_media_variant_pn (Julia lines 47-49)
    // Note: orig_data is now on disk in cache, not in memory - pass None
    for v in variants {
        let size = v.get("size").and_then(|s| s.as_str()).unwrap_or("original");
        let anim = v.get("animated").and_then(|b| b.as_bool()).unwrap_or(false);
        let media_url = v.get("media_url").and_then(|s| s.as_str()).unwrap_or(&url).to_string();
        log::debug!("Importing variant - size: {}, animated: {}, media_url: {}", size, anim, media_url);

        let res = crate::pn_wrappers::import_media_variant_pn(
            state,
            eid_hex.as_deref(),
            &url,
            size,
            anim,
            &media_url,
            orig_sha_arr,
            None, // orig_data is now in cache, not memory
        ).await;
        match res {
            Ok(_) => {
                log::debug!("Variant import succeeded - size: {}, animated: {}", size, anim);
            },
            Err(e) => {
                log::debug!("Variant import failed - size: {}, animated: {}, error: {}", size, anim, e);
            }
        }
    }

    // Schedule MediaAnalysis callback (Julia lines 51-57)
    // Schedule if orig_sha256 is available and no_media_analysis flag is false
    if let (Some(ref cache_hash), Some(ref _orig_sha)) = (&orig_data_cache_hash, orig_sha_arr) {
        log::debug!("Orig data in cache (hash: {}), no_media_analysis: {}", cache_hash, no_media_analysis);
        if !no_media_analysis {
            log::debug!("Scheduling media analysis");
            // Try to get pubkey, but schedule analysis even if not available
            let pubkey_bytes: Option<Vec<u8>> = if let Some(eh) = eid_opt {
                if let Ok(id_bytes) = hex::decode(eh) {
                    sqlx::query!("select pubkey from events where id = $1 limit 1", &id_bytes[..])
                        .fetch_optional(&state.pool)
                        .await
                        .ok()
                        .flatten()
                        .and_then(|row| row.pubkey)
                } else {
                    None
                }
            } else {
                None
            };

            log::debug!("Got pubkey: {}", pubkey_bytes.is_some());

            // Build args for MediaAnalysis.ext_after_import_upload_2(url, orig_data; pubkey, eid, origin="nostr")
            // Note: pubkey and eid can be nothing/null
            // Use cache reference instead of loading data into memory
            let ma_args = json!({
                "_ty": "Tuple",
                "_v": [
                    url,
                    {"_ty": "Vector{UInt8}", "_cache_sha256": cache_hash},
                ]
            });
            let mut ma_kwargs_map = serde_json::Map::new();
            if let Some(ref pk) = pubkey_bytes {
                ma_kwargs_map.insert("pubkey".to_string(), processing_graph::vec_u8_from_bytes(pk).await?);
            }
            if let Some(eh) = eid_opt {
                ma_kwargs_map.insert("eid".to_string(), json!({"_ty": "EventId", "_v": eh}));
            }
            ma_kwargs_map.insert("origin".to_string(), json!("nostr"));
            let ma_kwargs = json!(ma_kwargs_map);

            log::debug!("Scheduling media analysis for delayed execution");
            // Schedule delayed execution for media analysis
            let _ = processing_graph::pnd_delayed(
                state,
                "MediaAnalysis",
                "ext_after_import_upload_2",
                &ma_args,
                &ma_kwargs,
            ).await;
            log::debug!("Media analysis scheduled");
        } else {
            log::debug!("Skipping media analysis - no_media_analysis flag is set");
        }
    } else {
        log::debug!("Orig data not available - skipping media analysis");
    }

    log::debug!("EXIT - returning null");
    // Return null (matches Julia's implicit return of nothing)
    Ok(Value::Null)
}

async fn low_trust_user(pool: &PgPool, pubkey: &[u8]) -> anyhow::Result<bool> {
    let pubkey_hex = hex::encode(pubkey);
    log::debug!("ENTRY - pubkey: {}", pubkey_hex);

    log::debug!("Checking verified_users table");
    if sqlx::query!("select 1 as one from verified_users where pubkey = $1 limit 1", pubkey)
        .fetch_optional(pool)
        .await?
        .is_some() {
        log::debug!("Found in verified_users - returning false (trusted)");
        return Ok(false);
    }
    log::debug!("Not in verified_users");

    log::debug!("Checking pubkey_trustrank table");
    if sqlx::query!("select 1 as one from pubkey_trustrank where pubkey = $1 and rank > 1e-6 limit 1", pubkey)
        .fetch_optional(pool)
        .await?
        .is_some() {
        log::debug!("Found in pubkey_trustrank with high rank - returning false (trusted)");
        return Ok(false);
    }
    log::debug!("Not in pubkey_trustrank with high rank");

    log::debug!("Checking pn_time_for_pubkeys table");
    if sqlx::query!("select 1 as one from pn_time_for_pubkeys where pubkey = $1 and duration > 1800 limit 1", pubkey)
        .fetch_optional(pool)
        .await?
        .is_some() {
        log::debug!("Found in pn_time_for_pubkeys with duration > 1800 - returning true (LOW TRUST)");
        return Ok(true);
    }
    log::debug!("Not in pn_time_for_pubkeys with high duration - returning false (default trusted)");
    Ok(false)
}

async fn handler_import_media_variant_pn_inner(
    state: &AppState,
    eid_hex: Option<&str>,
    url: &str,
    size: &str,
    anim: bool,
    media_url: &str,
    orig_sha256: Option<[u8; 32]>,
    _orig_data: Option<&[u8]>,
) -> anyhow::Result<Value> {
    log::debug!("ENTRY - eid_hex: {:?}, url: {}, size: {}, anim: {}, media_url: {}", eid_hex, url, size, anim, media_url);
    let nid = &processing_graph::current_parent().ok_or_else(|| anyhow::anyhow!("no current processing node"))?;

    // Set root-level Extra metadata fields (matches Julia E(; v...) at line 66)
    let mut extra_root = serde_json::Map::new();
    extra_root.insert("url".to_string(), json!(url));
    extra_root.insert("size".to_string(), json!({"_ty":"Symbol","_v":size}));
    extra_root.insert("anim".to_string(), json!(anim));
    extra_root.insert("media_url".to_string(), json!(media_url));
    if let Some(eh) = eid_hex {
        extra_root.insert("eid".to_string(), json!({"_ty":"EventId","_v":eh}));
    }
    let _ = processing_graph::extra_merge(state, nid, extra_root).await;

    log::debug!("Downloading media: {}", media_url);
    let dldur_start = std::time::Instant::now();
    let data = media::download(&state.media_env, media_url, None, None, None).await?;
    let dldur = dldur_start.elapsed().as_secs_f64();
    log::debug!("Downloaded {} bytes in {:.2}s", data.len(), dldur);
    let mimetype = media::parse_mimetype(&data).await;
    log::debug!("MIME type: {}", mimetype);
    let ftype = mimetype.split('/').next().unwrap_or("").to_string();
    log::debug!("File type: {}", ftype);

    let mut width = None;
    let mut height = None;
    let mut duration: Option<f32> = None;
    if ftype == "image" {
        log::debug!("Processing as IMAGE");
        if let Ok((w, h, dur)) = media::parse_image_dimensions(&data).await {
            width = Some(w as i32); height = Some(h as i32); duration = dur;
            log::debug!("Image dimensions: {}x{}", w, h);
        }
    } else if ftype == "video" {
        log::debug!("Processing as VIDEO");
        if let Ok((w, h, dur)) = media::parse_video_dimensions(&data).await {
            width = Some(w as i32); height = Some(h as i32); duration = dur;
            log::debug!("Video dimensions: {}x{}, duration: {:?}s", w, h, dur);
        }
    }

    // Log download info (matches Julia line 82)
    let dims_tuple = if let (Some(w), Some(h)) = (width, height) {
        json!({"_ty":"Tuple","_v":[w, h, duration.unwrap_or(0.0)]})
    } else {
        json!(null)
    };
    let v_data = json!({
        "eid": eid_hex.map(|s| json!({"_ty":"EventId","_v":s})).unwrap_or(json!(null)),
        "url": url,
        "size": {"_ty":"Symbol","_v":size},
        "anim": anim,
        "media_url": media_url
    });
    let _ = processing_graph::extralog(state, nid, json!({
        "v": {"_ty":"NamedTuple","_v":v_data.clone()},
        "dldur": dldur,
        "dlsize": data.len(),
        "mimetype": mimetype,
        "ftype": ftype,
        "dims": dims_tuple
    })).await;

    if ftype == "image" {
        // Swap if EXIF orientation indicates rotation (Julia lines 88-92)
        let rotated = media::is_image_rotated(&data).await;
        let _ = processing_graph::extralog(state, nid, json!({
            "v": {"_ty":"NamedTuple","_v":v_data.clone()},
            "rotated": rotated
        })).await;
        if rotated {
            log::debug!("Image is rotated - swapping dimensions");
            let tmpw = width.unwrap_or(0);
            width = Some(height.unwrap_or(0));
            height = Some(tmpw);
            log::debug!("After rotation swap: {}x{}", width.unwrap_or(0), height.unwrap_or(0));
        }
    } else if ftype == "video" {
        // Video thumbnail extraction (Julia lines 94-102)
        log::debug!("Attempting to extract video thumbnail");
        if let Some(th) = media::extract_video_thumbnail(&data).await {
            log::debug!("Thumbnail extracted: {} bytes", th.len());
            // Import thumbnail via media_import and link
            let key_fields = vec![
                ("url".to_string(), Value::String(url.to_string())),
                ("type".to_string(), Value::String("video_thumbnail".to_string())),
            ];
            let th_clone = th.clone();
            log::debug!("Calling media_import for thumbnail");
            if let Ok(thumbnail_media_url) = crate::media::media_import(state, &key_fields, |_| Ok(th_clone.clone())).await {
                log::debug!("Thumbnail imported to: {}", thumbnail_media_url);
                let _ = processing_graph::extralog(state, nid, json!({
                    "v": {"_ty":"NamedTuple","_v":v_data.clone()},
                    "thumbnail_media_url": thumbnail_media_url
                })).await;
                let _ = processing_graph::extralog(state, nid, json!({
                    "op":"insert",
                    "table":"video_thumbnails",
                    "url":url,
                    "thumbnail_media_url":thumbnail_media_url
                })).await;
                // Insert into video_thumbnails
                let _ = sqlx::query!("insert into video_thumbnails values ($1, $2, nextval('video_thumbnails_rowid_seq')) on conflict do nothing", url, thumbnail_media_url)
                    .execute(&state.pool).await;

                // Recursively import the thumbnail with all variants (Julia line 101)
                // Build args for import_media_pn call
                let eid_json = match eid_hex { Some(eh) => json!({"_ty":"EventId","_v": eh }), None => json!(null) };
                let variant_specs_json = all_variants_json();
                let th_args = json!({
                    "_ty":"Tuple",
                    "_v": [
                        {"_ty":"CacheStorage"},
                        eid_json,
                        thumbnail_media_url,
                        variant_specs_json
                    ]
                });
                let th_kwargs = json!({});
                // Call import_media_pn for the thumbnail
                log::debug!("Recursively calling import_media_pn for thumbnail");
                let _ = processing_graph::pn_immediate(
                    state,
                    "PrimalServer.DB",
                    "import_media_pn",
                    &th_args,
                    &th_kwargs,
                ).await;
                log::debug!("Recursive import_media_pn completed");
            } else {
                log::debug!("Failed to import thumbnail via media_import");
            }
        } else {
            log::debug!("No thumbnail extracted");
        }
    }

    let (width, height) = match (width, height) {
        (Some(w), Some(h)) => (w, h),
        _ => {
            log::debug!("unknown dimensions, import aborted");
            return Ok(json!({"columns":[],"rows":[]}));
        }
    };

    let category = "";
    let category_prob: f32 = 1.0;

    log::debug!("Final metadata - width: {}, height: {}, duration: {:?}", width, height, duration);
    // Match Julia format: log insert operation with all metadata in one entry
    let _ = processing_graph::extralog(state, nid, json!({
        "op":"insert",
        "table":"media",
        "url":url,
        "size":size,
        "anim":anim,
        "dldur":dldur,
        "width":width,
        "height":height,
        "mimetype":mimetype,
        "duration":duration.unwrap_or(0.0),
        "media_url":media_url,
        "orig_sha256":orig_sha256.map(hex::encode)
    })).await;

    // Insert into media table (Julia lines 114-116)
    let imported_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let orig_sha_bytes: Option<Vec<u8>> = orig_sha256.map(|a| a.to_vec());
    log::debug!("Inserting into media table - url: {}, media_url: {}, size: {}, animated: {}, orig_sha: {:?}", url, media_url, size, anim, orig_sha256.map(hex::encode));
    sqlx::query!(
        "insert into media_1_16fa35f2dc (url, media_url, size, animated, imported_at, download_duration, width, height, mimetype, category, category_confidence, duration, rowid, orig_sha256)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,nextval('media_rowid_seq'),$13) on conflict do nothing",
        url,
        media_url,
        size,
        (if anim { 1_i64 } else { 0_i64 }),
        imported_at,
        dldur as f64,
        width as i64,
        height as i64,
        mimetype,
        category,
        category_prob as f64,
        duration.unwrap_or(0.0) as f64,
        orig_sha_bytes
    )
    .execute(&state.pool)
    .await?;

    log::debug!("EXIT - media inserted successfully");
    // Return structured result similar to Julia version
    Ok(json!({"columns":[],"rows":[]}))
}

pub async fn handler_import_media_variant_pn(
    state: &AppState,
    args: Value,
    _kwargs: Value,
) -> anyhow::Result<Value> {
    let a = as_tuple(&args)?;
    if a.len() < 8 { anyhow::bail!("invalid args length"); }
    let eid_hex = as_event_id_hex(&a[1]);
    let url = a[2].as_str().ok_or_else(|| anyhow::anyhow!("missing url"))?.to_string();
    let size = as_symbol(&a[3]).unwrap_or_else(|| "original".into());
    let anim = a[4].as_bool().unwrap_or(false);
    let media_url = a[5].as_str().unwrap_or("").to_string();
    let orig_sha256 = processing_graph::read_vector_u8(&a[6]).await.map(|v| {
        let mut arr = [0u8; 32];
        let len = v.len().min(32);
        arr[..len].copy_from_slice(&v[..len]);
        arr
    });
    let orig_data = processing_graph::read_vector_u8(&a[7]).await;

    handler_import_media_variant_pn_inner(
        state,
        eid_hex.as_deref(),
        &url,
        &size,
        anim,
        &media_url,
        orig_sha256,
        orig_data.as_deref(),
    ).await
}

#[procnode(module = "PrimalServer.DB", func = "import_media_fast_pn")]
pub async fn import_media_fast_pn(state: &AppState, eid_hex: &String, url: &String) -> anyhow::Result<Value> {
    let nid = &processing_graph::current_parent().ok_or_else(|| anyhow::anyhow!("no current processing node"))?;

    let eid = hex::decode(&eid_hex)?;

    // low_trust guard if eid present
    if let Some(row) = sqlx::query!("select pubkey from events where id = $1 limit 1", &eid)
        .fetch_optional(&state.pool)
        .await? {
        if let Some(pubkey) = row.pubkey {
            if low_trust_user(&state.pool, &pubkey).await? { return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"})); }
        }
    }

    let extra_map = json!({"eid": &eid_hex, "url": url}).as_object().ok_or_else(|| anyhow::anyhow!("failed to convert json to object"))?.clone();
    let _ = processing_graph::extra_merge(state, nid, extra_map).await;

    // Clean URL and range-download first 5 MiB
    let cleaned_url = {
        fn cl(u: &str) -> String { if let Some(i)=u.find('#'){u[..i].to_string()} else {u.to_string()} }
        cl(&url)
    };
    let dldur_start = std::time::Instant::now();
    let data_start = media::download(&state.media_env, &cleaned_url, None, Some(30), Some((1, 5*1024*1024))).await?;
    let dldur = dldur_start.elapsed().as_secs_f64();

    let _ = processing_graph::extralog(state, nid, json!({"url": url, "cleaned_url": cleaned_url, "dldur": dldur, "dlsize": data_start.len()})).await;

    let cleaned_url = url::Url::parse(&cleaned_url).ok().ok_or_else(|| anyhow::anyhow!("invalid cleaned url"))?;
    let path = cleaned_url.path();
    let ext = if let Some(pos) = path.rfind('.') {
        &path[pos..]
    } else {
        ""
    };

    let mimetype = media::parse_mimetype(&data_start).await;
    let dims = if mimetype.starts_with("image/") {
        media::parse_image_dimensions(&data_start).await.ok().map(|(w,h, dur)| (w as i32, h as i32, dur.unwrap_or(0.0)))
    } else if mimetype.starts_with("video/") {
        media::parse_video_dimensions(&data_start).await.ok().map(|(w,h,dur)| (w as i32,h as i32, dur.unwrap_or(0.0)))
    } else { None };
    if dims.is_none() { return Ok(json!({"_ty":"Symbol","_v":"no_dims"})); }
    let (width, height, duration) = dims.ok_or_else(|| anyhow::anyhow!("missing dims"))?;

    let _ = processing_graph::extralog(state, nid, json!({"url": url, "ext": ext, "mimetype": mimetype, "dims": dims})).await;

    if !(mimetype.starts_with("image/") || mimetype.starts_with("video/")) {
        anyhow::bail!("unsupported mimetype");
    }

    let imported_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let category = "";
    let category_prob: f64 = 1.0;
    let size = "original";
    let animated: i64 = 0;

    let _ = processing_graph::extralog(state, nid, json!({"op":"insert","table":"media","url":url,"media_url":url,"size":size,"animated":animated,"dldur":dldur,"width":width,"height":height,"mimetype":mimetype,"duration":duration})).await;

    sqlx::query!(
        "insert into media_1_16fa35f2dc (url, media_url, size, animated, imported_at, download_duration, width, height, mimetype, category, category_confidence, duration, rowid, orig_sha256)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,nextval('media_rowid_seq'),$13) on conflict do nothing",
        url,
        url,
        size,
        animated,
        imported_at,
        dldur as f64,
        width as i64,
        height as i64,
        mimetype,
        category,
        category_prob,
        duration as f64,
        None::<Vec<u8>>,
    ).execute(&state.pool).await?;

    let _ = processing_graph::extralog(state, nid, json!({"op":"insert","table":"event_media","event_id":&eid_hex,"url":url})).await;

    sqlx::query!("insert into event_media (event_id, url, rowid) values ($1, $2, nextval('event_media_rowid_seq')) on conflict do nothing", &eid, url).execute(&state.pool).await?;

    Ok(Value::Null)
}

// Clean implementation of import_media_video_variants_pn
async fn import_media_video_variants_pn_impl(
    state: &AppState,
    url: &str,
    media_url: &str,
    mimetype: &str,
    width: i32,
    height: i32,
    duration: f32,
) -> anyhow::Result<Value> {

    let (_nid, vr) = media::handler_media_video_variants_pn(state, &crate::processing_graph::NodeId([0;32]), json!({"_ty":"Tuple","_v":[url, media_url, {"_ty":"Tuple","_v":[width,height]}, duration]}), json!({})).await.map(|v| (crate::processing_graph::NodeId([0;32]), v))?;
    let arr = vr.get("variants").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let imported_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let category = "";
    let category_prob: f64 = 1.0;
    for v in &arr {
        if let (Some(sz), Some(murl)) = (v.get("size").and_then(|s| s.as_str()), v.get("media_url").and_then(|s| s.as_str())) {
            // unknown width/height here; leave 0
            sqlx::query!(
                "insert into media_1_16fa35f2dc (url, media_url, size, animated, imported_at, download_duration, width, height, mimetype, category, category_confidence, duration, rowid, orig_sha256)
                 values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,nextval('media_rowid_seq'),$13) on conflict do nothing",
                url,
                murl,
                sz,
                1_i64,
                imported_at,
                0.0_f64,
                0_i64,
                0_i64,
                mimetype,
                category,
                category_prob,
                duration as f64,
                None::<Vec<u8>>,
            ).execute(&state.pool).await?;
        }
    }
    Ok(json!({"_ty":"Tuple","_v":[arr.len() as i64, {"_ty":"Symbol","_v":"variants"}]}))
}

// Handler that parses kwargs and calls the implementation
pub async fn handler_import_media_video_variants_pn(state: &AppState, _args: Value, kwargs: Value) -> anyhow::Result<Value> {
    let url = kwargs.get("url").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let media_url = kwargs.get("media_url").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let mimetype = kwargs.get("mimetype").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let width = kwargs.get("width").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
    let height = kwargs.get("height").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
    let duration = kwargs.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;

    import_media_video_variants_pn_impl(state, &url, &media_url, &mimetype, width, height, duration).await
}

#[procnode(module = "PrimalServer.DB", func = "import_preview_pn")]
pub async fn import_preview_pn(state: &AppState, eid_hex: &String, url: &String) -> anyhow::Result<Value> {
    let nid = &processing_graph::current_parent().ok_or_else(|| anyhow::anyhow!("no current processing node"))?;

    // Set root-level Extra metadata fields (matches Julia E(; eid, url))
    let mut extra_root = serde_json::Map::new();
    extra_root.insert("eid".to_string(), json!(eid_hex));
    extra_root.insert("url".to_string(), json!(url));
    let _ = processing_graph::extra_merge(state, nid, extra_root).await;

    // Check low_trust_user (Julia line 199)
    let eid_bytes = hex::decode(&eid_hex)?;
    if let Some(row) = sqlx::query!("select pubkey from events where id = $1 limit 1", &eid_bytes[..])
        .fetch_optional(&state.pool)
        .await? {
        if let Some(pubkey) = row.pubkey {
            if low_trust_user(&state.pool, &pubkey).await? {
                return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"}));
            }
        }
    }

    let dldur_start = std::time::Instant::now();
    let md = media::fetch_resource_metadata(&state.media_env, &url).await;
    let dldur = dldur_start.elapsed().as_secs_f64();

    // Import image if present in metadata (Julia line 203)
    if !md.image.is_empty() {
        let variant_specs_json = all_variants_json();
        let img_args = json!({
            "_ty":"Tuple",
            "_v": [
                {"_ty":"CacheStorage"},
                {"_ty":"EventId","_v": eid_hex},
                md.image,
                variant_specs_json
            ]
        });
        let img_kwargs = json!({});
        // Try to import the image, ignore errors
        let _ = processing_graph::pn_immediate(
            state,
            "PrimalServer.DB",
            "import_media_pn",
            &img_args,
            &img_kwargs,
        ).await;
    }

    // Insert preview row if missing
    let imported_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let category = "";
    let category_prob: f64 = 1.0;

    // Match Julia line 208: extralog((; op="insert", table="preview", url, dldur, r...))
    // This spreads all metadata fields from r (mimetype, title, description, image, icon_url)
    let _ = processing_graph::extralog(state, nid, json!({
        "op":"insert",
        "table":"preview",
        "url":url,
        "dldur":dldur,
        "image":md.image,
        "title":md.title,
        "icon_url":md.icon_url,
        "mimetype":md.mimetype,
        "description":md.description
    })).await;

    sqlx::query!(
        "insert into preview_1_44299731c7 (url, imported_at, download_duration, mimetype, category, category_confidence, md_title, md_description, md_image, icon_url, rowid)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,nextval('preview_rowid_seq')) on conflict do nothing",
        url, imported_at, dldur as f64, md.mimetype, category, category_prob, md.title, md.description, md.image, md.icon_url
    ).execute(&state.pool).await?;

    // Match Julia line 215: extralog((; op="insert", table="event_preview", eid, url))
    let _ = processing_graph::extralog(state, nid, json!({
        "op":"insert",
        "table":"event_preview",
        "eid":{"_ty":"EventId","_v":&eid_hex},
        "url":url
    })).await;

    // Link event_preview row
    sqlx::query!(
        "insert into event_preview_1_310cef356e (event_id, url, rowid) values ($1,$2,nextval('event_preview_rowid_seq')) on conflict do nothing",
        &eid_bytes[..], url
    ).execute(&state.pool).await?;

    // Match Julia line 263: (; ok=true, r=_result, id=_id)
    // The function doesn't explicitly return a value in Julia, so _result is ()
    // which becomes [] in JSON
    Ok(json!({
        "_ty":"NamedTuple",
        "_v":{
            "ok":true,
            "r":[],
            "id":{"_ty":"NodeId","_v":hex::encode(nid.0)}
        }
    }))
}

/// Import video frames into the database (Julia lines 224-232)
pub async fn import_video_frames(
    state: &AppState,
    frames: &[(f32, Vec<u8>)],
    video_sha256: &[u8],
    added_at: Option<i64>,
) -> anyhow::Result<()> {
    let added_at = added_at.unwrap_or_else(|| time::OffsetDateTime::now_utc().unix_timestamp());

    for (frame_idx, (frame_pos, frame_data)) in frames.iter().enumerate() {
        let frame_idx = (frame_idx + 1) as i64;  // 1-indexed like Julia

        // Import frame via media_import (Julia line 227)
        let key_fields = vec![
            ("type".to_string(), Value::String("video_frame".to_string())),
            ("video_sha256".to_string(), Value::String(hex::encode(video_sha256))),
            ("frame_idx".to_string(), json!(frame_idx)),
            ("frame_pos".to_string(), json!(*frame_pos)),
        ];
        let frame_clone = frame_data.clone();
        let _media_url = media::media_import(state, &key_fields, |_| Ok(frame_clone.clone())).await?;

        // Insert into video_frames table (Julia lines 229-230)
        let frame_sha256 = sha2::Sha256::digest(frame_data);
        sqlx::query!(
            "insert into video_frames (video_sha256, frame_idx, frame_pos, frame_sha256, added_at) values ($1, $2, $3, $4, $5) on conflict do nothing",
            video_sha256,
            frame_idx,
            *frame_pos,
            &frame_sha256[..],
            added_at
        ).execute(&state.pool).await?;
    }

    Ok(())
}

/// Import video URL and extract frames (Julia lines 234-244)
pub async fn import_video(
    state: &AppState,
    video_url: &str,
    video_data: &[u8],
    video_sha256: &[u8],
) -> anyhow::Result<()> {
    let added_at = time::OffsetDateTime::now_utc().unix_timestamp();

    // Insert into video_urls table (Julia lines 237-238)
    sqlx::query!(
        "insert into video_urls (url, sha256, added_at) values ($1, $2, $3) on conflict do nothing",
        video_url,
        video_sha256,
        added_at
    ).execute(&state.pool).await?;

    // Check if frames already exist (Julia line 239)
    let existing = sqlx::query!(
        "select 1 as one from video_frames where video_sha256 = $1 limit 1",
        video_sha256
    ).fetch_optional(&state.pool).await?;

    if existing.is_none() {
        // Extract and import frames (Julia lines 240-242)
        let frames = media::extract_video_frames(video_data, 5, "mjpeg").await?;
        import_video_frames(state, &frames, video_sha256, Some(added_at)).await?;
    }

    Ok(())
}

pub async fn handler_import_media_hls_pn(
    state: &AppState,
    id: &crate::processing_graph::NodeId,
    args: Value,
    _kwargs: Value,
) -> anyhow::Result<Value> {
    let a = as_tuple(&args)?;
    if a.len() < 4 { anyhow::bail!("invalid args length"); }
    let eid_hex = as_event_id_hex(&a[1]);
    let eid_opt = eid_hex.as_deref();
    let url = a[2].as_str().ok_or_else(|| anyhow::anyhow!("missing url"))?.to_string();
    let media_url = a[3].as_str().ok_or_else(|| anyhow::anyhow!("missing media_url"))?.to_string();

    let _ = processing_graph::extralog(state, id, json!({"step":"import_media_hls_pn:start","url":url,"media_url":media_url})).await;

    // If eid present, check low_trust_user against event's pubkey
    if let Some(eh) = eid_opt {
        let id_bytes = hex::decode(eh)?;
        if let Some(row) = sqlx::query!("select pubkey from events where id = $1 limit 1", &id_bytes[..])
            .fetch_optional(&state.pool)
            .await? {
            if let Some(pubkey) = row.pubkey {
                if low_trust_user(&state.pool, &pubkey).await? {
                    let _ = processing_graph::extralog(state, id, json!({"step":"low_trust_user:block","eid":eh})).await;
                    return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"}));
                }
            } else {
                let _ = processing_graph::extralog(state, id, json!({"step":"low_trust_user:block","reason":"no_pubkey","eid":eh})).await;
                return Ok(json!({"_ty":"Symbol","_v":"low_trust_user"}));
            }
        }
    }

    // Get enabled HLS providers from config
    let enabled_providers: Vec<_> = state.config.media.hls_providers.iter()
        .filter(|p| p.enabled)
        .collect();

    if enabled_providers.is_empty() {
        let _ = processing_graph::extralog(state, id, json!({"step":"no_enabled_providers"})).await;
        return Ok(json!({"_ty":"Symbol","_v":"no_providers"}));
    }

    let _ = processing_graph::extralog(state, id, json!({"step":"providers_found","count":enabled_providers.len()})).await;

    // Create HTTP client for provider API calls
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    // Get configured timeout for HLS processing
    let hls_timeout_secs = state.config.media.hls_processing_timeout_secs;

    // Process all providers in parallel using tokio tasks
    let mut tasks = Vec::new();

    for provider_config in enabled_providers {
        let provider_name = provider_config.provider_type.clone();
        let state_clone = state.clone();
        let id_clone = id.clone();
        let url_clone = url.clone();
        let media_url_clone = media_url.clone();
        let eid_opt_clone = eid_opt.map(|s| s.to_string());
        let http_client_clone = http_client.clone();
        let provider_config_clone = provider_config.clone();

        let _ = processing_graph::extralog(state, id, json!({"step":"processing_provider","provider":provider_name})).await;

        // Spawn a task for each provider
        let task = tokio::spawn(async move {
            let mut task_results = Vec::new();
            let mut task_errors = Vec::new();

            match crate::hls_providers::create_provider(&provider_config_clone, http_client_clone).await {
                Ok(provider) => {
                    let start = std::time::Instant::now();

                    // Process with configured timeout
                    match provider.process_video(&media_url_clone, hls_timeout_secs).await {
                        Ok((hls_url, asset_id)) => {
                            let duration = start.elapsed().as_secs_f64();
                            let _ = processing_graph::extralog(&state_clone, &id_clone, json!({
                                "step":"provider_success",
                                "provider":provider_name,
                                "hls_url":hls_url,
                                "asset_id":asset_id,
                                "duration_secs":duration
                            })).await;

                            // Insert into event_hls_media table
                            if let Some(ref eh) = eid_opt_clone {
                                let eid_bytes = match hex::decode(eh) {
                                    Ok(bytes) => bytes,
                                    Err(e) => {
                                        let error_msg = format!("Failed to decode event_id: {}", e);
                                        task_errors.push(json!({
                                            "provider": provider_name,
                                            "error": error_msg
                                        }));
                                        return (task_results, task_errors);
                                    }
                                };
                                let created_at = time::OffsetDateTime::now_utc().unix_timestamp();

                                // Store asset_id in extra jsonb field
                                let extra = json!({"provider_asset_id": asset_id});

                                let insert_result = sqlx::query!(
                                    "insert into event_hls_media (event_id, url, media_url, provider, hls_url, created_at, extra)
                                     values ($1, $2, $3, $4, $5, $6, $7)
                                     on conflict (event_id, url, provider) do update
                                     set media_url = excluded.media_url, hls_url = excluded.hls_url, created_at = excluded.created_at, extra = excluded.extra",
                                    &eid_bytes[..],
                                    url_clone,
                                    media_url_clone,
                                    provider_name,
                                    hls_url,
                                    created_at,
                                    extra
                                ).execute(&state_clone.pool).await;

                                match insert_result {
                                    Ok(_) => {
                                        let _ = processing_graph::extralog(&state_clone, &id_clone, json!({
                                            "op":"insert",
                                            "table":"event_hls_media",
                                            "event_id":eh,
                                            "url":url_clone,
                                            "media_url":media_url_clone,
                                            "provider":provider_name,
                                            "hls_url":hls_url,
                                            "asset_id":asset_id
                                        })).await;

                                        task_results.push(json!({
                                            "provider": provider_name,
                                            "hls_url": hls_url,
                                            "asset_id": asset_id,
                                            "success": true
                                        }));
                                    }
                                    Err(e) => {
                                        let error_msg = format!("Database insert failed: {}", e);
                                        let _ = processing_graph::extralog(&state_clone, &id_clone, json!({
                                            "step":"db_insert_error",
                                            "provider":provider_name,
                                            "error":error_msg
                                        })).await;
                                        task_errors.push(json!({
                                            "provider": provider_name,
                                            "error": error_msg
                                        }));
                                    }
                                }
                            } else {
                                // No event_id, just return result without database insert
                                task_results.push(json!({
                                    "provider": provider_name,
                                    "hls_url": hls_url,
                                    "asset_id": asset_id,
                                    "success": true
                                }));
                            }
                        }
                        Err(e) => {
                            dbg!(&e);
                            let error_msg = format!("{}", e);
                            let _ = processing_graph::extralog(&state_clone, &id_clone, json!({
                                "step":"provider_error",
                                "provider":provider_name,
                                "error":error_msg
                            })).await;
                            task_errors.push(json!({
                                "provider": provider_name,
                                "error": error_msg
                            }));
                        }
                    }
                }
                Err(e) => {
                    let error_msg = format!("Failed to create provider: {}", e);
                    let _ = processing_graph::extralog(&state_clone, &id_clone, json!({
                        "step":"provider_init_error",
                        "provider":provider_name,
                        "error":error_msg
                    })).await;
                    task_errors.push(json!({
                        "provider": provider_name,
                        "error": error_msg
                    }));
                }
            }

            log::info!("Completed HLS processing for provider: {}", provider_name);

            (task_results, task_errors)
        });

        tasks.push(task);
    }

    // Wait for all tasks to complete and collect results
    let mut results = Vec::new();
    let mut errors = Vec::new();

    for task in tasks {
        match task.await {
            Ok((task_results, task_errors)) => {
                results.extend(task_results);
                errors.extend(task_errors);
            }
            Err(e) => {
                let error_msg = format!("Task join error: {}", e);
                let _ = processing_graph::extralog(state, id, json!({
                    "step":"task_join_error",
                    "error":error_msg
                })).await;
                errors.push(json!({
                    "error": error_msg
                }));
            }
        }
    }

    let _ = processing_graph::extralog(state, id, json!({
        "step":"import_media_hls_pn:done",
        "success_count":results.len(),
        "error_count":errors.len()
    })).await;

    // Return results
    Ok(json!({
        "_ty":"NamedTuple",
        "_v":{
            "results": results,
            "errors": errors,
            "success_count": results.len(),
            "error_count": errors.len()
        }
    }))
}

// TODO: Refactor these handlers to use #[procnode] macro with clean signatures
// For now, use inline registration in register_builtin_nodes()

