//! `jpr-review owners`: lists the authenticated GitHub user and organizations as JSON.

use std::env;

use anyhow::{Context, Result};
use review_forge_github::GhForge;

use crate::theme::Theme;

/// Runs `jpr-review owners`: lists the authenticated user profile and
/// organizations as a JSON array on stdout.
pub fn run(theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    super::narrate(theme, "Listing GitHub accounts...");
    let owners = GhForge::new(cwd, None)
        .list_owners()
        .context("listing GitHub accounts")?;
    println!(
        "{}",
        serde_json::to_string(&owners).context("serializing GitHub accounts")?
    );
    Ok(())
}
