use bytes::Bytes;
// logging via log::warn! macro when needed
use once_cell::sync::Lazy;
use primal_media_macros::procnode;
use regex::Regex;
use reqwest::{Client, Proxy};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;

use crate::config::MediaConfig;
use crate::procnode_call;
use crate::AppState;
use sha2::Digest;
use serde_json::{json, Value};
use crate::config::{MediaPathEntry, S3ProviderConfig};
use reqwest::Url;

use log::info;

const DEFAULT_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

#[derive(Debug, Clone)]
pub enum Size {
    Small,
    Medium,
    Large,
    Original,
    Custom(String),
}

#[derive(Debug, Clone, Copy)]
pub enum Animated {
    Static,
    Animated,
}

/// Global semaphore to limit concurrent downloads and prevent memory exhaustion
static DOWNLOAD_SEMAPHORE: Lazy<Semaphore> = Lazy::new(|| Semaphore::new(64));

#[derive(Clone)]
pub struct MediaEnv {
    pub cfg: MediaConfig,
    pub http: Client,
    /// Cached HTTP clients per proxy URL (None key = no proxy)
    proxy_clients: Arc<HashMap<Option<String>, Client>>,
}

impl MediaEnv {
    pub fn new(cfg: MediaConfig) -> anyhow::Result<Self> {
        let mut proxy_clients: HashMap<Option<String>, Client> = HashMap::new();

        // Create no-proxy client
        let no_proxy_client = reqwest::Client::builder()
            .user_agent(DEFAULT_USER_AGENT)
            .gzip(true)
            .brotli(true)
            .deflate(true)
            .tcp_keepalive(Duration::from_secs(30))
            .danger_accept_invalid_certs(true)
            .pool_max_idle_per_host(10)
            .build()?;
        proxy_clients.insert(None, no_proxy_client.clone());

        // Pre-create clients for each configured proxy
        for proxy_url in &cfg.proxies {
            match Proxy::all(proxy_url) {
                Ok(proxy) => {
                    match reqwest::Client::builder()
                        .user_agent(DEFAULT_USER_AGENT)
                        .gzip(true)
                        .brotli(true)
                        .deflate(true)
                        .tcp_keepalive(Duration::from_secs(30))
                        .danger_accept_invalid_certs(true)
                        .pool_max_idle_per_host(10)
                        .proxy(proxy)
                        .build()
                    {
                        Ok(client) => {
                            log::info!("Pre-created HTTP client for proxy: {}", proxy_url);
                            proxy_clients.insert(Some(proxy_url.clone()), client);
                        }
                        Err(e) => {
                            log::warn!("Failed to create client for proxy {}: {}", proxy_url, e);
                        }
                    }
                }
                Err(e) => {
                    log::warn!("Invalid proxy URL {}: {}", proxy_url, e);
                }
            }
        }

        log::info!("MediaEnv initialized with {} cached HTTP clients", proxy_clients.len());

        Ok(Self {
            cfg,
            http: no_proxy_client,
            proxy_clients: Arc::new(proxy_clients),
        })
    }

    /// Get a cached client for the given proxy (None = no proxy)
    pub fn get_client(&self, proxy: Option<&str>) -> Option<&Client> {
        match proxy {
            None => self.proxy_clients.get(&None),
            Some(p) => self.proxy_clients.get(&Some(p.to_string())),
        }
    }
}

const MAX_DOWNLOAD_SIZE: u64 = 2 * 1024 * 1024 * 1024; // 2GB

pub async fn download(
    env: &MediaEnv,
    url: &str,
    proxy: Option<&str>,
    timeout_secs: Option<u64>,
    range: Option<(u64, u64)>,
) -> anyhow::Result<Bytes> {
    // Acquire semaphore permit to limit concurrent downloads
    let _permit = DOWNLOAD_SEMAPHORE.acquire().await
        .map_err(|_| anyhow::anyhow!("download semaphore closed"))?;

    info!("Downloading URL: {} (permits available: {})", url, DOWNLOAD_SEMAPHORE.available_permits());

    // Determine timeout - use longer timeout for primal.net URLs
    let timeout = if url.contains(".primal.net") || url.contains(".primalnode.net") {
        Duration::from_secs(180)
    } else {
        Duration::from_secs(timeout_secs.unwrap_or(env.cfg.download_timeout_secs))
    };

    // Try requested proxy, then rotate through configured proxies.
    let mut proxies: Vec<Option<&str>> = match proxy {
        Some(p) => vec![Some(p)],
        None => {
            let mut proxies = env
                .cfg
                .proxies
                .iter()
                .map(|s| Some(s.as_str()))
                .collect::<Vec<Option<&str>>>();
            use rand::seq::SliceRandom;
            let mut rng = rand::thread_rng();
            proxies.shuffle(&mut rng);
            proxies
        }
    };

    if url.contains(".primal.net") || url.contains(".primaldata.s3") || url.contains(".primaldata.fsn1") {
        if !proxies.iter().any(|p| p.is_none()) {
            proxies.insert(0, None);
        }
    }

    let mut last_err: Option<anyhow::Error> = None;

    for p in proxies {
        // Use cached client if available
        let client = match env.get_client(p) {
            Some(c) => c,
            None => {
                // Proxy not in cache (e.g., passed explicitly but not in config)
                // Skip this proxy and try the next one
                log::warn!("No cached client for proxy {:?}, skipping", p);
                last_err = Some(anyhow::anyhow!("No cached client for proxy"));
                continue;
            }
        };

        // Check file size with HEAD request before downloading (skip for range requests)
        if range.is_none() {
            match client.head(url).timeout(timeout).send().await {
                Ok(head_resp) => {
                    if let Some(content_length) = head_resp.headers()
                        .get(reqwest::header::CONTENT_LENGTH)
                        .and_then(|v| v.to_str().ok())
                        .and_then(|s| s.parse::<u64>().ok())
                    {
                        if content_length > MAX_DOWNLOAD_SIZE {
                            log::warn!(
                                "Skipping download of {} - file size {} bytes ({:.2} GB) exceeds maximum allowed size of 2GB",
                                url,
                                content_length,
                                content_length as f64 / (1024.0 * 1024.0 * 1024.0)
                            );
                            return Err(anyhow::anyhow!(
                                "File size {} bytes exceeds maximum allowed size of 2GB",
                                content_length
                            ));
                        }
                        log::debug!("File size check passed: {} bytes", content_length);
                    }
                }
                Err(e) => {
                    log::debug!("HEAD request failed (proceeding with download): {}", e);
                    // Continue with download even if HEAD fails - some servers don't support HEAD
                }
            }
        }

        let mut req = client.get(url).timeout(timeout);

        if let Some((start, end)) = range {
            req = req.header(reqwest::header::RANGE, format!("bytes={}-{}", start.saturating_sub(1), end.saturating_sub(1)));
        }

        match req.send().await {
            Ok(resp) => match resp.error_for_status() {
                Ok(resp_ok) => match resp_ok.bytes().await {
                    Ok(b) => return Ok(b),
                    Err(e) => { last_err = Some(anyhow::anyhow!(e)); }
                },
                Err(e) => { last_err = Some(anyhow::anyhow!(e)); }
            },
            Err(e) => { last_err = Some(anyhow::anyhow!(e)); }
        }

        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    log::debug!("Downloading {} failed after trying all proxies with {:?}", url, last_err);

    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("download failed")))
}

pub async fn parse_mimetype(data: &[u8]) -> String {
    use std::io::Write;
    use tokio::process::Command;

    let mut tmp = match tempfile::NamedTempFile::new() {
        Ok(t) => t,
        Err(_) => return "application/octet-stream".into(),
    };

    if tmp.write_all(data).is_err() {
        return "application/octet-stream".into();
    }

    let path = match tmp.path().to_str() {
        Some(p) => p,
        None => return "application/octet-stream".into(),
    };

    match Command::new("file")
        .arg("-b")
        .arg("--mime-type")
        .arg(path)
        .output()
        .await
    {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }
        _ => "application/octet-stream".into(),
    }
}

/// Regex pattern to extract image dimensions from `file` command output.
/// Matches patterns like ", 1920 x 1080," or ", 800x600,"
static DIMENSIONS_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r", ([0-9]+) ?x ?([0-9]+)(, |$)").expect("Failed to compile dimensions regex")
});

pub async fn parse_image_dimensions(data: &[u8]) -> anyhow::Result<(u32, u32, Option<f32>)> {
    // Special-case SVG by sniffing content
    if data.len() >= 4 && (&data[0..4] == b"\x3csvg" || String::from_utf8_lossy(&data[..]).contains("<svg")) {
        let s = String::from_utf8_lossy(data);
        let width = s.split("width=\"").nth(1).and_then(|t| t.split('"').next()).and_then(|n| n.parse::<u32>().ok());
        let height = s.split("height=\"").nth(1).and_then(|t| t.split('"').next()).and_then(|n| n.parse::<u32>().ok());
        if let (Some(w), Some(h)) = (width, height) { return Ok((w, h, Some(0.0))); }
    }

    use std::io::Write;
    use tokio::process::Command;

    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(data)?;
    let path = tmp.path().to_str()
        .ok_or_else(|| anyhow::anyhow!("Temporary file path contains invalid UTF-8"))?;

    let output = Command::new("file")
        .arg(path)
        .output()
        .await?;

    if !output.status.success() {
        anyhow::bail!("file command failed: {}", String::from_utf8_lossy(&output.stderr));
    }

    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if let Some(caps) = DIMENSIONS_REGEX.captures(&s) {
        let w = caps.get(1)
            .and_then(|m| m.as_str().parse::<u32>().ok())
            .ok_or_else(|| anyhow::anyhow!("Failed to parse width from dimensions"))?;
        let h = caps.get(2)
            .and_then(|m| m.as_str().parse::<u32>().ok())
            .ok_or_else(|| anyhow::anyhow!("Failed to parse height from dimensions"))?;
        return Ok((w, h, None));
    }

    // Fallback to ImageMagick identify command (works better for webp and other formats)
    log::debug!("file command didn't match regex, trying identify command");
    let identify_output = Command::new("identify")
        .arg("-format")
        .arg("%w %h")
        .arg(format!("{}[0]", path))  // [0] gets first frame for animated images
        .output()
        .await?;

    if identify_output.status.success() {
        let s = String::from_utf8_lossy(&identify_output.stdout);
        let parts: Vec<&str> = s.trim().split_whitespace().collect();
        if parts.len() >= 2 {
            if let (Ok(w), Ok(h)) = (parts[0].parse::<u32>(), parts[1].parse::<u32>()) {
                log::debug!("Successfully parsed dimensions using identify: {}x{}", w, h);
                return Ok((w, h, None));
            }
        }
        log::warn!("Could not parse identify output: {}", s);
    } else {
        log::warn!("identify command failed: {}", String::from_utf8_lossy(&identify_output.stderr));
    }

    anyhow::bail!("Could not parse image dimensions from file or identify commands");
}

pub async fn is_image_rotated(data: &[u8]) -> bool {
    use std::io::Write;
    use tokio::process::Command;

    let mut tmp = match tempfile::NamedTempFile::new() {
        Ok(t) => t,
        Err(_) => return false,
    };

    if tmp.write_all(data).is_err() {
        return false;
    }

    let path = match tmp.path().to_str() {
        Some(p) => p,
        None => return false,
    };

    match Command::new("exiftool")
        .arg("-t")
        .arg(path)
        .output()
        .await
    {
        Ok(out) if out.status.success() => {
            if let Ok(s) = String::from_utf8(out.stdout) {
                for line in s.lines() {
                    let mut parts = line.split('\t');
                    if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
                        if k == "Orientation" && v.contains("Rotate 90 CW") {
                            return true;
                        }
                    }
                }
            }
            false
        }
        _ => false,
    }
}

pub async fn parse_video_dimensions(data: &[u8]) -> anyhow::Result<(u32, u32, Option<f32>)> {
    use std::io::Write;
    use tokio::process::Command;

    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(data)?;
    let path = tmp.path().to_str()
        .ok_or_else(|| anyhow::anyhow!("Temporary file path contains invalid UTF-8"))?;

    // First probe: get stream info with probesize (Julia lines 582)
    let output = Command::new("ffprobe")
        .arg("-v").arg("error")
        .arg("-probesize").arg("10M")
        .arg("-select_streams").arg("v:0")
        .arg("-show_entries").arg("stream")
        .arg(path)
        .stdin(std::process::Stdio::null())
        .output()
        .await?;

    if !output.status.success() {
        anyhow::bail!("ffprobe failed: {}", String::from_utf8_lossy(&output.stderr));
    }

    // Parse output line by line (Julia lines 583-593)
    let stdout_str = String::from_utf8_lossy(&output.stdout);
    let mut width = 0u32;
    let mut height = 0u32;
    let mut duration: Option<f32> = None;
    let mut rotation = 0i32;
    let mut display_aspect_ratio: Option<String> = None;

    for line in stdout_str.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "width" => width = value.parse().unwrap_or(0),
                "height" => height = value.parse().unwrap_or(0),
                "duration" => duration = value.parse().ok(),
                "rotation" => rotation = value.parse().unwrap_or(0),
                "display_aspect_ratio" => display_aspect_ratio = Some(value.to_string()),
                _ => {}
            }
        }
    }

    // If duration is 0, try getting it from format (Julia lines 594-602)
    if duration.is_none() || duration == Some(0.0) {
        let output2 = Command::new("ffprobe")
            .arg("-v").arg("error")
            .arg("-probesize").arg("10M")
            .arg("-select_streams").arg("v:0")
            .arg("-show_format")
            .arg(path)
            .stdin(std::process::Stdio::null())
            .output()
            .await?;

        if output2.status.success() {
            let stdout_str2 = String::from_utf8_lossy(&output2.stdout);
            for line in stdout_str2.lines() {
                if let Some((key, value)) = line.split_once('=') {
                    if key == "duration" {
                        duration = value.parse().ok();
                        break;
                    }
                }
            }
        }
    }

    // Handle rotation: swap dimensions if 90, -90, or 270 degrees (Julia lines 603-604)
    if rotation == 90 || rotation == -90 || rotation == 270 {
        std::mem::swap(&mut width, &mut height);
    }
    // Handle display_aspect_ratio: swap if portrait ratio but landscape dimensions (Julia lines 605-613)
    else if let Some(dar) = display_aspect_ratio {
        if let Some((w_str, h_str)) = dar.split_once(':') {
            if let (Ok(dar_w), Ok(dar_h)) = (w_str.parse::<f32>(), h_str.parse::<f32>()) {
                // If aspect ratio is portrait (h > w) but dimensions are landscape (width > height), swap
                if dar_h > dar_w && width > height {
                    std::mem::swap(&mut width, &mut height);
                }
            }
        }
    }

    if width == 0 || height == 0 {
        anyhow::bail!("Failed to parse video dimensions");
    }

    Ok((width, height, duration))
}

pub async fn extract_video_thumbnail(data: &[u8]) -> Option<Vec<u8>> {
    use std::io::Write;
    use tokio::process::Command;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut tmp = tempfile::NamedTempFile::new().ok()?;
    tmp.write_all(data).ok()?;
    let path = tmp.path().to_str()?;

    // Get duration (Julia line 692)
    let (_w, _h, _dur) = parse_video_dimensions(data).await.ok()?;

    // ss = 0 for start position (Julia line 697)
    let ss = 0;

    // ffmpeg with scale filter and PNG output, piped to ImageMagick for quality JPG conversion (Julia lines 701)
    // Scale filter: "scale=iw*sar:ih,scale='min(1280,iw)':'-1'"
    let mut ffmpeg_child = Command::new("ffmpeg")
        .arg("-v").arg("error")
        .arg("-i").arg(path)
        .arg("-vframes").arg("1")
        .arg("-an")  // Disable audio (Julia line 700)
        .arg("-ss").arg(ss.to_string())
        .arg("-vf").arg("scale=iw*sar:ih,scale='min(1280,iw)':'-1'")
        .arg("-c:v").arg("png")
        .arg("-f").arg("image2pipe")
        .arg("-")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    // Take the stdout handle from ffmpeg
    let mut ffmpeg_stdout = ffmpeg_child.stdout.take()?;

    // Spawn ImageMagick for JPG conversion with quality 90 (Julia line 701)
    let mut magick_child = Command::new("magick")
        .arg("-")
        .arg("-quality").arg("90")
        .arg("jpg:-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    let mut magick_stdin = magick_child.stdin.take()?;
    let mut magick_stdout = magick_child.stdout.take()?;

    // Spawn task to copy ffmpeg stdout to magick stdin
    let copy_task = tokio::spawn(async move {
        let mut buffer = Vec::new();
        ffmpeg_stdout.read_to_end(&mut buffer).await.ok()?;
        magick_stdin.write_all(&buffer).await.ok()?;
        magick_stdin.shutdown().await.ok()?;
        Some(())
    });

    // Read output from magick
    let mut output_data = Vec::new();
    magick_stdout.read_to_end(&mut output_data).await.ok()?;

    // Wait for copy task and processes to complete
    let _ = copy_task.await.ok()?;
    let _ = ffmpeg_child.wait().await.ok()?;
    let status = magick_child.wait().await.ok()?;

    if status.success() && !output_data.is_empty() {
        Some(output_data)
    } else {
        None
    }
}

pub async fn strip_metadata_with_exiftool(data: &[u8]) -> anyhow::Result<Vec<u8>> {
    use std::io::Write;
    use tokio::process::Command;

    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(data)?;
    let path = tmp.path().to_str()
        .ok_or_else(|| anyhow::anyhow!("Temporary file path contains invalid UTF-8"))?;

    // Try exiftool first (Julia lines 675-676)
    let status = Command::new("exiftool")
        .arg("-ignoreMinorErrors")
        .arg("-all=")
        .arg("-tagsfromfile")
        .arg("@")
        .arg("-Orientation")
        .arg("-overwrite_original")
        .arg(path)
        .status()
        .await;

    if let Ok(s) = status {
        if s.success() {
            let out = tokio::fs::read(path).await?;
            return Ok(out);
        }
    }

    // Fallback to ffmpeg (Julia lines 678-679)
    let mt = parse_mimetype(data).await;
    let ext = mimetype_ext(&mt).trim_start_matches('.').to_string();

    let output = Command::new("ffmpeg")
        .arg("-y")
        .arg("-i")
        .arg(path)
        .arg("-map_metadata")
        .arg("-1")
        .arg("-c:v")
        .arg("copy")
        .arg("-c:a")
        .arg("copy")
        .arg("-f")
        .arg(&ext)
        .arg("-")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .await?;

    if output.status.success() && !output.stdout.is_empty() {
        Ok(output.stdout)
    } else {
        anyhow::bail!("Both exiftool and ffmpeg failed to strip metadata")
    }
}

/// Extract N frames from video at evenly distributed positions (Julia lines 628-636)
pub async fn extract_video_frames(data: &[u8], nframes: u32, image_format: &str) -> anyhow::Result<Vec<(f32, Vec<u8>)>> {
    use std::io::Write;
    use tokio::process::Command;
    use tokio::io::AsyncReadExt;

    let (_w, _h, dur) = parse_video_dimensions(data).await?;
    let duration = dur.unwrap_or(0.0);

    if duration <= 0.0 {
        anyhow::bail!("Cannot extract frames: invalid video duration");
    }

    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(data)?;
    let path = tmp.path().to_str()
        .ok_or_else(|| anyhow::anyhow!("Temporary file path contains invalid UTF-8"))?;

    let mut frames = Vec::new();

    for i in 1..=nframes {
        let frame_pos = (i as f32) * duration / ((nframes + 1) as f32);

        // ffmpeg piped to magick (Julia line 633)
        let mut ffmpeg_child = Command::new("ffmpeg")
            .arg("-v").arg("error")
            .arg("-i").arg(path)
            .arg("-vframes").arg("1")
            .arg("-an")
            .arg("-ss").arg(frame_pos.to_string())
            .arg("-c:v").arg(image_format)
            .arg("-f").arg("image2pipe")
            .arg("-")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()?;

        let mut ffmpeg_stdout = ffmpeg_child.stdout.take()
            .ok_or_else(|| anyhow::anyhow!("Failed to capture ffmpeg stdout"))?;

        let mut magick_child = Command::new("magick")
            .arg("-")
            .arg("-")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()?;

        let mut magick_stdin = magick_child.stdin.take()
            .ok_or_else(|| anyhow::anyhow!("Failed to open magick stdin"))?;
        let mut magick_stdout = magick_child.stdout.take()
            .ok_or_else(|| anyhow::anyhow!("Failed to capture magick stdout"))?;

        // Copy ffmpeg output to magick input
        let copy_task = tokio::spawn(async move {
            use tokio::io::AsyncWriteExt;
            let mut buffer = Vec::new();
            ffmpeg_stdout.read_to_end(&mut buffer).await.ok()?;
            magick_stdin.write_all(&buffer).await.ok()?;
            magick_stdin.shutdown().await.ok()?;
            Some(())
        });

        let mut frame_data = Vec::new();
        magick_stdout.read_to_end(&mut frame_data).await?;

        let _ = copy_task.await;
        let _ = ffmpeg_child.wait().await;
        let _ = magick_child.wait().await;

        if !frame_data.is_empty() {
            frames.push((frame_pos, frame_data));
        }
    }

    Ok(frames)
}

/// Resize image using ImageMagick with memory limit (Julia lines 708-710)
pub async fn resize_image(data: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    use tokio::process::Command;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    // Julia: systemd-run --quiet --scope -p MemoryMax=5G --user magick - -resize WxH -
    let mut child = Command::new("systemd-run")
        .arg("--quiet")
        .arg("--scope")
        .arg("-p")
        .arg("MemoryMax=5G")
        .arg("--user")
        .arg("magick")
        .arg("-")
        .arg("-resize")
        .arg(format!("{}x{}", width, height))
        .arg("-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    let mut stdin = child.stdin.take()?;
    let mut stdout = child.stdout.take()?;

    let data_clone = data.to_vec();
    let write_task = tokio::spawn(async move {
        stdin.write_all(&data_clone).await.ok()?;
        stdin.shutdown().await.ok()?;
        Some(())
    });

    let mut output = Vec::new();
    stdout.read_to_end(&mut output).await.ok()?;

    let _ = write_task.await;
    let status = child.wait().await.ok()?;

    if status.success() && !output.is_empty() {
        Some(output)
    } else {
        None
    }
}

/// Extract beginning portion of video (Julia lines 712-724)
pub async fn extract_video_beginning(data: &[u8], duration_secs: u32, timeout_secs: u32) -> anyhow::Result<Vec<u8>> {
    use tokio::process::Command;

    // Create temp files (Julia lines 713-715)
    let rnd: String = (0..30).map(|_| rand::random::<char>()).filter(|c| c.is_ascii_lowercase()).take(30).collect();
    let fn1 = format!("/tmp/extract-video-beginning-{}-1", &rnd[..rnd.len().min(30)]);
    let fn2 = format!("/tmp/extract-video-beginning-{}-2.mp4", &rnd[..rnd.len().min(30)]);

    // Write input file
    tokio::fs::write(&fn1, data).await?;

    // Run ffmpeg with timeout (Julia line 718)
    let status = Command::new("timeout")
        .arg(timeout_secs.to_string())
        .arg("ffmpeg")
        .arg("-v").arg("error")
        .arg("-i").arg(&fn1)
        .arg("-t").arg(duration_secs.to_string())
        .arg("-movflags").arg("faststart")
        .arg("-c").arg("copy")
        .arg(&fn2)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;

    // Read output and cleanup (Julia lines 719-723)
    let result = if status.map(|s| s.success()).unwrap_or(false) {
        tokio::fs::read(&fn2).await
    } else {
        Err(std::io::Error::new(std::io::ErrorKind::Other, "ffmpeg failed"))
    };

    // Cleanup temp files
    let _ = tokio::fs::remove_file(&fn1).await;
    let _ = tokio::fs::remove_file(&fn2).await;

    result.map_err(|e| anyhow::anyhow!("extract_video_beginning failed: {}", e))
}

// Utility helpers (kept near-media to mirror Julia's structure)
fn sha256_hex(data: &[u8]) -> String { let h = sha2::Sha256::digest(data); hex::encode(h) }
pub fn last_segment(path: &str) -> String { std::path::Path::new(path).components().last().map(|c| c.as_os_str().to_string_lossy().to_string()).unwrap_or_else(|| "cache".to_string()) }
pub fn join_url(root: &str, segments: &[&str]) -> String { let mut s = root.trim_end_matches('/').to_string(); for seg in segments { s.push('/'); s.push_str(seg.trim_matches('/')); } s }
fn clean_url_str(u: &str) -> String { if let Some(i) = u.find('#') { u[..i].to_string() } else { u.to_string() } }
fn mimetype_ext(mt: &str) -> &str { match mt { "image/jpeg"=>".jpg","image/png"=>".png","image/gif"=>".gif","image/webp"=>".webp","image/svg+xml"=>".svg","video/mp4"=>".mp4","video/x-m4v"=>".mp4","video/mov"=>".mov","video/webp"=>".webp","video/webm"=>".webm","video/quicktime"=>".mov","video/x-matroska"=>".mkv","video/3gpp"=>".3gp","image/vnd.microsoft.icon"=>".ico","text/plain"=>".txt","application/json"=>".json","text/html"=>".html","text/javascript"=>".js","application/wasm"=>".wasm",_=>".bin", } }
pub fn juliaish_json_from_kv(fields: &[(String, Value)]) -> String { let mut kvs = Vec::new(); for (k, v) in fields { kvs.push((k.clone(), crate::processing_graph::parse_arg(v))); } let aj = crate::processing_graph::AJ::Obj(kvs); let mut s = String::new(); crate::processing_graph::write_json(&mut s, &aj); s }
fn key_h_from_fields(fields: &[(String, Value)]) -> String { let s = juliaish_json_from_kv(fields); sha256_hex(s.as_bytes()) }
pub fn subdir_from_h(h: &str) -> (String, String) { let subdir = format!("{}/{}/{}", &h[0..1], &h[1..3], &h[3..5]); (subdir.clone(), format!("{}/{}", subdir, h)) }
async fn ensure_dir(path: &str) -> anyhow::Result<()> { tokio::fs::create_dir_all(path).await?; Ok(()) }
fn default_variant_specs() -> Vec<(String, bool)> { let sizes=["original","small","medium","large"]; let mut v=Vec::new(); for s in sizes { for a in [true,false] { v.push((s.to_string(),a)); } } v }
fn size_resolution(size: &str) -> (i32,i32) { match size { "small"=>(200,200),"medium"=>(400,400),"large"=>(1000,1000), _=>(0,0) } }
fn build_scale_filter(size:&str)->Option<String>{ let (w,h)=size_resolution(size); if w==0 {return None;} if size=="small"||size=="medium" {Some(format!("scale=trunc(oh*a/2)*2:min({}\\,ih)",h))} else if size=="large" {Some(format!("scale=min({}\\,iw):trunc(ow/a/2)*2",w))} else {None}}
/// Returns stderr output from ffmpeg on success (for logging/diagnostics)
async fn ffmpeg_resize_to_file(input:&[u8],filters:&[String],single_frame:bool,outfn:&str,ffmpeg_remote_host:Option<&str>)->anyhow::Result<String> {
    use tokio::process::Command;
    use tokio::io::AsyncWriteExt;
    use tokio::time::Duration;
    use std::process::Stdio;

    let output_to_stdout = ffmpeg_remote_host.is_some();

    // Build ffmpeg args
    let mut ffmpeg_args = vec![
        "-v".to_string(), "error".to_string(), "-y".to_string(),
        "-i".to_string(), "-".to_string(), "-map_metadata".to_string(), "-1".to_string(),
    ];
    if single_frame {
        ffmpeg_args.extend_from_slice(&["-frames:v".into(), "1".into(), "-update".into(), "1".into()]);
    }
    if !filters.is_empty() {
        ffmpeg_args.push("-vf".into());
        ffmpeg_args.push(filters.join(","));
    }
    if output_to_stdout {
        let ext = std::path::Path::new(outfn).extension().and_then(|e| e.to_str()).unwrap_or("jpg");
        let fmt = match ext {
            "jpg" | "jpeg" => "mjpeg",
            "png" => "image2",
            "webp" => "webp",
            "gif" => "gif",
            "mp4" => "mp4",
            _ => "mjpeg",
        };
        if fmt == "mp4" {
            ffmpeg_args.extend_from_slice(&["-movflags".into(), "frag_keyframe+empty_moov".into()]);
        }
        ffmpeg_args.extend_from_slice(&["-f".into(), fmt.into()]);
        ffmpeg_args.push("pipe:1".into());
    } else {
        ffmpeg_args.push(outfn.into());
    }

    // Build command: local ffmpeg or ssh to remote host
    let mut cmd = if let Some(host) = ffmpeg_remote_host {
        let remote_cmd = std::iter::once("nice".to_string())
            .chain(std::iter::once("ffmpeg".to_string()))
            .chain(ffmpeg_args)
            .map(|a| shell_escape::escape(a.into()).into_owned())
            .collect::<Vec<_>>()
            .join(" ");
        log::debug!("Running remote ffmpeg on {}: {}", host, remote_cmd);
        let mut c = Command::new("ssh");
        c.arg(host)
         .arg(&remote_cmd);
        c
    } else {
        let mut c = Command::new("ffmpeg");
        for arg in &ffmpeg_args { c.arg(arg); }
        c
    };

    cmd.stdin(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    if output_to_stdout { cmd.stdout(Stdio::piped()); } else { cmd.stdout(Stdio::null()); }

    log::debug!("Running ffmpeg command: {:?}", cmd);
    let mut child = cmd.spawn()?;

    {
        let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("failed to open ffmpeg stdin"))?;
        if let Err(e) = stdin.write_all(input).await {
            let output = child.wait_with_output().await?;
            let stderr = String::from_utf8_lossy(&output.stderr);
            log::error!("Failed to write to ffmpeg stdin (remote={}): {}, stderr: {}", ffmpeg_remote_host.unwrap_or("local"), e, stderr);
            anyhow::bail!("ffmpeg write failed (remote={}): {}, stderr: {}", ffmpeg_remote_host.unwrap_or("local"), e, stderr);
        }
        let _ = stdin.shutdown().await;
    }

    let output = tokio::time::timeout(Duration::from_secs(600), child.wait_with_output()).await
        .map_err(|_| anyhow::anyhow!("ffmpeg timed out after 600s"))??;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        log::error!("ffmpeg failed (remote={}): stderr: {}", ffmpeg_remote_host.unwrap_or("local"), stderr);
        anyhow::bail!("ffmpeg resize failed (remote={}): {}", ffmpeg_remote_host.unwrap_or("local"), stderr);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    if output_to_stdout {
        if output.stdout.is_empty() {
            anyhow::bail!("remote ffmpeg produced no output, stderr: {}", stderr);
        }
        if let Some(parent) = std::path::Path::new(outfn).parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        tokio::fs::write(outfn, &output.stdout).await?;
    }

    Ok(stderr)
}

// Handler for PrimalServer.Media.media_variants_pn(est, url; variant_specs, key)
#[procnode(module = "PrimalServer.Media", func = "media_variants_pn")]
pub async fn media_variants_pn(
    state: &AppState,
    id: &crate::processing_graph::NodeId,
    url: &String,
) -> anyhow::Result<Value> {
    log::debug!("ENTRY - url: {}", url);
    let cleaned_url = clean_url_str(&url);
    log::debug!("Parsed URL - original: {}, cleaned: {}", url, cleaned_url);
    let _ = crate::processing_graph::extralog(state, id, json!({"step":"media_variants_pn:start","url":url,"cleaned_url":cleaned_url})).await;

    // Use default values (kwargs parsing can be added later)
    let base_fields: Vec<(String, Value)> = Vec::new();

    // Ensure original present
    let mut k_orig = base_fields.clone(); k_orig.push(("url".into(), Value::String(cleaned_url.clone()))); k_orig.push(("type".into(), Value::String("original".into())));
    let h_orig = key_h_from_fields(&k_orig);
    let orig = sqlx::query!(
        "select ms.media_url, ms.ext, ms.content_type from media_storage ms join media_storage_priority msp on ms.storage_provider = msp.storage_provider where h = $1 order by msp.priority limit 1",
        h_orig
    )
        .fetch_optional(&state.pool).await?;
    log::debug!("Checking for original media in storage");
    let (orig_media_url, orig_ext, mimetype, orig_data) = if let Some(row) = orig {
        log::debug!("Found original in storage: {}", row.media_url);
        // Download from storage URL
        let dldur_start = std::time::Instant::now();
        let data = download(&state.media_env, &row.media_url, None, None, None).await?;
        let dldur = dldur_start.elapsed().as_secs_f64();
        log::debug!("Downloaded from storage: {} bytes in {:.3}s", data.len(), dldur);
        (row.media_url, row.ext, row.content_type, data)
    } else {
        log::debug!("Original not in storage, downloading and importing");
        // insert original via media_import
        let dldur_start = std::time::Instant::now();
        let mut data = download(&state.media_env, &cleaned_url, None, None, None).await?;
        let dldur = dldur_start.elapsed().as_secs_f64();
        log::debug!("Downloaded original: {} bytes in {:.3}s", data.len(), dldur);
        let mt = parse_mimetype(&data).await;
        log::debug!("Original MIME type: {}", mt);
        if state.config.media.strip_image_metadata && mt.starts_with("image/") {
            log::debug!("Stripping image metadata");
            if let Ok(cleaned) = strip_metadata_with_exiftool(&data).await { data = Bytes::from(cleaned); }
        }
        log::debug!("Calling media_import for original");
        let data_for_import = data.to_vec();
        let media_url = media_import(state, &k_orig, |_| Ok(data_for_import.clone())).await?;
        log::debug!("Original imported to: {}", media_url);
        let ext = mimetype_ext(&mt).to_string();
        let _ = crate::processing_graph::extralog(state, id, json!({"step":"original:imported","media_url":media_url})).await;
        (media_url, ext, mt, data)
    };
    if orig_ext == ".bin" {
        log::debug!("Original extension is .bin - returning empty variants");
        return Ok(json!({"variants": []}));
    }

    // Use default variant specs (kwargs parsing can be added later)
    let variant_specs = default_variant_specs();

    // orig_data already downloaded above - no need to download again
    let dlsize = orig_data.len();
    let _ = crate::processing_graph::extralog(state, id, json!({
        "orig_media_url": orig_media_url,
        "url": url,
        "dlsize": dlsize
    })).await;

    // Log original media variant
    let _ = crate::processing_graph::extralog(state, id, json!({
        "murl": orig_media_url,
        "v": {"animated": true, "size": "original", "url": url}
    })).await;
    let _ = crate::processing_graph::extralog(state, id, json!({
        "murl": orig_media_url,
        "v": {"animated": false, "size": "original", "url": url}
    })).await;

    log::debug!("Generating {} variant(s)", variant_specs.len());
    let mut out_variants = Vec::new();
    for (size, animated) in variant_specs {
        log::debug!("Processing variant - size: {}, animated: {}", size, animated);
        if size == "original" || mimetype == "image/svg+xml" {
            log::debug!("Using original media for size: {}", size);
            out_variants.push(json!({"size": size, "animated": animated, "media_url": orig_media_url}));
            continue;
        }
        // For videos: only extract single frames, never re-encode whole video
        if mimetype.starts_with("video/") && animated {
            log::debug!("Skipping animated variant for video: {}", size);
            continue;
        }
        let mut conv_single_frame=false;
        if !mimetype.starts_with("image/gif") && (!animated || mimetype.starts_with("image/")) {
            conv_single_frame=true;
        }
        let mut filters=Vec::new();
        if let Some(f)=build_scale_filter(&size){ filters.push(f); }
        ensure_dir(&state.config.media.tmp_dir).await?;
        let outfn = format!("{}/{}{}", state.config.media.tmp_dir, h_orig, orig_ext);
        let logfile = format!("{}.log", outfn);

        // Build ffmpeg command string for logging
        let vf_str = if !filters.is_empty() {
            format!(" -vf \"{}\"", filters.join(","))
        } else {
            String::new()
        };
        let frames_str = if conv_single_frame {
            " -frames:v 1 -update 1".to_string()
        } else {
            String::new()
        };
        let cmd_str = format!(
            "`nice ionice -c3 ffmpeg -y -i -{}{} {}`",
            frames_str, vf_str, outfn
        );

        log::debug!("Resizing with ffmpeg - conv_single_frame: {}, output: {}", conv_single_frame, outfn);
        let _ = crate::processing_graph::extralog(state, id, json!({
            "cmd": cmd_str,
            "logfile": logfile,
            "outfn": outfn,
            "v": {"animated": animated, "size": size, "url": url}
        })).await;

        match ffmpeg_resize_to_file(&orig_data, &filters, conv_single_frame, &outfn, state.config.media.ffmpeg_remote_host.as_deref()).await {
            Ok(ffmpeg_stderr) => {
                let _ = crate::processing_graph::extralog(state, id, json!({
                    "status": true,
                    "ffmpeg_stderr": if ffmpeg_stderr.is_empty() { None } else { Some(&ffmpeg_stderr) },
                    "v": {"animated": animated, "size": size, "url": url}
                })).await;
            }
            Err(e) => {
                log::debug!("FFmpeg resize failed: {}", e);
                log::warn!("ffmpeg resize failed: {}", e);
                let _ = crate::processing_graph::extralog(state, id, json!({
                    "status": false,
                    "error": e.to_string(),
                    "v": {"animated": animated, "size": size, "url": url}
                })).await;
                continue;
            }
        }

        // Import resized variant via media_import
        let mut k_resized=base_fields.clone();
        k_resized.push(("url".into(), Value::String(url.clone())));
        k_resized.push(("type".into(), Value::String("resized".into())));
        k_resized.push(("size".into(), Value::String(size.clone())));
        k_resized.push(("animated".into(), Value::Bool(animated)));
        let data = tokio::fs::read(&outfn).await
            .map_err(|e| anyhow::anyhow!("failed to read ffmpeg output {}: {}", outfn, e))?;
        log::debug!("Resized file read - {} bytes, calling media_import", data.len());
        let data_clone = data.clone();
        let media_url2 = media_import(state, &k_resized, |_| Ok(data_clone.clone())).await?;
        log::debug!("Resized variant imported to: {}", media_url2);

        let _ = crate::processing_graph::extralog(state, id, json!({
            "murl": media_url2,
            "v": {"animated": animated, "size": size, "url": url}
        })).await;

        let _ = tokio::fs::remove_file(&outfn).await;
        out_variants.push(json!({"size": size, "animated": animated, "media_url": media_url2}));
    }
    log::debug!("EXIT - returning {} variants", out_variants.len());

    // Log final variant list
    let variant_map: serde_json::Map<String, Value> = out_variants.iter()
        .map(|v| {
            let size = v.get("size").and_then(|s| s.as_str()).unwrap_or("");
            let anim = v.get("animated").and_then(|b| b.as_bool()).unwrap_or(false);
            let murl = v.get("media_url").and_then(|s| s.as_str()).unwrap_or("");
            let key = format!("(:{}, {})", size, anim);
            (key, Value::String(murl.to_string()))
        })
        .collect();
    let _ = crate::processing_graph::extralog(state, id, json!({
        "url": url,
        "variants": variant_map
    })).await;

    Ok(json!({"variants": out_variants}))
}

// Fast variant generator for probing; returns (size, animated, media_url, mimetype, dims, dldur, data_start)
#[procnode(module = "PrimalServer.Media", func = "media_variant_fast_pn")]
pub async fn media_variant_fast_pn(state: &AppState, id: &crate::processing_graph::NodeId, url: &String) -> anyhow::Result<Value> {
    let cleaned_url = clean_url_str(&url);
    let dldur_start = std::time::Instant::now();
    let data_start = download(&state.media_env, &cleaned_url, None, None, Some((1, 5*1024*1024))).await?;
    let _dldur = dldur_start.elapsed().as_secs_f64();
    let mimetype = parse_mimetype(&data_start).await;
    let dims = if mimetype.starts_with("image/") { parse_image_dimensions(&data_start).await.ok() } else if mimetype.starts_with("video/") { parse_video_dimensions(&data_start).await.ok().map(|(w,h,d)| (w,h,d)) } else { None };
    if dims.is_none() { return Ok(json!({"_ty":"Symbol","_v":"no_dims"})); }

    // Quick large resized variant
    let size = "large"; let animated = false;
    let mut k_resized: Vec<(String, Value)> = Vec::new();
    k_resized.push(("url".into(), Value::String(url.clone())));
    k_resized.push(("type".into(), Value::String("resized".into())));
    k_resized.push(("size".into(), Value::String(size.into())));
    k_resized.push(("animated".into(), Value::Bool(animated)));
    let h_res = key_h_from_fields(&k_resized);
    let (subdir2,_)=subdir_from_h(&h_res); let dirpath2 = format!("{}/{}", state.config.media.media_path, subdir2); ensure_dir(&dirpath2).await?; let ext = mimetype_ext(&mimetype).to_string();
    let outfn = format!("{}/{}{}", state.config.media.tmp_dir, h_res, ext);
    let mut filters=Vec::new(); if let Some(f)=build_scale_filter(size){ filters.push(f); }
    if let Err(e)=ffmpeg_resize_to_file(&data_start, &filters, true, &outfn, state.config.media.ffmpeg_remote_host.as_deref()).await { log::warn!("fast_pn ffmpeg resize failed: {}", e); return Ok(Value::Null); }
    let out_data = tokio::fs::read(&outfn).await?;
    let out_clone = out_data.clone();
    let media_url2 = media_import(state, &k_resized, |_| Ok(out_clone.clone())).await?;
    let _ = tokio::fs::remove_file(&outfn).await;
    let _ = crate::processing_graph::extralog(state, id, json!({"step":"media_variant_fast:done","media_url":media_url2,"size":size})).await;
    Ok(json!({"_ty":"Tuple","_v":[{"_ty":"Symbol","_v": size}, animated, media_url2, mimetype]}))
}

// Metadata fetcher for previews (basic implementation; can be enhanced)
#[derive(Default, Debug, Clone, Serialize, Deserialize)]
pub struct ResourceMetadata {
    pub mimetype: String,
    pub title: String,
    pub description: String,
    pub image: String,
    pub icon_url: String,
}

pub async fn fetch_resource_metadata(env: &MediaEnv, url: &str) -> ResourceMetadata {
    use tokio::process::{Command};
    use std::process::Stdio;

    // Match Julia behavior: proxy is "null" string if None (Julia line 645)
    let proxy = env.cfg.metadata_proxy.clone().unwrap_or_else(|| "null".into());

    // Use proper script path relative to primal-media directory
    let script_path = "../link-preview.py";

    if tokio::fs::try_exists(script_path).await.unwrap_or(false) {
        // Use timeout wrapper and nice (Julia line 647: "nice timeout 10")
        if let Ok(cmdout) = Command::new("timeout")
            .arg("10")
            .arg("nice")
            .arg("/home/pr/.julia/conda/3/x86_64/bin/python")
            .arg(script_path)
            .arg(url)
            .arg(&proxy)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .await
        {
            if cmdout.status.success() {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&cmdout.stdout) {
                    let md = ResourceMetadata {
                        mimetype: v.get("mimetype").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        title: v.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        description: v.get("description").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        image: v.get("image").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        icon_url: v.get("icon_url").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                    };
                    return md;
                }
            }
        }
    }
    ResourceMetadata::default()
}

// Handler for PrimalServer.Media.transcode_video_pn(url, media_url, input_resolution, input_duration, target, bitrate)
// Clean implementation of transcode_video_pn
async fn transcode_video_pn_impl(
    state: &AppState,
    id: &crate::processing_graph::NodeId,
    url: &str,
    media_url: &str,
    iw: i32,
    ih: i32,
    input_duration: f32,
    target_ty: &str,
    target_val: i32,
    bitrate: i32,
) -> anyhow::Result<Value> {

    anyhow::ensure!(iw > 0 && ih > 0, "invalid input resolution");
    let ratio = iw as f64 / ih as f64;
    let (ow, oh) = if target_ty == ":height" { ((target_val as f64 * ratio).round() as i32, target_val) } else if target_ty == ":width" { (target_val, (target_val as f64 / ratio).round() as i32) } else { anyhow::bail!("invalid target"); };

    // Remote ffmpeg over ssh
    let server = state.config.media.video_transcoding_server.clone().ok_or_else(|| anyhow::anyhow!("video_transcoding_server not set"))?;
    let ffmpeg_path = state.config.media.video_transcoding_ffmpeg_path.clone().unwrap_or_else(|| "ffmpeg".to_string());
    let remoteoutfn = format!("/tmp/transcoding-{}.mp4", &sha256_hex(url.as_bytes())[0..16]);

    let outfn = format!("{}/{}.mp4", state.config.media.tmp_dir, &sha256_hex(remoteoutfn.as_bytes())[0..16]);
    let logfile = format!("{}.log", outfn);
    let timeout = (input_duration as f64 / 5.0 + 120.0).ceil() as i32;
    let scale_filter = format!("scale_cuda=w={}:h={}:format=nv12,fps=30", ow, oh);
    let remote_cmd = format!(
        "{} -nostats -progress /dev/stderr -y -hide_banner -map_metadata -1 -hwaccel cuda -hwaccel_output_format cuda -i {} -vf '{}' -c:v h264_nvenc -profile:v main -level:v 4.0 -b:v {} -maxrate {} -bufsize 5M -c:a aac -profile:a aac_low -b:a 128k -movflags +faststart {} && cat {} && rm -f {}",
        ffmpeg_path, shell_escape::escape(media_url.into()), scale_filter, bitrate, bitrate, remoteoutfn, remoteoutfn, remoteoutfn
    );

    use tokio::process::Command;
    use std::process::Stdio;
    let mut cmd = Command::new("timeout");
    cmd.arg(timeout.to_string())
        .arg("ssh")
        .arg("-o").arg("ConnectTimeout=10")
        .arg("-o").arg("ServerAliveInterval=20")
        .arg("-o").arg("ServerAliveCountMax=3")
        .arg(&server)
        .arg(remote_cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    tokio::fs::create_dir_all(&state.config.media.tmp_dir).await.ok();
    let _ = crate::processing_graph::extralog(state, id, json!({"step":"transcode:start","server":server,"cmd":"ssh ffmpeg nvenc"})).await;
    let mut child = cmd.spawn()?;
    let mut out_file = tokio::fs::File::create(&outfn).await?;
    // Copy stdout to file
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let t_out = tokio::spawn(async move {
        tokio::io::copy(&mut stdout, &mut out_file).await.ok()
    });
    // For now, ignore progress; capture and write logfile
    let logf = logfile.clone();
    let t_err = tokio::spawn(async move {
        let mut f = tokio::fs::File::create(&logf).await.ok()?;
        let _ = tokio::io::copy(&mut stderr, &mut f).await;
        Some(())
    });
    let status = child.wait().await?;
    let _ = t_out.await;
    let _ = t_err.await;
    anyhow::ensure!(status.success(), "ssh ffmpeg failed");

    let data = tokio::fs::read(&outfn).await?;
    if data.is_empty() { anyhow::bail!("transcoded output empty"); }
    let key_fields = vec![
        ("url".to_string(), Value::String(url.to_string())),
        ("type".to_string(), Value::String("transcoded_video".to_string())),
        ("target_resolution".to_string(), json!({"_ty":"Tuple","_v":[oh]})),
    ];
    let data_clone = data.clone();
    let media_url2 = media_import(state, &key_fields, |_| Ok(data_clone.clone())).await?;
    // Cleanup tmp file and log
    let _ = tokio::fs::remove_file(&outfn).await;
    let _ = tokio::fs::remove_file(&logfile).await;
    let _ = crate::processing_graph::extralog(state, id, json!({"step":"transcode:done","media_url":media_url2,"ow":ow,"oh":oh})).await;
    Ok(json!({"_ty":"Tuple","_v":[media_url2, {"_ty":"Tuple","_v":[ow, oh]}]}))
}

// Handler that parses args and calls the implementation
pub async fn handler_transcode_video_pn(state: &AppState, id: &crate::processing_graph::NodeId, args: Value, _kwargs: Value) -> anyhow::Result<Value> {
    // Parse tuple args
    let a = if let Value::Object(o) = &args { o.get("_v").and_then(|v| v.as_array()).cloned().unwrap_or_default() } else { vec![] };
    if a.len() < 6 { anyhow::bail!("invalid args length"); }
    let url = a[0].as_str().ok_or_else(|| anyhow::anyhow!("missing url"))?.to_string();
    let media_url = a[1].as_str().ok_or_else(|| anyhow::anyhow!("missing media_url"))?.to_string();
    let (iw, ih) = if let Value::Object(t) = &a[2] { if let Some(Value::Array(v)) = t.get("_v") { (v[0].as_i64().unwrap_or(0) as i32, v[1].as_i64().unwrap_or(0) as i32) } else { (0,0) } } else { (0,0) };
    let input_duration = a[3].as_f64().unwrap_or(0.0) as f32;
    let (target_ty, target_val) = if let Value::Object(t) = &a[4] { if let Some(Value::Array(v)) = t.get("_v") { (v[0].as_str().unwrap_or(":"), v[1].as_i64().unwrap_or(0) as i32) } else { (":",0) } } else { (":", 0) };
    let bitrate = a[5].as_i64().unwrap_or(1_000_000) as i32;

    transcode_video_pn_impl(state, id, &url, &media_url, iw, ih, input_duration, target_ty, target_val, bitrate).await
}

// Clean implementation of media_video_variants_pn
async fn media_video_variants_pn_impl(
    state: &AppState,
    url: &str,
    media_url: &str,
    iw: i32,
    ih: i32,
    input_duration: f32,
) -> anyhow::Result<Value> {

    let mut targets = vec![];
    if iw >= ih {
        targets.push(("medium", (":height", 480_i32), 1_500_000_i32));
    } else {
        targets.push(("medium", (":width", 720_i32), 2_400_000_i32));
    }
    // Perform transcodes now and collect resulting variants
    let mut out = Vec::new();
    for (size, (ty, val), bitrate) in targets {
        let res = procnode_call!(state, "PrimalServer.Media", "transcode_video_pn",
            [url, media_url, json!({"_ty":"Tuple","_v":[iw, ih]}), input_duration, json!({"_ty":"Tuple","_v":[ty, val]}), bitrate]
        );
        if let Ok((_nid, v)) = res {
            // Expect Tuple (media_url2, (ow, oh))
            if let Value::Object(o) = v { if let Some(Value::Array(t)) = o.get("_v") {
                if t.len() >= 2 { let mu = t[0].as_str().unwrap_or("").to_string(); out.push(json!({"size": size, "animated": true, "media_url": mu})); }
            }}
        }
    }
    Ok(json!({"variants": out}))
}

// Handler that parses args and calls the implementation
pub async fn handler_media_video_variants_pn(state: &AppState, _id: &crate::processing_graph::NodeId, args: Value, _kwargs: Value) -> anyhow::Result<Value> {
    let a = if let Value::Object(o) = &args { o.get("_v").and_then(|v| v.as_array()).cloned().unwrap_or_default() } else { vec![] };
    if a.len() < 4 { anyhow::bail!("invalid args length"); }
    let url = a[0].as_str().unwrap_or("").to_string();
    let media_url = a[1].as_str().unwrap_or("").to_string();
    let (iw, ih) = if let Value::Object(t) = &a[2] { if let Some(Value::Array(v)) = t.get("_v") { (v[0].as_i64().unwrap_or(0) as i32, v[1].as_i64().unwrap_or(0) as i32) } else { (0,0) } } else { (0,0) };
    let input_duration = a[3].as_f64().unwrap_or(0.0) as f32;

    media_video_variants_pn_impl(state, &url, &media_url, iw, ih, input_duration).await
}

// ---- Media import helpers (translated from Julia) ----

// Helper to determine if external storage should be used (Julia lines 317-321)
async fn use_external_storage(pool: &sqlx::PgPool, pubkey: &[u8]) -> anyhow::Result<bool> {
    // Check verified_users
    if sqlx::query!("select 1 as one from verified_users where pubkey = $1 limit 1", pubkey)
        .fetch_optional(pool)
        .await?
        .is_some() {
        return Ok(false);  // Verified users use local storage
    }
    // Check trustrank (UPLOAD_BLOCKED_TRUSTRANK_THRESHOLD default is 0.0 in Julia line 316)
    let threshold = 0.0;
    if sqlx::query!("select 1 as one from pubkey_trustrank where pubkey = $1 and rank >= $2 limit 1", pubkey, threshold)
        .fetch_optional(pool)
        .await?
        .is_none() {
        return Ok(true);  // Low trustrank users use external storage
    }
    Ok(false)
}

pub async fn media_import_local<F>(state: &AppState, key_fields: &[(String, Value)], host: &str, media_path: &str, mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[(String, Value)]) -> anyhow::Result<Vec<u8>> {
    log::debug!("media_import_local ENTRY - host: {}, media_path: {}, key_fields: {:?}", host, media_path, key_fields);
    let key_json = juliaish_json_from_kv(key_fields);
    let h = sha256_hex(key_json.as_bytes());
    log::debug!("media_import_local computed hash: {}", h);

    // Deduplication check - return existing URL if already stored (Julia lines 373-375)
    let rs = sqlx::query!(
        "select h, ext, media_url from media_storage where storage_provider = $1 and h = $2 limit 1",
        host,
        h
    ).fetch_optional(&state.pool).await?;
    if let Some(row) = rs {
        log::debug!("media_import_local found existing entry: {}", row.media_url);
        return Ok(row.media_url);
    }

    log::debug!("media_import_local fetching data from callback");
    let data = fetchfunc(key_fields)?;
    log::debug!("media_import_local fetched {} bytes", data.len());
    let sha = sha2::Sha256::digest(&data);
    let (subdir, _) = subdir_from_h(&h);
    let dirpath = format!("{}/{}", media_path, subdir);
    tokio::fs::create_dir_all(&dirpath).await?;
    let base_path = format!("{}/{}", dirpath, h);
    let rnd = &sha256_hex(rand::random::<[u8;16]>().as_slice())[0..12];

    // Write .key file (Julia lines 380-381)
    let key_tmp_path = format!("{}.key.tmp-{}", base_path, rnd);
    tokio::fs::write(&key_tmp_path, key_json.as_bytes()).await?;
    tokio::fs::rename(&key_tmp_path, format!("{}.key", base_path)).await?;

    // Write data file (Julia lines 382-383)
    let data_tmp_path = format!("{}.tmp-{}", base_path, rnd);
    tokio::fs::write(&data_tmp_path, &data).await?;
    let mt = parse_mimetype(&data).await;
    log::debug!("media_import_local MIME type: {}", mt);
    let ext = mimetype_ext(&mt).to_string();
    let final_path = format!("{}{}", base_path, ext);

    // Move data file to final location with extension (Julia line 386)
    tokio::fs::rename(&data_tmp_path, &final_path).await?;

    // Create symlink: base_path -> base_path.ext (Julia lines 387-395)
    let symlink_tmp = format!("{}.tmp-{}", base_path, rnd);
    #[cfg(unix)]
    {
        let _ = tokio::fs::symlink(format!("{}{}", h, ext), &symlink_tmp).await;
        // Try to move symlink, ignore errors if already exists
        let _ = tokio::fs::rename(&symlink_tmp, &base_path).await;
    }

    let p = format!("{}/{}", last_segment(media_path), subdir);
    let media_url = join_url(&state.config.media.media_url_root, &[&p, &format!("{}{}", h, ext)]);
    log::debug!("media_import_local inserting media_url: {}", media_url);
    let added_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    sqlx::query!(
        "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256) values ($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict do nothing",
        media_url,
        host,
        added_at,
        key_json,
        h,
        ext,
        mt,
        data.len() as i64,
        &sha[..]
    ).execute(&state.pool).await?;
    log::debug!("media_import_local EXIT - returning {}", media_url);
    Ok(media_url)
}

pub async fn media_import<F>(state: &AppState, key_fields: &[(String, Value)], mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[(String, Value)]) -> anyhow::Result<Vec<u8>> {
    log::debug!("ENTRY - key_fields: {:?}", key_fields);
    // Extract pubkey from key if member_upload (Julia lines 326-328)
    let mut pubkey: Option<Vec<u8>> = None;
    for (k, v) in key_fields {
        if k == "type" && v.as_str() == Some("member_upload") {
            for (k2, v2) in key_fields {
                if k2 == "pubkey" {
                    if let Some(pk_str) = v2.as_str() {
                        pubkey = hex::decode(pk_str).ok();
                    }
                }
            }
        }
    }

    // Determine if external storage should be used (Julia lines 330-338)
    let external = if let Some(ref pk) = pubkey {
        use_external_storage(&state.pool, pk).await?
    } else {
        true  // Default to external if no pubkey
    };

    log::debug!("pubkey: {:?}, external: {}", pubkey.as_ref().map(hex::encode), external);

    if let Some(paths) = &state.config.media.media_paths {
        let list = &paths.cache;
        let mut last_err: Option<anyhow::Error> = None;
        log::debug!("Found {} media path(s)", list.len());
        for entry in list {
            match entry {
                MediaPathEntry::Local { host, path } => {
                    // Only use local if NOT external (Julia line 348)
                    if !external {
                        log::debug!("Trying local import - host: {}, path: {}", host, path);
                        match media_import_local(state, key_fields, host, path, |k| fetchfunc(k)).await {
                            Ok(url) => {
                                log::debug!("Local import succeeded: {}", url);
                                return Ok(url);
                            },
                            Err(e) => {
                                log::debug!("Local import failed: {}", e);
                                last_err = Some(e);
                            },
                        }
                    }
                }
                MediaPathEntry::S3 { provider, dir } => {
                    // Only use S3 if external (Julia line 351)
                    if external {
                        log::debug!("Trying S3 import - provider: {}, dir: {}", provider, dir);
                        match media_import_s3(state, key_fields, provider, dir, |k| fetchfunc(k)).await {
                            Ok(url) => {
                                log::debug!("S3 import succeeded: {}", url);
                                return Ok(url);
                            },
                            Err(e) => {
                                log::debug!("S3 import failed: {}", e);
                                last_err = Some(e);
                            },
                        }
                    }
                }
            }
        }
        let err = last_err.unwrap_or_else(|| anyhow::anyhow!("media_import: no providers configured"));
        log::debug!("All providers failed: {}", err);
        Err(err)
    } else {
        // Fallback to single local path
        let host = last_segment(&state.config.media.media_path);
        let media_path = state.config.media.media_path.clone();
        log::debug!("Using fallback local path - host: {}, path: {}", host, media_path);
        media_import_local(state, key_fields, &host, &media_path, fetchfunc).await
    }
}

pub async fn media_import_local_2<F>(state: &AppState, key_fields: &[(String, Value)], sha256: &[u8], host: &str, media_path: &str, mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[u8]) -> anyhow::Result<Vec<u8>> {
    log::debug!("media_import_local_2 ENTRY - host: {}, media_path: {}, sha256: {}", host, media_path, hex::encode(sha256));

    // Deduplication check - return existing URL if already stored (Julia lines 484-486)
    let rs = sqlx::query!(
        "select media_url from media_storage where storage_provider = $1 and sha256 = $2 limit 1",
        host,
        sha256
    ).fetch_optional(&state.pool).await?;
    if let Some(row) = rs {
        log::debug!("media_import_local_2 found existing entry: {}", row.media_url);
        return Ok(row.media_url);
    }

    log::debug!("media_import_local_2 fetching data from callback");
    let data = fetchfunc(sha256)?;
    log::debug!("media_import_local_2 fetched {} bytes", data.len());
    anyhow::ensure!(sha2::Sha256::digest(&data)[..] == *sha256, "sha256 mismatch for media_import_local_2");
    log::debug!("media_import_local_2 SHA256 verified");
    let h = hex::encode(sha256);
    let (subdir, _) = subdir_from_h(&h);
    let dirpath = format!("{}/{}", media_path, subdir);
    tokio::fs::create_dir_all(&dirpath).await?;
    let base_path = format!("{}/{}", dirpath, h);
    let mt = parse_mimetype(&data).await;
    log::debug!("media_import_local_2 MIME type: {}", mt);
    let ext = mimetype_ext(&mt).to_string();
    let rnd = &sha256_hex(rand::random::<[u8;16]>().as_slice())[0..12];

    // Write data file (Julia line 498)
    let data_tmp_path = format!("{}.tmp-{}", base_path, rnd);
    tokio::fs::write(&data_tmp_path, &data).await?;
    let final_path = format!("{}{}", base_path, ext);
    log::debug!("media_import_local_2 wrote temp file, moving to: {}", final_path);

    // Move data file to final location with extension (Julia line 499)
    tokio::fs::rename(&data_tmp_path, &final_path).await?;

    // Create symlink: base_path -> base_path.ext (Julia lines 500-508)
    let symlink_tmp = format!("{}.tmp-{}", base_path, rnd);
    #[cfg(unix)]
    {
        let _ = tokio::fs::symlink(format!("{}{}", h, ext), &symlink_tmp).await;
        // Try to move symlink, ignore errors if already exists
        let _ = tokio::fs::rename(&symlink_tmp, &base_path).await;
    }

    let p = format!("{}/{}", last_segment(media_path), subdir);
    let media_url = join_url(&state.config.media.media_url_root, &[&p, &format!("{}{}", h, ext)]);
    log::debug!("media_import_local_2 inserting media_url: {}", media_url);
    let added_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let key_json = juliaish_json_from_kv(key_fields);

    // Note: For media_import_2, the h field in the DB is the hash of the key, not sha256 (Julia line 512)
    let key_h = sha256_hex(key_json.as_bytes());
    sqlx::query!(
        "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256) values ($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict do nothing",
        media_url,
        host,
        added_at,
        key_json,
        key_h,
        ext,
        mt,
        data.len() as i64,
        sha256
    ).execute(&state.pool).await?;
    log::debug!("media_import_local_2 EXIT - returning {}", media_url);
    Ok(media_url)
}

pub async fn media_import_2<F>(state: &AppState, key_fields: &[(String, Value)], sha256: &[u8], mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[u8]) -> anyhow::Result<Vec<u8>> {
    log::debug!("media_import_2 ENTRY - sha256: {}, key_fields: {:?}", hex::encode(sha256), key_fields);
    // Extract pubkey from key (same logic as media_import)
    let mut pubkey: Option<Vec<u8>> = None;
    for (k, v) in key_fields {
        if k == "type" && v.as_str() == Some("member_upload") {
            for (k2, v2) in key_fields {
                if k2 == "pubkey" {
                    if let Some(pk_str) = v2.as_str() {
                        pubkey = hex::decode(pk_str).ok();
                    }
                }
            }
        }
    }

    // Determine if external storage should be used (Julia lines 443-451)
    let external = if let Some(ref pk) = pubkey {
        use_external_storage(&state.pool, pk).await?
    } else {
        true  // Default to external if no pubkey
    };

    log::debug!("media_import_2 pubkey: {:?}, external: {}", pubkey.as_ref().map(hex::encode), external);

    if let Some(paths) = &state.config.media.media_paths_2 {
        let list = &paths.cache;
        let mut last_err: Option<anyhow::Error> = None;
        let mut result_url: Option<String> = None;
        log::debug!("media_import_2 found {} media path(s)", list.len());
        for entry in list {
            match entry {
                MediaPathEntry::Local { host, path } => {
                    // Only use local if NOT external (Julia line 461)
                    if !external {
                        log::debug!("media_import_2 trying local import - host: {}, path: {}", host, path);
                        match media_import_local_2(state, key_fields, sha256, host, path, |s| fetchfunc(s)).await {
                            Ok(url) => {
                                log::debug!("media_import_2 local import succeeded: {}", url);
                                result_url = Some(url);
                                break;
                            },
                            Err(e) => {
                                log::debug!("media_import_2 local import failed: {}", e);
                                last_err = Some(e);
                            },
                        }
                    }
                }
                MediaPathEntry::S3 { provider, dir } => {
                    // Only use S3 if external (Julia line 464)
                    if external {
                        log::debug!("media_import_2 trying S3 import - provider: {}, dir: {}", provider, dir);
                        match media_import_s3_2(state, key_fields, sha256, provider, dir, |s| fetchfunc(s)).await {
                            Ok(url) => {
                                log::debug!("media_import_2 S3 import succeeded: {}", url);
                                result_url = Some(url);
                                break;
                            },
                            Err(e) => {
                                log::debug!("media_import_2 S3 import failed: {}", e);
                                last_err = Some(e);
                            },
                        }
                    }
                }
            }
        }

        // Transform URL to BLOSSOM_HOST format (Julia line 477)
        if let Some(url) = result_url {
            let blossom_host = &state.config.media.blossom_host;
            if let Ok(parsed) = url::Url::parse(&url) {
                if let Some(filename) = parsed.path_segments().and_then(|s| s.last()) {
                    let result = format!("{}/{}", blossom_host, filename);
                    log::debug!("media_import_2 transformed URL to: {}", result);
                    return Ok(result);
                }
            }
            log::debug!("media_import_2 returning original URL: {}", url);
            Ok(url)  // Fallback to original URL if parsing fails
        } else {
            let err = last_err.unwrap_or_else(|| anyhow::anyhow!("media_import_2: no providers configured"));
            log::debug!("media_import_2 all providers failed: {}", err);
            Err(err)
        }
    } else {
        let host = last_segment(&state.config.media.media_path_2);
        let media_path = state.config.media.media_path_2.clone();
        log::debug!("media_import_2 using fallback local path - host: {}, path: {}", host, media_path);
        let url = media_import_local_2(state, key_fields, sha256, &host, &media_path, fetchfunc).await?;
        // Transform URL to BLOSSOM_HOST format
        let blossom_host = &state.config.media.blossom_host;
        if let Ok(parsed) = url::Url::parse(&url) {
            if let Some(filename) = parsed.path_segments().and_then(|s| s.last()) {
                let result = format!("{}/{}", blossom_host, filename);
                log::debug!("media_import_2 fallback transformed URL to: {}", result);
                return Ok(result);
            }
        }
        log::debug!("media_import_2 fallback returning original URL: {}", url);
        Ok(url)
    }
}

fn find_s3_provider<'a>(cfg: &'a MediaConfig, name: &str) -> Option<&'a S3ProviderConfig> {
    cfg.s3_providers.iter().find(|p| p.name == name).or_else(|| {
        let available = cfg.s3_providers.iter().map(|p| &p.name).collect::<Vec<_>>();
        log::warn!("S3 provider '{}' not found. Available: {:?}", name, available);
        None
    })
}

fn s3_domain(p: &S3ProviderConfig) -> String {
    if let Some(d) = &p.domain { d.clone() } else {
        let host = Url::parse(&p.endpoint).ok().and_then(|u| Some(u.host_str()?.to_string())).unwrap_or_default();
        format!("{}.{}", p.bucket, host)
    }
}

async fn s3_call_json(json_req: &serde_json::Value, data: Option<&[u8]>) -> anyhow::Result<serde_json::Value> {
    info!("s3_call_json: req={}", json_req);

    use aws_config::BehaviorVersion;
    use aws_sdk_s3::{Client, config::Region};
    use aws_sdk_s3::config::Credentials;
    use aws_sdk_s3::primitives::ByteStream;
    use aws_sdk_s3::presigning::PresigningConfig;
    use aws_types::sdk_config::{RequestChecksumCalculation, ResponseChecksumValidation};
    use std::time::Duration;

    let access_key = json_req.get("access_key").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let secret_key = json_req.get("secret_key").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let endpoint   = json_req.get("endpoint").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let region_s   = json_req.get("region").and_then(|v| v.as_str()).unwrap_or("auto").to_string();
    let operation  = json_req.get("operation").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let bucket     = json_req.get("bucket").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let object     = json_req.get("object").and_then(|v| v.as_str()).map(|s| s.to_string());
    let content_type = json_req.get("content_type").and_then(|v| v.as_str()).map(|s| s.to_string());
    let destination_bucket = json_req.get("destination_bucket").and_then(|v| v.as_str()).map(|s| s.to_string());
    let destination_object = json_req.get("destination_object").and_then(|v| v.as_str()).map(|s| s.to_string());
    let source_bucket = json_req.get("source_bucket").and_then(|v| v.as_str()).map(|s| s.to_string());
    let source_object = json_req.get("source_object").and_then(|v| v.as_str()).map(|s| s.to_string());
    let expires = json_req.get("expires").and_then(|v| v.as_u64()).unwrap_or(3600);

    let region = Region::new(region_s);
    let credentials = Credentials::new(access_key, secret_key, None, None, "custom");
    let config = aws_config::defaults(BehaviorVersion::latest())
        .region(region)
        .credentials_provider(credentials)
        .endpoint_url(endpoint)
        .request_checksum_calculation(RequestChecksumCalculation::WhenRequired)
        .response_checksum_validation(ResponseChecksumValidation::WhenRequired)
        .load()
        .await;
    let client = Client::new(&config);

    let res = match operation.as_str() {
        "upload" => {
            let body = ByteStream::from(data.unwrap_or(&[]).to_vec());
            let mut req = client.put_object().bucket(bucket).key(object.clone().unwrap());
            if let Some(ct) = content_type { req = req.content_type(ct); }
            req.body(body).send().await?;
            Ok(json!({"status": true}))
        }
        "check" => {
            let ok = client.head_object().bucket(bucket).key(object.unwrap()).send().await.is_ok();
            Ok(json!({"exists": ok}))
        }
        "get" => {
            let resp = client.get_object().bucket(bucket).key(object.unwrap()).send().await?;
            let bytes = resp.body.collect().await?.into_bytes();
            Ok(json!({"status": true, "data_len": bytes.len()}))
        }
        "delete" => {
            let ok = client.delete_object().bucket(bucket).key(object.unwrap()).send().await.is_ok();
            Ok(json!({"status": ok}))
        }
        "copy" => {
            client.copy_object()
                .bucket(destination_bucket.unwrap())
                .key(destination_object.unwrap())
                .copy_source(format!("{}/{}", source_bucket.unwrap(), source_object.unwrap()))
                .send().await?;
            Ok(json!({"status": true}))
        }
        "pre-sign-url" => {
            let exp = Duration::from_secs(expires);
            let presign_conf = PresigningConfig::expires_in(exp)?;
            let presigned = client.get_object().bucket(bucket).key(object.unwrap()).presigned(presign_conf).await?;
            Ok(json!({"status": true, "url": presigned.uri().to_string()}))
        }
        _ => anyhow::bail!("unsupported s3 operation"),
    };

    info!("s3_call_json: response={:?}", res);

    res
}

pub async fn media_import_s3<F>(state: &AppState, key_fields: &[(String, Value)], provider: &str, dir: &str, mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[(String, Value)]) -> anyhow::Result<Vec<u8>> {
    log::debug!("media_import_s3 ENTRY - provider: {}, dir: {}, key_fields: {:?}", provider, dir, key_fields);
    let p = find_s3_provider(&state.config.media, provider).ok_or_else(|| anyhow::anyhow!("unknown s3 provider"))?;
    let key_json = juliaish_json_from_kv(key_fields);
    let h = sha256_hex(key_json.as_bytes());
    log::debug!("media_import_s3 computed hash: {}", h);

    // Deduplication check - return existing URL if already stored (Julia lines 415-416, 431-432)
    let rs = sqlx::query!(
        "select h, ext, media_url from media_storage where storage_provider = $1 and h = $2 limit 1",
        provider,
        h
    ).fetch_optional(&state.pool).await?;
    if let Some(row) = rs {
        log::debug!("media_import_s3 found existing entry: {}", row.media_url);
        return Ok(row.media_url);
    }

    // Doesn't exist, upload to S3 (Julia lines 417-428)
    let (subdir, _) = subdir_from_h(&h);
    let object = format!("{}/{}/{}", dir.trim_matches('/'), subdir, h);
    log::debug!("media_import_s3 fetching data from callback");
    let data = fetchfunc(key_fields)?;
    log::debug!("media_import_s3 fetched {} bytes", data.len());
    let sha256 = sha2::Sha256::digest(&data);
    let mt = parse_mimetype(&data).await;
    log::debug!("media_import_s3 MIME type: {}", mt);
    let ext = mimetype_ext(&mt);
    let object_ext = format!("{}{}", object, ext);
    log::debug!("media_import_s3 uploading S3 object: {}", object_ext);
    let req = json!({
        "operation":"upload",
        "access_key": p.access_key,
        "secret_key": p.secret_key,
        "endpoint": p.endpoint,
        "region": p.region,
        "bucket": p.bucket,
        "object": object_ext,
        "content_type": mt
    });
    let _ = s3_call_json(&req, Some(&data)).await?;
    let domain = s3_domain(p);
    let media_url = format!("https://{}/{}", domain, object_ext);
    log::debug!("media_import_s3 inserting media_url: {}", media_url);
    let added_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    sqlx::query!(
        "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256) values ($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict do nothing",
        media_url, provider, added_at, key_json, h, ext, mt, data.len() as i64, &sha256[..]
    ).execute(&state.pool).await?;
    log::debug!("media_import_s3 EXIT - returning {}", media_url);
    Ok(media_url)
}

pub async fn media_import_s3_2<F>(state: &AppState, key_fields: &[(String, Value)], sha256: &[u8], provider: &str, dir: &str, mut fetchfunc: F) -> anyhow::Result<String>
where F: FnMut(&[u8]) -> anyhow::Result<Vec<u8>> {
    let p = find_s3_provider(&state.config.media, provider).ok_or_else(|| anyhow::anyhow!("unknown s3 provider"))?;

    // Deduplication check - return existing URL if already stored (Julia lines 526-527, 546-547)
    let rs = sqlx::query!(
        "select media_url from media_storage where storage_provider = $1 and sha256 = $2 limit 1",
        provider,
        sha256
    ).fetch_optional(&state.pool).await?;
    if let Some(row) = rs {
        log::debug!("media_import_s3_2 found existing entry: {}", row.media_url);
        return Ok(row.media_url);
    }

    // Doesn't exist, upload to S3 (Julia lines 528-545)
    let h = hex::encode(sha256);
    let (subdir, _) = subdir_from_h(&h);
    let object = format!("{}/{}/{}", dir.trim_matches('/'), subdir, h);
    let data = fetchfunc(sha256)?;
    anyhow::ensure!(sha2::Sha256::digest(&data)[..] == *sha256, "sha256 mismatch for s3_2");
    let mt = parse_mimetype(&data).await;
    let ext = mimetype_ext(&mt);
    let object_ext = format!("{}{}", object, ext);
    let req = json!({
        "operation":"upload",
        "access_key": p.access_key,
        "secret_key": p.secret_key,
        "endpoint": p.endpoint,
        "region": p.region,
        "bucket": p.bucket,
        "object": object_ext,
        "content_type": mt
    });
    let _ = s3_call_json(&req, Some(&data)).await?;
    let domain = s3_domain(p);
    let media_url = format!("https://{}/{}", domain, object_ext);
    let added_at = (time::OffsetDateTime::now_utc().unix_timestamp()) as i64;
    let key_json = juliaish_json_from_kv(key_fields);
    sqlx::query!(
        "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256) values ($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict do nothing",
        media_url, provider, added_at, key_json, sha256_hex(key_json.as_bytes()), ext, mt, data.len() as i64, sha256
    ).execute(&state.pool).await?;
    Ok(media_url)
}

