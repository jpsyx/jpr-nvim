//! Conversion from completed `cli-tui` [`Answers`] maps into typed [`Command`] values.

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use cli_tui::Answers;

use crate::cli::Command;
use crate::commands;

/// Converts completed interactive `answers` for `command_id` into a typed [`Command`].
pub fn answers_to_command(command_id: &str, answers: &Answers) -> Result<Command> {
    match command_id {
        "prs" => answers_to_prs(answers),
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

struct ResolvedTarget {
    pr: Option<u64>,
    repo: Option<String>,
    socket: Option<PathBuf>,
}

fn answers_to_prs(answers: &Answers) -> Result<Command> {
    let repo = if is_answer_true(answers, "custom_repo") {
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
    let repo = if is_answer_true(answers, "custom_repo") {
        Some(parse_required_repo(answers, "repo")?)
    } else {
        None
    };
    let worktree_cmd = if is_answer_true(answers, "custom_worktree") {
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
        is_local_only: is_answer_true(answers, "is_local_only"),
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

fn answers_to_state_path(answers: &Answers) -> Result<Command> {
    Ok(Command::StatePath {
        pr: Some(parse_required_pr(answers, "pr")?),
        repo: Some(parse_required_repo(answers, "repo")?),
    })
}

fn answers_to_serve(answers: &Answers) -> Result<Command> {
    let pr = parse_required_pr(answers, "pr")?;
    let repo = parse_required_repo(answers, "repo")?;
    let raw_poll = answers.get("poll").map_or("60", String::as_str).trim();
    let poll: u64 = raw_poll
        .parse()
        .with_context(|| format!("{raw_poll:?} is not a valid poll interval"))?;
    Ok(Command::Serve { pr, repo, poll })
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

fn is_answer_true(answers: &Answers, step_id: &str) -> bool {
    answers.get(step_id).map(String::as_str) == Some("true")
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
