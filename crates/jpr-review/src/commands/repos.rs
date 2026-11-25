//! `jpr-review repos`: lists GitHub repositories for a user or organization as JSON.

use std::env;

use anyhow::{Context, Result};
use review_forge_github::GhForge;

use crate::theme::Theme;

/// Runs `jpr-review repos`: lists repositories for `owner` (or the authenticated
/// viewer when omitted) as a JSON array on stdout.
pub fn run(owner: Option<&str>, limit: u32, theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    if let Some(login) = owner {
        review_forge_github::discovery::validate_owner_login(login)?;
    }
    super::narrate(theme, "Listing GitHub repositories...");
    let repos = GhForge::new(cwd, None)
        .list_repos(owner, limit)
        .context("listing GitHub repositories")?;
    println!(
        "{}",
        serde_json::to_string(&repos).context("serializing GitHub repositories")?
    );
    Ok(())
}
