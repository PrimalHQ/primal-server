use primal_media::media;

/// A minimal ISO base media file header; `file` reports it as video/mp4.
const MP4_FTYP: &[u8] = b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2avc1mp41";

fn mp4_of_size(len: usize) -> Vec<u8> {
    let mut data = MP4_FTYP.to_vec();
    data.resize(len, 0);
    data
}

#[tokio::test]
async fn test_parse_mimetype_small() {
    assert_eq!(media::parse_mimetype(&mp4_of_size(64 * 1024)).await, "video/mp4");
}

/// `file` reads at most a few MB (7 MiB for file-5.45) from stdin and then
/// exits, so writing a larger buffer fails with EPIPE. That used to be
/// reported as "application/octet-stream", silently mislabelling every blob
/// over ~7 MB.
#[tokio::test]
async fn test_parse_mimetype_larger_than_file_read_limit() {
    for len in [8 * 1024 * 1024, 64 * 1024 * 1024] {
        assert_eq!(
            media::parse_mimetype(&mp4_of_size(len)).await,
            "video/mp4",
            "wrong mimetype for a {len}-byte blob"
        );
    }
}

#[tokio::test]
async fn test_parse_mimetype_empty() {
    assert_eq!(media::parse_mimetype(&[]).await, "inode/x-empty");
}
