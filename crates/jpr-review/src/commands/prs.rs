use std::env;

use anyhow::{Context, Result};
use review_forge_github::GhForge;

use crate::theme::Theme;

/// Runs `jpr-review prs`: lists open pull requests as a JSON array on stdout.
pub fn run(repo: Option<&str>, limit: u32, theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    if let Some(target_repo) = repo {
        let _ = super::parse_repo(target_repo)?;
    }
    super::narrate(theme, "Listing open pull requests...");
    let summaries = GhForge::new(cwd, repo.map(str::to_owned))
        .open_pull_requests(limit)
        .context("listing open pull requests")?;
    println!(
        "{}",
        serde_json::to_string(&summaries).context("serializing open pull requests")?
    );
    Ok(())
}
