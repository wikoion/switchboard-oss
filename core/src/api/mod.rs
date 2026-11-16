//! Everything Dart can call. Kept small: app-level operations, not the SDK.

pub mod calls;
pub mod client;
pub mod types;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "warn,switchboard_core=info".into()),
        )
        .try_init();
}
