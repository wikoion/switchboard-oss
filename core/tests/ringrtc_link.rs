//! RingRTC's prebuilt libwebrtc.a carries its own BoringSSL, and rustls brings
//! in aws-lc. This links and runs both in one binary.
#![cfg(target_os = "linux")]

use ringrtc::webrtc::peer_connection_factory::{AudioConfig, PeerConnectionFactory};

#[tokio::test]
async fn ringrtc_links_next_to_rustls() {
    let client = matrix_sdk::Client::builder()
        .homeserver_url("https://example.invalid")
        .build()
        .await
        .expect("matrix client");
    drop(client);

    let factory = PeerConnectionFactory::new(&AudioConfig::default(), false, "", None)
        .expect("peer connection factory");
    factory.create_outgoing_audio_track().expect("audio track");
}
