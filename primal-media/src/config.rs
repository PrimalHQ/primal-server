use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub database_url: Option<String>,
    #[serde(default)]
    pub database: Option<DbConfig>,
    #[serde(default)]
    pub scheduler: SchedulerConfig,
    #[serde(default)]
    pub media: MediaConfig,
    #[serde(default)]
    pub tasks: TaskConfig,
    #[serde(default)]
    pub log_level: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database_url: None,
            database: Some(DbConfig::default()),
            scheduler: SchedulerConfig::default(),
            media: MediaConfig::default(),
            tasks: TaskConfig::default(),
            log_level: Some("info".to_string()),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DbConfig {
    #[serde(default = "DbConfig::default_host")]
    pub host: String,
    #[serde(default = "DbConfig::default_port")]
    pub port: u16,
    #[serde(default = "DbConfig::default_user")]
    pub user: String,
    #[serde(default = "DbConfig::default_dbname")]
    pub dbname: String,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub sslmode: Option<String>,
    #[serde(default = "DbConfig::default_statement_timeout_secs")]
    pub statement_timeout_secs: u64,
    #[serde(default = "DbConfig::default_acquire_timeout_secs")]
    pub acquire_timeout_secs: u64,
}

impl Default for DbConfig {
    fn default() -> Self {
        Self {
            host: Self::default_host(),
            port: Self::default_port(),
            user: Self::default_user(),
            dbname: Self::default_dbname(),
            password: None,
            sslmode: None,
            statement_timeout_secs: Self::default_statement_timeout_secs(),
            acquire_timeout_secs: Self::default_acquire_timeout_secs(),
        }
    }
}

impl DbConfig {
    fn default_host() -> String { "127.0.0.1".into() }
    fn default_port() -> u16 { 54017 }
    fn default_user() -> String { "pr".into() }
    fn default_dbname() -> String { "primal1".into() }
    fn default_statement_timeout_secs() -> u64 { 360 } // 6 minutes
    fn default_acquire_timeout_secs() -> u64 { 360 }   // 6 minutes
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SchedulerConfig {
    #[serde(default = "SchedulerConfig::default_period_ms")] 
    pub period_ms: u64,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self { period_ms: 1000 }
    }
}

impl SchedulerConfig {
    pub fn default_period_ms() -> u64 { 1000 }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MediaConfig {
    #[serde(default)]
    pub media_path: String,
    #[serde(default)]
    pub media_path_2: String,
    #[serde(default)]
    pub media_url_root: String,
    #[serde(default)]
    pub tmp_dir: String,
    #[serde(default)]
    pub proxies: Vec<String>,
    #[serde(default)]
    pub metadata_proxy: Option<String>,
    #[serde(default)]
    pub ssh_command: Vec<String>,
    #[serde(default = "MediaConfig::default_download_timeout_secs")]
    pub download_timeout_secs: u64,
    #[serde(default)]
    pub video_transcoding_server: Option<String>,
    #[serde(default)]
    pub video_transcoding_ffmpeg_path: Option<String>,
    #[serde(default)]
    pub strip_image_metadata: bool,
    #[serde(default)]
    pub s3_providers: Vec<S3ProviderConfig>,
    #[serde(default)]
    pub hls_providers: Vec<HlsProviderConfig>,
    #[serde(default = "MediaConfig::default_hls_processing_timeout_secs")]
    pub hls_processing_timeout_secs: u64,
    #[serde(default)]
    pub media_paths: Option<MediaPaths>,
    #[serde(default)]
    pub media_paths_2: Option<MediaPaths>,
    #[serde(default = "MediaConfig::default_ai_host")]
    pub ai_host: String,
    #[serde(default = "MediaConfig::default_ai_timeout_secs")]
    pub ai_timeout_secs: u64,
    #[serde(default = "MediaConfig::default_blossom_host")]
    pub blossom_host: String,
    #[serde(default = "MediaConfig::default_binary_data_cache_dir")]
    pub binary_data_cache_dir: String,
}

impl Default for MediaConfig {
    fn default() -> Self {
        Self {
            media_path: "/mnt/ppr1/var/www/cdn/cache".into(),
            media_path_2: "/mnt/ppr1/var/www/cdn/cache2".into(),
            media_url_root: "https://media.primal.net/cache".into(),
            tmp_dir: "/mnt/ppr1/var/www/cdn/cache/tmp".into(),
            proxies: vec![],
            metadata_proxy: None,
            ssh_command: vec![],
            download_timeout_secs: Self::default_download_timeout_secs(),
            video_transcoding_server: None,
            video_transcoding_ffmpeg_path: None,
            strip_image_metadata: false,
            s3_providers: vec![],
            hls_providers: vec![],
            hls_processing_timeout_secs: Self::default_hls_processing_timeout_secs(),
            media_paths: None,
            media_paths_2: None,
            ai_host: Self::default_ai_host(),
            ai_timeout_secs: Self::default_ai_timeout_secs(),
            blossom_host: Self::default_blossom_host(),
            binary_data_cache_dir: Self::default_binary_data_cache_dir(),
        }
    }
}

impl MediaConfig {
    fn default_download_timeout_secs() -> u64 { 30 }
    fn default_hls_processing_timeout_secs() -> u64 { 600 }
    fn default_ai_host() -> String { "192.168.52.1".to_string() }
    fn default_ai_timeout_secs() -> u64 { 30 }
    fn default_blossom_host() -> String { "blossom.primal.net".to_string() }
    fn default_binary_data_cache_dir() -> String { "./cache/procgraph".to_string() }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct S3ProviderConfig {
    pub name: String,
    pub bucket: String,
    pub endpoint: String,
    pub region: String,
    #[serde(default)]
    pub domain: Option<String>,
    pub access_key: String,
    pub secret_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HlsProviderConfig {
    #[serde(rename = "type")]
    pub provider_type: String, // "aws", "mux", "bunny", "cloudflare"
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub api_secret: Option<String>,
    #[serde(default)]
    pub api_token: Option<String>, // For Cloudflare (preferred over api_key)
    #[serde(default)]
    pub account_id: Option<String>, // For Cloudflare account ID
    #[serde(default)]
    pub region: Option<String>,
    #[serde(default)]
    pub endpoint: Option<String>,
    #[serde(default)]
    pub library_id: Option<String>, // For Bunny Stream
    #[serde(default)]
    pub cdn_hostname: Option<String>, // For Bunny Stream
    #[serde(default)]
    pub role_arn: Option<String>, // For AWS MediaConvert IAM role
    #[serde(default)]
    pub s3_output_bucket: Option<String>, // For AWS MediaConvert S3 output
    #[serde(default)]
    pub s3_output_path: Option<String>, // For AWS MediaConvert S3 output path prefix
    #[serde(default)]
    pub abr_profiles: Option<Vec<AbrProfile>>, // For AWS adaptive bitrate profiles
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AbrProfile {
    pub name: String,
    pub width: i32,
    pub height: i32,
    pub video_bitrate: i32,
    pub audio_bitrate: i32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum MediaPathEntry {
    Local { host: String, path: String },
    S3 { provider: String, dir: String },
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MediaPaths {
    #[serde(default)]
    pub uploadfast: Vec<MediaPathEntry>,
    #[serde(default)]
    pub upload: Vec<MediaPathEntry>,
    #[serde(default)]
    pub cache: Vec<MediaPathEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskConfig {
    #[serde(default = "TaskConfig::default_ntasks")]
    pub ntasks: u32,
    #[serde(default = "TaskConfig::default_limit")]
    pub limit: u32,
    #[serde(default = "TaskConfig::default_max_concurrent_per_name")]
    pub max_concurrent_per_name: usize,
}

impl Default for TaskConfig {
    fn default() -> Self { Self { ntasks: 10, limit: 100, max_concurrent_per_name: 1 } }
}

impl TaskConfig {
    pub fn default_ntasks() -> u32 { 10 }
    pub fn default_limit() -> u32 { 100 }
    pub fn default_max_concurrent_per_name() -> usize { 1 }
}

impl Config {
    pub fn from_path(path: &str) -> anyhow::Result<Self> {
        let s = std::fs::read_to_string(path)
            .with_context(|| format!("reading config file: {}", path))?;
        let mut cfg: Config = serde_json::from_str(&s)
            .with_context(|| "parsing config json")?;
        // Fill defaults where necessary
        if cfg.database.is_none() && cfg.database_url.is_none() {
            cfg.database = Some(DbConfig::default());
        }
        Ok(cfg)
    }

    pub fn database_url(&self) -> String {
        if let Some(url) = &self.database_url {
            return url.clone();
        }
        let db = self.database.clone().unwrap_or_default();
        let auth = if let Some(pass) = db.password.filter(|p| !p.is_empty()) {
            format!(":{}", urlencoding::encode(&pass))
        } else { String::new() };
        let ssl = db.sslmode.as_deref().unwrap_or("");
        let suffix = if ssl.is_empty() { String::new() } else { format!("?sslmode={}", ssl) };
        format!(
            "postgres://{}{}@{}:{}/{}{}",
            db.user,
            auth,
            db.host,
            db.port,
            db.dbname,
            suffix
        )
    }
}
