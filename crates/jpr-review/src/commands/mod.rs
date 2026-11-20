//! Subcommand dispatch and the helpers commands share.

/// `checkout`: put a pull request in its own worktree and say where.
pub mod checkout;
/// `serve`: one pull request's review session, as JSON-RPC on stdin/stdout.
pub mod serve;
/// `state-path`: where a pull request's review state lives on this machine.
pub mod state_path;

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

use crate::cli::{Cli, Command};
use crate::prompt::{self, Question};
use crate::theme::Theme;

/// Runs the command the arguments selected.
pub fn run(cli: &Cli, theme: Theme) -> Result<()> {
    match &cli.command {
        Command::Checkout {
            pr,
            repo,
            worktree_cmd,
        } => checkout::run(
            pr_number(*pr, theme)?,
            repo.as_deref(),
            worktree_cmd.as_deref(),
            theme,
        ),
        Command::Serve { pr, repo, poll } => serve::run(*pr, repo, *poll),
        Command::StatePath { pr, repo } => {
            let number = pr_number(*pr, theme)?;
            state_path::run(number, &repo_name(repo.as_deref(), theme)?)
        }
    }
}

/// The pull request number: the flag, else asked for on a terminal.
pub fn pr_number(flag: Option<u64>, theme: Theme) -> Result<u64> {
    if let Some(number) = flag {
        return Ok(number);
    }
    let question = Question::new(
        "pull request number",
        "Which pull request?",
        "--pr <NUMBER>",
    );
    parse_pr_number(&prompt::ask(&question, theme)?)
}

/// Reads `12` or `#12`.
pub fn parse_pr_number(answer: &str) -> Result<u64> {
    let trimmed = answer.trim();
    trimmed
        .strip_prefix('#')
        .unwrap_or(trimmed)
        .parse()
        .with_context(|| format!("{trimmed:?} is not a pull request number"))
}

/// The repository: the flag, else asked for on a terminal.
pub fn repo_name(flag: Option<&str>, theme: Theme) -> Result<String> {
    if let Some(repo) = flag {
        return Ok(repo.to_owned());
    }
    let question = Question::new(
        "repository",
        "Which repository (owner/name)?",
        "--repo <OWNER/NAME>",
    );
    prompt::ask(&question, theme)
}

/// Splits `owner/name`.
pub fn parse_repo(value: &str) -> Result<(String, String)> {
    match value.split_once('/') {
        Some((owner, name)) if !owner.is_empty() && !name.is_empty() && !name.contains('/') => {
            Ok((owner.to_owned(), name.to_owned()))
        }
        _ => bail!("expected the repository as owner/name, got {value:?}"),
    }
}

/// This machine's state directory for a pull request.
pub fn state_dir(owner: &str, name: &str, number: u64) -> Result<PathBuf> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")?;
    let xdg = env::var_os("XDG_STATE_HOME").map(PathBuf::from);
    review_store_fs::state_dir(xdg.as_deref(), &home, crate::STATE_APP, owner, name, number)
}

/// Says what the tool is about to do, on stderr.
pub fn narrate(theme: Theme, message: &str) {
    eprintln!("{}", theme.info(message));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_pull_request_numbers() {
        assert_eq!(parse_pr_number("12").unwrap(), 12);
        assert_eq!(parse_pr_number(" #34\n").unwrap(), 34);
        assert!(parse_pr_number("abc").is_err());
    }

    #[test]
    fn splits_owner_and_name() {
        assert_eq!(
            parse_repo("octo/widgets").unwrap(),
            ("octo".to_owned(), "widgets".to_owned())
        );
        assert!(parse_repo("widgets").is_err());
        assert!(parse_repo("/widgets").is_err());
        assert!(parse_repo("a/b/c").is_err());
    }
}
