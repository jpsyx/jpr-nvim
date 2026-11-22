use anyhow::{Context, Result};
use review_core::ports::ReviewStore;
use review_model::{Origin, Thread};
use serde_json::{Value, json};

use super::socket_client::{TargetContext, execute_via_socket_or_store};

/// Runs `jpr-review threads`: prints review threads as JSON on stdout.
pub fn run(target: TargetContext<'_>, is_local_only: bool) -> Result<()> {
    let threads = execute_via_socket_or_store(
        target,
        "threads",
        &json!({}),
        |result| parse_threads_from_rpc(result, is_local_only),
        |store| {
            let snapshot = store.load()?;
            let mut combined = snapshot.registry.threads;
            combined.extend(snapshot.local.threads);
            if is_local_only {
                combined.retain(|thread| thread.origin == Origin::Local);
            }
            Ok(combined)
        },
    )?;
    println!(
        "{}",
        serde_json::to_string(&json!({ "threads": threads }))
            .context("serializing threads output")?
    );
    Ok(())
}

fn parse_threads_from_rpc(mut result: Value, is_local_only: bool) -> Result<Vec<Thread>> {
    let raw = result
        .get_mut("threads")
        .map(Value::take)
        .context("missing threads array in daemon reply")?;
    let mut threads: Vec<Thread> =
        serde_json::from_value(raw).context("decoding threads from daemon reply")?;
    if is_local_only {
        threads.retain(|thread| thread.origin == Origin::Local);
    }
    Ok(threads)
}
