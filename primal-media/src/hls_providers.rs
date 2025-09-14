use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::time::sleep;
use uuid::Uuid;

use crate::config::HlsProviderConfig;

/// Status of an HLS transcoding job
#[derive(Debug, Clone, PartialEq)]
pub enum JobStatus {
    Queued,
    Processing,
    Completed,
    Failed(String),
}

/// Result of a transcoding job
#[derive(Debug, Clone)]
pub struct TranscodingResult {
    pub hls_url: String,
    pub provider: String,
    pub asset_id: String,
}

/// Trait for HLS transcoding providers
#[async_trait]
pub trait HlsProvider: Send + Sync {
    /// Submit a video URL for transcoding
    async fn submit_job(&self, video_url: &str) -> Result<String>;

    /// Poll the status of a job
    async fn poll_status(&self, job_id: &str) -> Result<(JobStatus, Option<String>)>;

    /// Delete an asset by its ID
    async fn delete_asset(&self, asset_id: &str) -> Result<()>;

    /// Get the provider name
    fn get_provider_name(&self) -> &str;

    /// Process a video URL with polling until completion
    /// Returns a tuple of (HLS URL, asset ID)
    async fn process_video(&self, video_url: &str, max_wait_secs: u64) -> Result<(String, String)> {
        let job_id = self.submit_job(video_url).await?;

        let start = std::time::Instant::now();
        let mut backoff_ms = 2000; // Start with 2 seconds

        loop {
            if start.elapsed().as_secs() > max_wait_secs {
                return Err(anyhow!("Timeout waiting for transcoding to complete"));
            }

            sleep(Duration::from_millis(backoff_ms)).await;

            match self.poll_status(&job_id).await? {
                (JobStatus::Completed, Some(hls_url)) => {
                    return Ok((hls_url, job_id.clone()));
                }
                (JobStatus::Failed(err), _) => {
                    return Err(anyhow!("Transcoding failed: {}", err));
                }
                (JobStatus::Processing, _) | (JobStatus::Queued, _) => {
                    // Exponential backoff up to 30 seconds
                    backoff_ms = (backoff_ms * 3 / 2).min(30000);
                    continue;
                }
                (JobStatus::Completed, None) => {
                    return Err(anyhow!("Job completed but no HLS URL returned"));
                }
            }
        }
    }
}

/// Create an HLS provider from configuration
pub async fn create_provider(config: &HlsProviderConfig, http_client: reqwest::Client) -> Result<Box<dyn HlsProvider>> {
    match config.provider_type.as_str() {
        "aws" => {
            let provider = AwsMediaConvertProvider::new(config, http_client).await?;
            Ok(Box::new(provider))
        }
        "mux" => {
            let provider = MuxProvider::new(config, http_client)?;
            Ok(Box::new(provider))
        }
        "bunny" => {
            let provider = BunnyStreamProvider::new(config, http_client)?;
            Ok(Box::new(provider))
        }
        "cloudflare" => {
            let provider = CloudflareStreamProvider::new(config, http_client)?;
            Ok(Box::new(provider))
        }
        _ => Err(anyhow!("Unknown HLS provider type: {}", config.provider_type)),
    }
}

// ============================================================================
// AWS MediaConvert Provider
// ============================================================================

pub struct AwsMediaConvertProvider {
    config: HlsProviderConfig,
    client: aws_sdk_mediaconvert::Client,
    role_arn: String,
    s3_output_bucket: String,
    s3_output_path: String,
    abr_profiles: Vec<crate::config::AbrProfile>,
}

impl AwsMediaConvertProvider {
    pub async fn new(config: &HlsProviderConfig, _client: reqwest::Client) -> Result<Self> {
        let region = config.region.clone()
            .ok_or_else(|| anyhow!("AWS region is required"))?;
        let role_arn = config.role_arn.clone()
            .ok_or_else(|| anyhow!("AWS MediaConvert IAM role ARN is required"))?;
        let s3_output_bucket = config.s3_output_bucket.clone()
            .ok_or_else(|| anyhow!("AWS S3 output bucket is required"))?;
        let s3_output_path = config.s3_output_path.clone()
            .unwrap_or_else(|| "hls-output".to_string());

        // Get ABR profiles or use defaults
        let abr_profiles = config.abr_profiles.clone().unwrap_or_else(|| {
            // Default adaptive bitrate profiles
            vec![
                crate::config::AbrProfile {
                    name: "1080p".to_string(),
                    width: 1920,
                    height: 1080,
                    video_bitrate: 5000000,
                    audio_bitrate: 128000,
                },
                crate::config::AbrProfile {
                    name: "720p".to_string(),
                    width: 1280,
                    height: 720,
                    video_bitrate: 3000000,
                    audio_bitrate: 128000,
                },
                crate::config::AbrProfile {
                    name: "480p".to_string(),
                    width: 854,
                    height: 480,
                    video_bitrate: 1500000,
                    audio_bitrate: 96000,
                },
                crate::config::AbrProfile {
                    name: "360p".to_string(),
                    width: 640,
                    height: 360,
                    video_bitrate: 800000,
                    audio_bitrate: 96000,
                },
            ]
        });

        // Build AWS config
        let mut aws_config_builder = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_config::Region::new(region));

        // If credentials are provided in config, use them
        if let (Some(access_key), Some(secret_key)) = (&config.api_key, &config.api_secret) {
            aws_config_builder = aws_config_builder.credentials_provider(
                aws_sdk_mediaconvert::config::Credentials::new(
                    access_key,
                    secret_key,
                    None,
                    None,
                    "HlsProviderConfig",
                )
            );
        }

        let sdk_config = aws_config_builder.load().await;

        // Create MediaConvert client
        let mut mediaconvert_config = aws_sdk_mediaconvert::config::Builder::from(&sdk_config);

        // Set custom endpoint if provided (for account-specific endpoint)
        if let Some(endpoint) = &config.endpoint {
            mediaconvert_config = mediaconvert_config.endpoint_url(endpoint);
        }

        let client = aws_sdk_mediaconvert::Client::from_conf(mediaconvert_config.build());

        Ok(Self {
            config: config.clone(),
            client,
            role_arn,
            s3_output_bucket,
            s3_output_path,
            abr_profiles,
        })
    }
}

#[async_trait]
impl HlsProvider for AwsMediaConvertProvider {
    async fn submit_job(&self, video_url: &str) -> Result<String> {
        use aws_sdk_mediaconvert::types::{
            AccelerationSettings, AccelerationMode, JobSettings, Input, Output,
            OutputGroup, OutputGroupSettings, HlsGroupSettings, HlsStreamInfResolution,
            AudioDescription, VideoDescription, H264Settings, H264CodecProfile,
            H264RateControlMode, AudioCodecSettings, AacSettings, AacCodecProfile, AacRateControlMode,
            AacCodingMode, ContainerSettings, ContainerType, OutputGroupType, AudioSelector,
            AudioDefaultSelection,
        };

        // Generate unique output path based on UUID
        let job_id = Uuid::new_v4();
        let job_name = format!("hls_transcode_{}", job_id);
        let s3_destination = format!("s3://{}/{}/{}/hls",
            self.s3_output_bucket,
            self.s3_output_path,
            job_id
        );

        // Create audio selector for the input
        // Use default selection to automatically select the first audio track
        let audio_selector = AudioSelector::builder()
            .default_selection(AudioDefaultSelection::Default)
            .build();

        // Create input with audio selector
        let input = Input::builder()
            .file_input(video_url)
            .audio_selectors("Audio Selector 1", audio_selector)
            .build();

        // Create HLS output group
        let hls_group_settings = HlsGroupSettings::builder()
            .destination(&s3_destination)
            .stream_inf_resolution(HlsStreamInfResolution::Include)
            .segment_length(6)
            .min_segment_length(0)
            .build();

        let output_group_settings = OutputGroupSettings::builder()
            .r#type(OutputGroupType::HlsGroupSettings)
            .hls_group_settings(hls_group_settings)
            .build();

        // Create multiple outputs for adaptive bitrate streaming
        let mut outputs = Vec::new();

        for profile in &self.abr_profiles {
            // Create video codec settings for this profile
            let h264_settings = H264Settings::builder()
                .rate_control_mode(H264RateControlMode::Qvbr)
                .codec_profile(H264CodecProfile::Main)
                .max_bitrate(profile.video_bitrate)
                .build();

            let video_description = VideoDescription::builder()
                .width(profile.width)
                .height(profile.height)
                .codec_settings(
                    aws_sdk_mediaconvert::types::VideoCodecSettings::builder()
                        .codec(aws_sdk_mediaconvert::types::VideoCodec::H264)
                        .h264_settings(h264_settings)
                        .build()
                )
                .build();

            // Create audio codec settings for this profile
            let aac_settings = AacSettings::builder()
                .codec_profile(AacCodecProfile::Lc)
                .rate_control_mode(AacRateControlMode::Cbr)
                .coding_mode(AacCodingMode::CodingMode20)
                .sample_rate(48000)
                .bitrate(profile.audio_bitrate)
                .build();

            let audio_codec_settings = AudioCodecSettings::builder()
                .codec(aws_sdk_mediaconvert::types::AudioCodec::Aac)
                .aac_settings(aac_settings)
                .build();

            let audio_description = AudioDescription::builder()
                .audio_source_name("Audio Selector 1")
                .codec_settings(audio_codec_settings)
                .build();

            // Create output with HLS container
            let container_settings = ContainerSettings::builder()
                .container(ContainerType::M3U8)
                .build();

            // Name modifier helps identify different renditions
            let name_modifier = format!("_{}", profile.name);

            let output = Output::builder()
                .name_modifier(&name_modifier)
                .container_settings(container_settings)
                .video_description(video_description)
                .audio_descriptions(audio_description)
                .build();

            outputs.push(output);
        }

        let output_group = OutputGroup::builder()
            .name("HLS ABR Group")
            .output_group_settings(output_group_settings)
            .set_outputs(Some(outputs))
            .build();

        // Create job settings
        // Note: Audio selectors are automatically created from audio descriptions
        let job_settings = JobSettings::builder()
            .inputs(input)
            .output_groups(output_group)
            .build();

        // Create acceleration settings
        let acceleration_settings = AccelerationSettings::builder()
            .mode(AccelerationMode::Disabled)
            .build();

        // Submit the job
        let create_job_output = self.client
            .create_job()
            .role(&self.role_arn)
            .settings(job_settings)
            .acceleration_settings(acceleration_settings)
            .set_user_metadata(Some({
                let mut metadata = std::collections::HashMap::new();
                metadata.insert("source_url".to_string(), video_url.to_string());
                metadata.insert("job_name".to_string(), job_name);
                metadata
            }))
            .send()
            .await
            .context("Failed to create MediaConvert job")?;

        let job = create_job_output.job()
            .ok_or_else(|| anyhow!("No job returned from create_job"))?;

        let job_id = job.id()
            .ok_or_else(|| anyhow!("No job ID in response"))?;

        Ok(job_id.to_string())
    }

    async fn poll_status(&self, job_id: &str) -> Result<(JobStatus, Option<String>)> {
        use aws_sdk_mediaconvert::types::JobStatus as AwsJobStatus;

        let get_job_output = self.client
            .get_job()
            .id(job_id)
            .send()
            .await
            .context("Failed to get MediaConvert job status")?;

        let job = get_job_output.job()
            .ok_or_else(|| anyhow!("No job returned from get_job"))?;

        let status = job.status()
            .ok_or_else(|| anyhow!("No status in job"))?;

        let job_status = match status {
            AwsJobStatus::Submitted => JobStatus::Queued,
            AwsJobStatus::Progressing => JobStatus::Processing,
            AwsJobStatus::Complete => JobStatus::Completed,
            AwsJobStatus::Canceled => JobStatus::Failed("Job was canceled".to_string()),
            AwsJobStatus::Error => {
                let error_msg = job.error_message()
                    .unwrap_or("Unknown error")
                    .to_string();
                JobStatus::Failed(error_msg)
            },
            _ => JobStatus::Processing,
        };

        let hls_url = if job_status == JobStatus::Completed {
            // Extract HLS URL from job outputs
            job.settings()
                .and_then(|settings| settings.output_groups().first())
                .and_then(|group| group.output_group_settings())
                .and_then(|settings| settings.hls_group_settings())
                .and_then(|hls| hls.destination())
                .map(|dest| {
                    // Convert s3:// URL to https:// URL for playback
                    // Format: s3://bucket/path/ -> https://bucket.s3.region.amazonaws.com/path/master.m3u8
                    if dest.starts_with("s3://") {
                        let path = dest.strip_prefix("s3://").unwrap_or(dest);
                        if let Some((bucket, path)) = path.split_once('/') {
                            format!("https://{}.s3.amazonaws.com/{}.m3u8", bucket, path)
                        } else {
                            dest.to_string()
                        }
                    } else {
                        dest.to_string()
                    }
                })
        } else {
            None
        };

        Ok((job_status, hls_url))
    }

    async fn delete_asset(&self, asset_id: &str) -> Result<()> {
        // For AWS MediaConvert, we need to delete the S3 objects
        // The asset_id is the job_id, we need to extract the S3 path from it
        // Get job details to find the output location
        let get_job_output = self.client
            .get_job()
            .id(asset_id)
            .send()
            .await
            .context("Failed to get MediaConvert job for deletion")?;

        let job = get_job_output.job()
            .ok_or_else(|| anyhow!("No job returned from get_job"))?;

        // Extract S3 destination from job settings
        if let Some(settings) = job.settings() {
            if let Some(output_groups) = settings.output_groups().first() {
                if let Some(og_settings) = output_groups.output_group_settings() {
                    if let Some(hls_settings) = og_settings.hls_group_settings() {
                        if let Some(destination) = hls_settings.destination() {
                            // Parse S3 URI (s3://bucket/path/)
                            if let Some(s3_path) = destination.strip_prefix("s3://") {
                                let parts: Vec<&str> = s3_path.splitn(2, '/').collect();
                                if parts.len() == 2 {
                                    let bucket = parts[0];
                                    let prefix = parts[1];

                                    // Delete all objects with this prefix
                                    
                                    let region = self.config.region.clone()
                                        .ok_or_else(|| anyhow!("AWS region is required"))?;
                                    let mut aws_config_builder = aws_config::defaults(aws_config::BehaviorVersion::latest())
                                        .region(aws_config::Region::new(region));

                                    // If credentials are provided in config, use them
                                    if let (Some(access_key), Some(secret_key)) = (&self.config.api_key, &self.config.api_secret) {
                                        aws_config_builder = aws_config_builder.credentials_provider(
                                            aws_sdk_s3::config::Credentials::new(
                                                access_key,
                                                secret_key,
                                                None,
                                                None,
                                                "HlsProviderConfig",
                                            )
                                        );
                                    }
                                    let sdk_config = aws_config_builder.load().await;

                                    let s3_client = aws_sdk_s3::Client::new(&sdk_config);

                                    // List and delete objects
                                    let list_output = s3_client
                                        .list_objects_v2()
                                        .bucket(bucket)
                                        .prefix(prefix)
                                        .send()
                                        .await
                                        .context("Failed to list S3 objects")?;

                                    let contents = list_output.contents();
                                    for object in contents {
                                        if let Some(key) = object.key() {
                                            s3_client
                                                .delete_object()
                                                .bucket(bucket)
                                                .key(key)
                                                .send()
                                                .await
                                                .context(format!("Failed to delete S3 object: {}", key))?;
                                        }
                                    }

                                    return Ok(());
                                }
                            }
                        }
                    }
                }
            }
        }

        Err(anyhow!("Could not determine S3 location for job {}", asset_id))
    }

    fn get_provider_name(&self) -> &str {
        "aws"
    }
}

// ============================================================================
// Mux.com Provider
// ============================================================================

pub struct MuxProvider {
    token_id: String,
    token_secret: String,
    client: reqwest::Client,
}

#[derive(Serialize)]
struct MuxCreateAssetRequest {
    input: Vec<MuxInput>,
    playback_policy: Vec<String>,
}

#[derive(Serialize)]
struct MuxInput {
    url: String,
}

#[derive(Deserialize)]
struct MuxCreateAssetResponse {
    data: MuxAsset,
}

#[derive(Deserialize)]
struct MuxAsset {
    id: String,
    status: String,
    playback_ids: Option<Vec<MuxPlaybackId>>,
}

#[derive(Deserialize)]
struct MuxPlaybackId {
    id: String,
}

#[derive(Deserialize)]
struct MuxGetAssetResponse {
    data: MuxAsset,
}

impl MuxProvider {
    pub fn new(config: &HlsProviderConfig, client: reqwest::Client) -> Result<Self> {
        let token_id = config.api_key.clone()
            .ok_or_else(|| anyhow!("Mux API token ID is required"))?;
        let token_secret = config.api_secret.clone()
            .ok_or_else(|| anyhow!("Mux API token secret is required"))?;

        Ok(Self {
            token_id,
            token_secret,
            client,
        })
    }
}

#[async_trait]
impl HlsProvider for MuxProvider {
    async fn submit_job(&self, video_url: &str) -> Result<String> {
        let url = "https://api.mux.com/video/v1/assets";

        let request_body = MuxCreateAssetRequest {
            input: vec![MuxInput {
                url: video_url.to_string(),
            }],
            playback_policy: vec!["public".to_string()],
        };

        let response = self.client
            .post(url)
            .basic_auth(&self.token_id, Some(&self.token_secret))
            .json(&request_body)
            .send()
            .await
            .context("Failed to submit Mux job")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Mux API error {}: {}", status, body));
        }

        let response_data: MuxCreateAssetResponse = response.json().await
            .context("Failed to parse Mux response")?;

        Ok(response_data.data.id)
    }

    async fn poll_status(&self, job_id: &str) -> Result<(JobStatus, Option<String>)> {
        let url = format!("https://api.mux.com/video/v1/assets/{}", job_id);

        let response = self.client
            .get(&url)
            .basic_auth(&self.token_id, Some(&self.token_secret))
            .send()
            .await
            .context("Failed to poll Mux status")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Mux API error {}: {}", status, body));
        }

        let response_data: MuxGetAssetResponse = response.json().await
            .context("Failed to parse Mux status response")?;

        let asset = response_data.data;

        let job_status = match asset.status.as_str() {
            "preparing" | "waiting" => JobStatus::Queued,
            "ready" => JobStatus::Completed,
            "errored" => JobStatus::Failed(format!("Mux asset in errored state")),
            _ => JobStatus::Processing,
        };

        let hls_url = if job_status == JobStatus::Completed {
            asset.playback_ids.and_then(|ids| ids.first().map(|id| {
                format!("https://stream.mux.com/{}.m3u8", id.id)
            }))
        } else {
            None
        };

        Ok((job_status, hls_url))
    }

    async fn delete_asset(&self, asset_id: &str) -> Result<()> {
        let url = format!("https://api.mux.com/video/v1/assets/{}", asset_id);

        let response = self.client
            .delete(&url)
            .basic_auth(&self.token_id, Some(&self.token_secret))
            .send()
            .await
            .context("Failed to delete Mux asset")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Mux delete API error {}: {}", status, body));
        }

        Ok(())
    }

    fn get_provider_name(&self) -> &str {
        "mux"
    }
}

// ============================================================================
// Bunny Stream Provider
// ============================================================================

pub struct BunnyStreamProvider {
    api_key: String,
    library_id: String,
    cdn_hostname: String,
    client: reqwest::Client,
}

#[derive(Serialize)]
struct BunnyCreateVideoRequest {
    title: String,
}

#[derive(Deserialize)]
struct BunnyCreateVideoResponse {
    guid: String,
}

#[derive(Serialize)]
struct BunnyFetchVideoRequest {
    url: String,
}

#[derive(Deserialize)]
struct BunnyVideoStatus {
    status: i32,
    #[serde(rename = "availableResolutions")]
    #[allow(dead_code)]
    available_resolutions: Option<String>,
}

impl BunnyStreamProvider {
    pub fn new(config: &HlsProviderConfig, client: reqwest::Client) -> Result<Self> {
        let api_key = config.api_key.clone()
            .ok_or_else(|| anyhow!("Bunny Stream API key is required"))?;
        let library_id = config.library_id.clone()
            .ok_or_else(|| anyhow!("Bunny Stream library ID is required"))?;
        let cdn_hostname = config.cdn_hostname.clone()
            .ok_or_else(|| anyhow!("Bunny Stream CDN hostname is required"))?;

        Ok(Self {
            api_key,
            library_id,
            cdn_hostname,
            client,
        })
    }
}

#[async_trait]
impl HlsProvider for BunnyStreamProvider {
    async fn submit_job(&self, video_url: &str) -> Result<String> {
        // Step 1: Create video object
        let create_url = format!("https://video.bunnycdn.com/library/{}/videos", self.library_id);

        let create_body = BunnyCreateVideoRequest {
            title: format!("video_{}", chrono::Utc::now().timestamp()),
        };

        let response = self.client
            .post(&create_url)
            .header("AccessKey", &self.api_key)
            .json(&create_body)
            .send()
            .await
            .context("Failed to create Bunny video")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Bunny API error {}: {}", status, body));
        }

        let create_response: BunnyCreateVideoResponse = response.json().await
            .context("Failed to parse Bunny create response")?;

        let video_id = create_response.guid;

        // Step 2: Fetch video from URL
        let fetch_url = format!("https://video.bunnycdn.com/library/{}/videos/{}/fetch",
            self.library_id, video_id);

        let fetch_body = BunnyFetchVideoRequest {
            url: video_url.to_string(),
        };

        let response = self.client
            .post(&fetch_url)
            .header("AccessKey", &self.api_key)
            .json(&fetch_body)
            .send()
            .await
            .context("Failed to fetch Bunny video")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Bunny fetch API error {}: {}", status, body));
        }

        Ok(video_id)
    }

    async fn poll_status(&self, job_id: &str) -> Result<(JobStatus, Option<String>)> {
        let url = format!("https://video.bunnycdn.com/library/{}/videos/{}",
            self.library_id, job_id);

        let response = self.client
            .get(&url)
            .header("AccessKey", &self.api_key)
            .send()
            .await
            .context("Failed to poll Bunny status")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Bunny API error {}: {}", status, body));
        }

        let video_status: BunnyVideoStatus = response.json().await
            .context("Failed to parse Bunny status response")?;

        // Status codes: 0=Queued, 1=Processing, 2=Encoding, 3=Finished, 4=Resolution finished, 5=Error
        let job_status = match video_status.status {
            0 => JobStatus::Queued,
            1 | 2 => JobStatus::Processing,
            3 | 4 => JobStatus::Completed,
            5 => JobStatus::Failed("Encoding error".to_string()),
            _ => JobStatus::Processing,
        };

        let hls_url = if job_status == JobStatus::Completed {
            Some(format!("https://{}/{}/playlist.m3u8", self.cdn_hostname, job_id))
        } else {
            None
        };

        Ok((job_status, hls_url))
    }

    async fn delete_asset(&self, asset_id: &str) -> Result<()> {
        let url = format!("https://video.bunnycdn.com/library/{}/videos/{}",
            self.library_id, asset_id);

        let response = self.client
            .delete(&url)
            .header("AccessKey", &self.api_key)
            .send()
            .await
            .context("Failed to delete Bunny video")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Bunny delete API error {}: {}", status, body));
        }

        Ok(())
    }

    fn get_provider_name(&self) -> &str {
        "bunny"
    }
}

// ============================================================================
// Cloudflare Stream Provider
// ============================================================================

pub struct CloudflareStreamProvider {
    account_id: String,
    api_token: String,
    client: reqwest::Client,
}

#[derive(Serialize)]
struct CloudflareCreateStreamRequest {
    url: String,
    meta: CloudflareStreamMeta,
}

#[derive(Serialize)]
struct CloudflareStreamMeta {
    name: String,
}

#[derive(Deserialize)]
struct CloudflareStreamResponse {
    result: CloudflareStreamResult,
    success: bool,
    errors: Vec<CloudflareError>,
}

#[derive(Deserialize)]
struct CloudflareStreamResult {
    uid: String,
    status: CloudflareStreamStatus,
    playback: Option<CloudflarePlayback>,
}

#[derive(Deserialize)]
struct CloudflareStreamStatus {
    state: String,
}

#[derive(Deserialize)]
struct CloudflarePlayback {
    hls: String,
}

#[derive(Deserialize)]
struct CloudflareError {
    message: String,
}

impl CloudflareStreamProvider {
    pub fn new(config: &HlsProviderConfig, client: reqwest::Client) -> Result<Self> {
        // Prefer api_token field, fallback to api_key for backward compatibility
        let api_token = config.api_token.clone()
            .or_else(|| config.api_key.clone())
            .ok_or_else(|| anyhow!("Cloudflare API token is required (use 'api_token' field)"))?;

        // Prefer account_id field, fallback to api_secret for backward compatibility
        let account_id = config.account_id.clone()
            .or_else(|| config.api_secret.clone())
            .ok_or_else(|| anyhow!("Cloudflare account ID is required (use 'account_id' field)"))?;

        Ok(Self {
            account_id,
            api_token,
            client,
        })
    }
}

#[async_trait]
impl HlsProvider for CloudflareStreamProvider {
    async fn submit_job(&self, video_url: &str) -> Result<String> {
        let url = format!("https://api.cloudflare.com/client/v4/accounts/{}/stream/copy",
            self.account_id);

        let request_body = CloudflareCreateStreamRequest {
            url: video_url.to_string(),
            meta: CloudflareStreamMeta {
                name: format!("video_{}", chrono::Utc::now().timestamp()),
            },
        };

        let response = self.client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .json(&request_body)
            .send()
            .await
            .context("Failed to submit Cloudflare Stream job")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Cloudflare API error {}: {}", status, body));
        }

        let response_data: CloudflareStreamResponse = response.json().await
            .context("Failed to parse Cloudflare response")?;

        if !response_data.success {
            let errors: Vec<String> = response_data.errors.iter()
                .map(|e| e.message.clone())
                .collect();
            return Err(anyhow!("Cloudflare API errors: {}", errors.join(", ")));
        }

        Ok(response_data.result.uid)
    }

    async fn poll_status(&self, job_id: &str) -> Result<(JobStatus, Option<String>)> {
        let url = format!("https://api.cloudflare.com/client/v4/accounts/{}/stream/{}",
            self.account_id, job_id);

        let response = self.client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .send()
            .await
            .context("Failed to poll Cloudflare status")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Cloudflare API error {}: {}", status, body));
        }

        let response_data: CloudflareStreamResponse = response.json().await
            .context("Failed to parse Cloudflare status response")?;

        if !response_data.success {
            let errors: Vec<String> = response_data.errors.iter()
                .map(|e| e.message.clone())
                .collect();
            return Err(anyhow!("Cloudflare API errors: {}", errors.join(", ")));
        }

        let result = response_data.result;

        let job_status = match result.status.state.as_str() {
            "queued" | "downloading" => JobStatus::Queued,
            "processing" | "encoding" => JobStatus::Processing,
            "ready" => JobStatus::Completed,
            "error" => JobStatus::Failed("Cloudflare Stream encoding error".to_string()),
            _ => JobStatus::Processing,
        };

        let hls_url = if job_status == JobStatus::Completed {
            result.playback.map(|p| p.hls)
        } else {
            None
        };

        Ok((job_status, hls_url))
    }

    async fn delete_asset(&self, asset_id: &str) -> Result<()> {
        let url = format!("https://api.cloudflare.com/client/v4/accounts/{}/stream/{}",
            self.account_id, asset_id);

        let response = self.client
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .send()
            .await
            .context("Failed to delete Cloudflare Stream video")?;

        let status = response.status();

        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("Cloudflare delete API error {}: {}", status, body));
        }

        // Handle 204 No Content or empty responses
        if status == 204 {
            return Ok(());
        }

        let body_text = response.text().await
            .context("Failed to read Cloudflare delete response body")?;

        if body_text.is_empty() {
            return Ok(());
        }

        let response_data: CloudflareStreamResponse = serde_json::from_str(&body_text)
            .context("Failed to parse Cloudflare delete response")?;

        if !response_data.success {
            let errors: Vec<String> = response_data.errors.iter()
                .map(|e| e.message.clone())
                .collect();
            return Err(anyhow!("Cloudflare delete API errors: {}", errors.join(", ")));
        }

        Ok(())
    }

    fn get_provider_name(&self) -> &str {
        "cloudflare"
    }
}
