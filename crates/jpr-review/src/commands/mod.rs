//! Subcommand dispatch and the helpers commands share.

/// `checkout`: put a pull request in its own worktree and say where.
pub mod checkout;
/// `guide`: print the agent review and reply contract.
pub mod guide;
/// `prepass-write`: write pre-pass findings as answered local threads.
pub mod prepass_write;
/// `prs`: list open pull requests as JSON.
pub mod prs;
/// `reply`: append an agent reply to a local thread.
pub mod reply;
/// `serve`: one pull request's review session, as JSON-RPC on stdin/stdout.
pub mod serve;
/// Shared Unix socket client, target resolution, and UTC timestamp formatting.
pub mod socket_client;
/// `state-path`: where a pull request's review state lives on this machine.
pub mod state_path;
/// `threads`: list review threads as JSON.
pub mod threads;

use std::env;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::cli::{Cli, Command};
use crate::prompt::{self, Question};
use crate::theme::Theme;

/// Runs a single resolved subcommand.
pub fn run_command(command: &Command, theme: Theme) -> Result<()> {
    match command {
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
        Command::Guide => guide::run(),
        Command::Prs { repo, limit } => prs::run(repo.as_deref(), *limit, theme),
        Command::Serve { pr, repo, poll } => serve::run(*pr, repo, *poll),
        Command::StatePath { pr, repo } => {
            let number = pr_number(*pr, theme)?;
            state_path::run(number, &repo_name(repo.as_deref(), theme)?)
        }
        other => run_agent_command(other, theme),
    }
}

/// Runs the subcommand parsed into `cli`, or fails when no subcommand is present.
pub fn run(cli: &Cli, theme: Theme) -> Result<()> {
    let command = cli
        .command
        .as_ref()
        .context("no subcommand specified; run `jpr-review --help` for usage")?;
    run_command(command, theme)
}

fn run_agent_command(command: &Command, theme: Theme) -> Result<()> {
    match command {
        Command::Threads {
            pr,
            repo,
            socket,
            is_local_only,
        } => run_with_target_context(socket.as_deref(), *pr, repo.as_deref(), theme, |target| {
            threads::run(target, *is_local_only)
        }),
        Command::Reply {
            thread_id,
            body,
            pr,
            repo,
            socket,
        } => run_with_target_context(socket.as_deref(), *pr, repo.as_deref(), theme, |target| {
            reply::run(thread_id.as_deref(), body.as_deref(), target)
        }),
        Command::PrepassWrite {
            input,
            pr,
            repo,
            socket,
        } => run_with_target_context(socket.as_deref(), *pr, repo.as_deref(), theme, |target| {
            prepass_write::run(input.as_deref(), target)
        }),
        Command::Checkout { .. }
        | Command::Guide
        | Command::Prs { .. }
        | Command::Serve { .. }
        | Command::StatePath { .. } => unreachable!("handled by commands::run_command"),
    }
}

fn run_with_target_context(
    socket: Option<&Path>,
    pr: Option<u64>,
    repo: Option<&str>,
    theme: Theme,
    action: impl FnOnce(socket_client::TargetContext<'_>) -> Result<()>,
) -> Result<()> {
    let socket_override = get_socket_override_from_cli(socket, pr.is_some() || repo.is_some())?;
    let target = create_target_context(socket_override.as_ref(), pr, repo, theme)?;
    action(target)
}

enum CliSocketOverride {
    Explicit(PathBuf),
    Env(PathBuf),
}

impl CliSocketOverride {
    fn as_override(&self) -> socket_client::SocketOverride<'_> {
        match self {
            Self::Explicit(path) => socket_client::SocketOverride::Explicit(path),
            Self::Env(path) => socket_client::SocketOverride::Env(path),
        }
    }
}

fn create_target_context<'a>(
    socket: Option<&'a CliSocketOverride>,
    pr: Option<u64>,
    repo: Option<&'a str>,
    theme: Theme,
) -> Result<socket_client::TargetContext<'a>> {
    Ok(socket_client::TargetContext {
        socket: socket.map(CliSocketOverride::as_override),
        pr: get_pr_number_from_flag_or_env(pr, repo.is_some())?,
        repo,
        theme,
    })
}

fn get_socket_override_from_cli(
    flag: Option<&Path>,
    has_explicit_target: bool,
) -> Result<Option<CliSocketOverride>> {
    if let Some(path) = flag {
        if path.as_os_str().is_empty() || path.to_string_lossy().trim().is_empty() {
            bail!("--socket path cannot be empty");
        }
        return Ok(Some(CliSocketOverride::Explicit(path.to_path_buf())));
    }
    if has_explicit_target {
        return Ok(None);
    }
    Ok(env::var_os("JPR_SOCKET")
        .filter(|value| !value.to_string_lossy().trim().is_empty())
        .map(PathBuf::from)
        .map(CliSocketOverride::Env))
}

fn get_pr_number_from_flag_or_env(
    flag: Option<u64>,
    has_explicit_repo: bool,
) -> Result<Option<u64>> {
    if flag.is_some() {
        return Ok(flag);
    }
    if has_explicit_repo {
        return Ok(None);
    }
    let Ok(raw) = env::var("JPR_PR") else {
        return Ok(None);
    };
    if raw.trim().is_empty() {
        return Ok(None);
    }
    parse_pr_number(&raw).map(Some)
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

    #[test]
    fn run_fails_when_no_subcommand_is_present() {
        let cli = Cli { command: None };
        let error =
            run(&cli, Theme::dark(false)).expect_err("bare Cli should fail in commands::run");
        assert!(error.to_string().contains("no subcommand specified"));
    }
}
