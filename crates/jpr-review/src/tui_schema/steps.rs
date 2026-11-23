//! Shared step factories, validators, and dynamic option loaders for `tui_schema`.

use std::env;
use std::sync::Arc;

use anyhow::{Context, Result};
use cli_tui::{Answers, SelectOption, StepKind, StepSpec};
use review_forge_github::GhForge;
use review_model::PullRequestSummary;

use crate::commands;

const DEFAULT_PR_LIST_LIMIT: u32 = 50;

/// Formats an open pull request summary as a [`SelectOption`] for interactive pickers.
#[must_use]
pub fn pull_request_summary_to_option(summary: &PullRequestSummary) -> SelectOption {
    let mut option = SelectOption::new(
        summary.number.to_string(),
        format!("#{}  {}", summary.number, summary.title),
    )
    .with_help(format!("@{} \u{00b7} {}", summary.author, summary.head_ref));
    if summary.is_draft {
        option = option.with_badge("draft");
    }
    option
}

pub(super) fn non_empty_env(variable_name: &str) -> Option<String> {
    env::var(variable_name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

pub(super) fn answer_equals(answers: &Answers, step_id: &str, expected: &str) -> bool {
    answers.get(step_id).map(String::as_str) == Some(expected)
}

pub(super) fn create_custom_repo_steps(
    toggle_help: &str,
    default_help: &str,
    custom_help: &str,
) -> Vec<StepSpec> {
    vec![
        StepSpec::new(
            "custom_repo",
            "Repository Scope",
            toggle_help,
            StepKind::Toggle {
                yes_label: "Specific owner/name".to_owned(),
                yes_help: custom_help.to_owned(),
                no_label: "Current repository".to_owned(),
                no_help: default_help.to_owned(),
            },
        )
        .with_default("false"),
        create_required_repo_step()
            .with_when(|answers| answer_equals(answers, "custom_repo", "true")),
    ]
}

pub(super) fn create_target_steps() -> Vec<StepSpec> {
    vec![
        create_target_mode_step(),
        StepSpec::new(
            "socket",
            "Daemon Socket Path",
            "Enter the Unix domain socket path for the running jpr-review serve daemon.",
            StepKind::Text {
                placeholder: Some("/tmp/jpr.sock".to_owned()),
            },
        )
        .with_default_fn(|_| non_empty_env("JPR_SOCKET").unwrap_or_default())
        .with_when(|answers| answer_equals(answers, "target_mode", "socket"))
        .with_validate(validate_non_empty("socket path")),
        create_required_pr_step().with_when(|answers| answer_equals(answers, "target_mode", "pr")),
        StepSpec::new(
            "repo",
            "Repository (Optional)",
            "Enter owner/name or leave blank to infer the repository from git.",
            StepKind::Text {
                placeholder: Some("owner/name (blank infers from git)".to_owned()),
            },
        )
        .with_when(|answers| answer_equals(answers, "target_mode", "pr"))
        .with_validate(validate_optional_repo),
    ]
}

fn create_target_mode_step() -> StepSpec {
    StepSpec::new(
        "target_mode",
        "Review Target",
        "Choose whether to connect to a running daemon socket or target a PR directly.",
        StepKind::Select(vec![
            SelectOption::new("socket", "Live Daemon Socket")
                .with_help("Talk to an already running jpr-review serve daemon via Unix socket."),
            SelectOption::new("pr", "Pull Request Number")
                .with_help("Target a pull request by number and optional owner/name repository."),
        ]),
    )
    .with_default_fn(|_| {
        if non_empty_env("JPR_SOCKET").is_some() {
            "socket".to_owned()
        } else {
            "pr".to_owned()
        }
    })
}

pub(super) fn create_required_pr_step() -> StepSpec {
    StepSpec::new(
        "pr",
        "Pull Request Number",
        "Enter the pull request number (for example 42 or #42).",
        StepKind::Text {
            placeholder: Some("42".to_owned()),
        },
    )
    .with_default_fn(|_| non_empty_env("JPR_PR").unwrap_or_default())
    .with_validate(validate_pr_number)
}

pub(super) fn create_required_repo_step() -> StepSpec {
    StepSpec::new(
        "repo",
        "Repository",
        "Enter the GitHub repository in owner/name format.",
        StepKind::Text {
            placeholder: Some("owner/name".to_owned()),
        },
    )
    .with_validate(validate_repo)
}

pub(super) fn create_open_pr_picker_step() -> StepSpec {
    StepSpec::new(
        "pr",
        "Open Pull Request",
        "Select the open pull request to check out into a review worktree.",
        StepKind::DynamicSelect(Arc::new(load_open_pull_request_options)),
    )
    .with_when(|answers| answer_equals(answers, "source", "list"))
}

fn load_open_pull_request_options(_answers: &Answers) -> Result<Vec<SelectOption>> {
    let cwd = env::current_dir().context("reading the current directory")?;
    let summaries = GhForge::new(cwd, None)
        .open_pull_requests(DEFAULT_PR_LIST_LIMIT)
        .context("loading open pull requests")?;
    Ok(summaries
        .iter()
        .map(pull_request_summary_to_option)
        .collect())
}

pub(super) fn validate_pr_number(value: &str, _answers: &Answers) -> Result<(), String> {
    commands::parse_pr_number(value)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(super) fn validate_repo(value: &str, _answers: &Answers) -> Result<(), String> {
    commands::parse_repo(value.trim())
        .map(|_| ())
        .map_err(|error| error.to_string())
}

fn validate_optional_repo(value: &str, _answers: &Answers) -> Result<(), String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    commands::parse_repo(trimmed)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub(super) fn validate_positive_u32(value: &str, _answers: &Answers) -> Result<(), String> {
    match value.trim().parse::<u32>() {
        Ok(limit) if limit >= 1 => Ok(()),
        _ => Err("limit must be an integer of 1 or greater".to_owned()),
    }
}

pub(super) fn validate_u64(value: &str, _answers: &Answers) -> Result<(), String> {
    value
        .trim()
        .parse::<u64>()
        .map(|_| ())
        .map_err(|_| "poll interval must be a non-negative integer in seconds".to_owned())
}

pub(super) fn validate_non_empty(
    field_name: &'static str,
) -> impl Fn(&str, &Answers) -> Result<(), String> + Send + Sync + 'static {
    move |value, _answers| {
        if value.trim().is_empty() {
            Err(format!("{field_name} cannot be empty"))
        } else {
            Ok(())
        }
    }
}
