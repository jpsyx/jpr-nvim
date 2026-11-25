//! Conversion from completed `cli-tui` [`Answers`] maps into typed [`Command`] values.

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use cli_tui::Answers;

use super::steps::{has_answer_value, non_empty_env};
use crate::cli::Command;
use crate::commands;

/// Converts completed interactive `answers` for `command_id` into a typed [`Command`].
pub fn answers_to_command(command_id: &str, answers: &Answers) -> Result<Command> {
    match command_id {
        "prs" => answers_to_prs(answers),
        "local" => answers_to_local(answers),
        "checkout" => answers_to_checkout(answers),
        "threads" => answers_to_threads(answers),
        "reply" => answers_to_reply(answers),
        "prepass-write" => answers_to_prepass_write(answers),
        "state-path" => answers_to_state_path(answers),
        "serve" => answers_to_serve(answers),
        "guide" => Ok(Command::Guide),
        other => bail!("unknown command id {other:?}"),
    }
}

/// Applies interactive `answers` onto a partially specified `original` [`Command`],
/// preserving ambient `$JPR_SOCKET` fallback when the user did not supply or edit `--socket`.
pub fn apply_answers_to_command(original: &Command, answers: &Answers) -> Result<Command> {
    apply_answers_to_command_with_env(original, answers, non_empty_env("JPR_SOCKET").as_deref())
}

pub(super) fn apply_answers_to_command_with_env(
    original: &Command,
    answers: &Answers,
    env_socket: Option<&str>,
) -> Result<Command> {
    let mut resolved = answers_to_command(command_id_for_command(original), answers)?;
    if !has_ambient_socket_origin(original) {
        return Ok(resolved);
    }
    if let Some(ambient_socket) = env_socket {
        clear_matching_ambient_socket(&mut resolved, ambient_socket);
    }
    Ok(resolved)
}

const fn command_id_for_command(command: &Command) -> &'static str {
    match command {
        Command::Checkout { .. } => "checkout",
        Command::Local { .. } => "local",
        Command::Guide => "guide",
        Command::Threads { .. } => "threads",
        Command::Reply { .. } => "reply",
        Command::PrepassWrite { .. } => "prepass-write",
        Command::Prs { .. } => "prs",
        Command::Serve { .. } => "serve",
        Command::StatePath { .. } => "state-path",
    }
}

const fn has_ambient_socket_origin(command: &Command) -> bool {
    match command {
        Command::Threads {
            pr, repo, socket, ..
        }
        | Command::Reply {
            pr, repo, socket, ..
        }
        | Command::PrepassWrite {
            pr, repo, socket, ..
        } => socket.is_none() && pr.is_none() && repo.is_none(),
        Command::Checkout { .. }
        | Command::Local { .. }
        | Command::Guide
        | Command::Prs { .. }
        | Command::Serve { .. }
        | Command::StatePath { .. } => false,
    }
}

fn clear_matching_ambient_socket(command: &mut Command, ambient_socket: &str) {
    let target_socket = match command {
        Command::Threads { socket, .. }
        | Command::Reply { socket, .. }
        | Command::PrepassWrite { socket, .. } => socket,
        Command::Checkout { .. }
        | Command::Local { .. }
        | Command::Guide
        | Command::Prs { .. }
        | Command::Serve { .. }
        | Command::StatePath { .. } => return,
    };
    if target_socket
        .as_deref()
        .is_some_and(|path| path.to_str() == Some(ambient_socket))
    {
        *target_socket = None;
    }
}

struct ResolvedTarget {
    pr: Option<u64>,
    repo: Option<String>,
    socket: Option<PathBuf>,
}

fn answers_to_prs(answers: &Answers) -> Result<Command> {
    let repo = if has_answer_value(answers, "custom_repo", "true") {
        Some(parse_required_repo(answers, "repo")?)
    } else {
        None
    };
    let raw_limit = answers.get("limit").map_or("50", String::as_str).trim();
    let limit: u32 = raw_limit
        .parse()
        .with_context(|| format!("{raw_limit:?} is not a valid limit"))?;
    if limit == 0 {
        bail!("limit must be at least 1");
    }
    Ok(Command::Prs { repo, limit })
}

fn answers_to_checkout(answers: &Answers) -> Result<Command> {
    let pr = match answers.get("source").map(String::as_str) {
        Some("manual") => parse_required_pr(answers, "pr_manual")?,
        Some("list") | None => parse_required_pr(answers, "pr")?,
        Some(other) => bail!("unknown checkout source {other:?}"),
    };
    let repo = if has_answer_value(answers, "custom_repo", "true") {
        Some(parse_required_repo(answers, "repo")?)
    } else {
        None
    };
    let worktree_cmd = if has_answer_value(answers, "custom_worktree", "true") {
        Some(require_non_empty(answers, "worktree_cmd")?)
    } else {
        None
    };
    Ok(Command::Checkout {
        pr: Some(pr),
        repo,
        worktree_cmd,
    })
}

fn answers_to_threads(answers: &Answers) -> Result<Command> {
    let target = answers_to_target(answers)?;
    Ok(Command::Threads {
        pr: target.pr,
        repo: target.repo,
        socket: target.socket,
        is_local_only: has_answer_value(answers, "is_local_only", "true"),
    })
}

fn answers_to_reply(answers: &Answers) -> Result<Command> {
    let target = answers_to_target(answers)?;
    let thread_id = require_non_empty(answers, "thread_id")?;
    let body = require_non_empty(answers, "body")?;
    Ok(Command::Reply {
        thread_id: Some(thread_id),
        body: Some(body),
        pr: target.pr,
        repo: target.repo,
        socket: target.socket,
    })
}

fn answers_to_prepass_write(answers: &Answers) -> Result<Command> {
    let target = answers_to_target(answers)?;
    let input = match answers.get("input_mode").map(String::as_str) {
        Some("file") => Some(PathBuf::from(require_non_empty(answers, "input")?)),
        Some("stdin") => None,
        Some(other) => bail!("unknown prepass input mode {other:?}"),
        None => bail!("missing input_mode answer"),
    };
    Ok(Command::PrepassWrite {
        input,
        pr: target.pr,
        repo: target.repo,
        socket: target.socket,
    })
}

fn answers_to_local(answers: &Answers) -> Result<Command> {
    match answers.get("base_mode").map(String::as_str) {
        Some("custom") => {
            let base = require_non_empty(answers, "base")?;
            review_workspace_git::validate_git_ref(&base)?;
            Ok(Command::Local {
                base: Some(base),
                repo: None,
                no_pr: false,
            })
        }
        Some("auto") | None => {
            let no_pr = has_answer_value(answers, "detect_pr", "false");
            let repo = if !no_pr && has_answer_value(answers, "custom_repo", "true") {
                Some(parse_required_repo(answers, "repo")?)
            } else {
                None
            };
            Ok(Command::Local {
                base: None,
                repo,
                no_pr,
            })
        }
        Some(other) => bail!("unknown local base mode {other:?}"),
    }
}

fn answers_to_state_path(answers: &Answers) -> Result<Command> {
    match answers.get("session_mode").map(String::as_str) {
        Some("local") => Ok(Command::StatePath {
            pr: None,
            is_local: true,
            repo: None,
        }),
        Some("pr") | None => Ok(Command::StatePath {
            pr: Some(parse_required_pr(answers, "pr")?),
            is_local: false,
            repo: Some(parse_required_repo(answers, "repo")?),
        }),
        Some(other) => bail!("unknown state-path session mode {other:?}"),
    }
}

fn answers_to_serve(answers: &Answers) -> Result<Command> {
    let raw_poll = answers.get("poll").map_or("60", String::as_str).trim();
    let poll: u64 = raw_poll
        .parse()
        .with_context(|| format!("{raw_poll:?} is not a valid poll interval"))?;
    match answers.get("session_mode").map(String::as_str) {
        Some("local") => {
            let base = answers
                .get("base")
                .map(|raw| raw.trim())
                .filter(|trimmed| !trimmed.is_empty())
                .map(str::to_owned);
            if let Some(ref base_ref) = base {
                review_workspace_git::validate_git_ref(base_ref)?;
            }
            Ok(Command::Serve {
                pr: None,
                is_local: true,
                base,
                repo: None,
                poll,
            })
        }
        Some("pr") | None => {
            let pr = parse_required_pr(answers, "pr")?;
            let repo = parse_required_repo(answers, "repo")?;
            Ok(Command::Serve {
                pr: Some(pr),
                is_local: false,
                base: None,
                repo: Some(repo),
                poll,
            })
        }
        Some(other) => bail!("unknown serve session mode {other:?}"),
    }
}

fn answers_to_target(answers: &Answers) -> Result<ResolvedTarget> {
    match answers.get("target_mode").map(String::as_str) {
        Some("socket") => Ok(ResolvedTarget {
            pr: None,
            repo: None,
            socket: Some(PathBuf::from(require_non_empty(answers, "socket")?)),
        }),
        Some("pr") => {
            let pr = parse_required_pr(answers, "pr")?;
            let repo = parse_optional_repo(answers, "repo")?;
            Ok(ResolvedTarget {
                pr: Some(pr),
                repo,
                socket: None,
            })
        }
        Some(other) => bail!("unknown target mode {other:?}"),
        None => bail!("missing target_mode answer"),
    }
}

fn require_non_empty(answers: &Answers, step_id: &str) -> Result<String> {
    let value = answers
        .get(step_id)
        .map(|raw| raw.trim())
        .filter(|trimmed| !trimmed.is_empty())
        .with_context(|| format!("missing required answer `{step_id}`"))?;
    Ok(value.to_owned())
}

fn parse_required_pr(answers: &Answers, step_id: &str) -> Result<u64> {
    let raw = require_non_empty(answers, step_id)?;
    commands::parse_pr_number(&raw)
}

fn parse_required_repo(answers: &Answers, step_id: &str) -> Result<String> {
    let raw = require_non_empty(answers, step_id)?;
    let _ = commands::parse_repo(&raw)?;
    Ok(raw)
}

fn parse_optional_repo(answers: &Answers, step_id: &str) -> Result<Option<String>> {
    let Some(trimmed) = answers
        .get(step_id)
        .map(|raw| raw.trim())
        .filter(|trimmed| !trimmed.is_empty())
    else {
        return Ok(None);
    };
    let _ = commands::parse_repo(trimmed)?;
    Ok(Some(trimmed.to_owned()))
}
