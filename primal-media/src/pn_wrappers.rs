use crate::processing_graph::{self, NodeId};
use crate::AppState;
use serde_json::json;

pub async fn import_media_variant_pn(
    state: &AppState,
    eid_hex: Option<&str>,
    url: &str,
    size: &str,
    anim: bool,
    media_url: &str,
    orig_sha256: Option<[u8; 32]>,
    orig_data: Option<&[u8]>,
) -> anyhow::Result<(NodeId, serde_json::Value)> {
    let eid_json = match eid_hex { Some(eh) => json!({"_ty":"EventId","_v": eh }), None => json!(null) };
    let orig_sha = match orig_sha256 {
        Some(arr) => processing_graph::vec_u8_from_bytes(&arr).await?,
        None => json!(null)
    };
    let orig_dat = match orig_data {
        Some(d) => processing_graph::vec_u8_from_bytes(d).await?,
        None => json!(null)
    };
    let args = json!({
        "_ty":"Tuple",
        "_v": [
            {"_v": null, "_ty":"CacheStorage"},
            eid_json,
            url,
            {"_ty":"Symbol","_v": size},
            anim,
            media_url,
            orig_sha,
            orig_dat
        ]
    });
    let kwargs = json!({});
    processing_graph::pn_immediate(state, "PrimalServer.DB", "import_media_variant_pn", &args, &kwargs).await
}

pub async fn transcode_video_pn(
    state: &AppState,
    url: &str,
    media_url: &str,
    iw: i32,
    ih: i32,
    target_ty: &str, // ":height" or ":width"
    target_val: i32,
    bitrate: i32,
) -> anyhow::Result<(NodeId, serde_json::Value)> {
    let args = json!({
        "_ty":"Tuple",
        "_v":[
            url,
            media_url,
            {"_ty":"Tuple","_v":[iw, ih]},
            0.0,
            {"_ty":"Tuple","_v":[target_ty, target_val]},
            bitrate
        ]
    });
    processing_graph::pn_immediate(state, "PrimalServer.Media", "transcode_video_pn", &args, &json!({})).await
}

