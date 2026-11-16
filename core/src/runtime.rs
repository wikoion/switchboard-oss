//! The core owns one Tokio runtime. matrix-sdk spawns its own background
//! tasks, so every call from Dart runs inside it rather than on the bridge's
//! executor.

use std::{future::Future, sync::LazyLock};

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("switchboard-core")
        .build()
        .expect("tokio runtime")
});

/// Runs `fut` on the core runtime and waits for it.
pub(crate) async fn run<F, T>(fut: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match RUNTIME.spawn(fut).await {
        Ok(v) => v,
        Err(e) => std::panic::resume_unwind(e.into_panic()),
    }
}

/// Starts `fut` on the core runtime without waiting for it.
pub(crate) fn spawn<F>(fut: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    RUNTIME.spawn(fut);
}
