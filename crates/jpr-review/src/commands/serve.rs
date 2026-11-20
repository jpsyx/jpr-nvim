use std::env;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use review_core::ReviewSession;
use review_core::ports::SystemClock;
use review_forge_github::GhForge;
use review_rpc::ServeOptions;
use review_store_fs::FsStore;

/// Runs `jpr-review serve` for pull request `number` of `repo` (owner/name).
///
/// It speaks JSON-RPC on stdin and stdout until the client shuts it down or
/// closes stdin. The Neovim plugin starts one per review tab; `poll` is the
/// seconds between background syncs, 0 for none.
pub fn run(number: u64, repo: &str, poll: u64) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    let cwd = env::current_dir().context("reading the current directory")?;
    let store = FsStore::new(super::state_dir(&owner, &name, number)?);
    let forge = GhForge::new(cwd.clone(), Some(repo.to_owned()));
    let mut session = ReviewSession::open(
        number,
        Box::new(forge),
        Box::new(store),
        Box::new(SystemClock),
    )?;
    session.record_daemon(std::process::id(), &cwd.to_string_lossy())?;
    let options = ServeOptions {
        server_version: env!("CARGO_PKG_VERSION").to_owned(),
        poll_every: poll_interval(poll),
    };
    review_rpc::serve(
        io::stdin().lock(),
        &Arc::new(Mutex::new(io::stdout())),
        &Arc::new(Mutex::new(session)),
        &options,
    )
}

/// `--poll` seconds as an interval; 0 turns background syncing off.
#[must_use]
pub const fn poll_interval(seconds: u64) -> Option<Duration> {
    if seconds == 0 {
        None
    } else {
        Some(Duration::from_secs(seconds))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_turns_polling_off() {
        assert_eq!(poll_interval(0), None);
        assert_eq!(poll_interval(60), Some(Duration::from_secs(60)));
    }
}
