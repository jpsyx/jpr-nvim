//! Declarative [`CommandSpec`] definitions for every `jpr-review` subcommand.

mod discovery;

use cli_tui::{CommandSpec, SelectOption, StepKind, StepSpec};

use super::steps::{
    create_required_pr_step, create_required_repo_step, create_target_steps, has_answer_value,
    validate_non_empty, validate_optional_git_ref, validate_u64,
};
use discovery::{
    create_checkout_spec, create_local_spec, create_owners_spec, create_prs_spec, create_repos_spec,
};

const DEFAULT_POLL_SECONDS: &str = "60";

/// Builds declarative interactive command specifications for every `jpr-review` subcommand.
#[must_use]
pub fn build_command_specs() -> Vec<CommandSpec> {
    vec![
        create_prs_spec(),
        create_owners_spec(),
        create_repos_spec(),
        create_local_spec(),
        create_checkout_spec(),
        create_threads_spec(),
        create_reply_spec(),
        create_prepass_write_spec(),
        create_state_path_spec(),
        create_serve_spec(),
        create_guide_spec(),
    ]
}

fn create_threads_spec() -> CommandSpec {
    let mut steps = create_target_steps();
    steps.push(
        StepSpec::new(
            "is_local_only",
            "Thread Filter",
            "Choose whether to include all review threads or only local agent threads.",
            StepKind::Toggle {
                yes_label: "Local agent threads only".to_owned(),
                yes_help: "Return only local threads created for agent review workflows."
                    .to_owned(),
                no_label: "All threads".to_owned(),
                no_help: "Include both GitHub review threads and local agent threads.".to_owned(),
            },
        )
        .with_default("false"),
    );
    CommandSpec::new(
        "threads",
        "List Review Threads",
        "Prints review threads as JSON from a live daemon socket or saved PR state.",
        steps,
    )
}

fn create_reply_spec() -> CommandSpec {
    let mut steps = create_target_steps();
    steps.push(
        StepSpec::new(
            "thread_id",
            "Local Thread ID",
            "Enter the local review thread identifier to reply to (for example loc-1).",
            StepKind::Text {
                placeholder: Some("loc-1".to_owned()),
            },
        )
        .with_validate(validate_non_empty("thread id")),
    );
    steps.push(
        StepSpec::new(
            "body",
            "Reply Body",
            "Enter the reply message text to append to the local thread.",
            StepKind::Text {
                placeholder: Some("Addressed in commit abc1234.".to_owned()),
            },
        )
        .with_validate(validate_non_empty("reply body")),
    );
    CommandSpec::new(
        "reply",
        "Reply to Local Thread",
        "Appends an agent reply message to a local review thread.",
        steps,
    )
}

fn create_prepass_write_spec() -> CommandSpec {
    let mut steps = create_target_steps();
    steps.push(
        StepSpec::new(
            "input_mode",
            "Findings Source",
            "Choose whether to read pre-pass review findings from a JSON file or standard input.",
            StepKind::Select(vec![
                SelectOption::new("file", "JSON file")
                    .with_help("Read the pre-pass findings JSON array from a file on disk."),
                SelectOption::new("stdin", "Read from stdin")
                    .with_help("Read the pre-pass findings JSON array from standard input."),
            ]),
        )
        .with_default("file"),
    );
    steps.push(
        StepSpec::new(
            "input",
            "Findings JSON Path",
            "Enter the path to the JSON file containing pre-pass review findings.",
            StepKind::Text {
                placeholder: Some("findings.json".to_owned()),
            },
        )
        .with_when(|answers| has_answer_value(answers, "input_mode", "file"))
        .with_validate(validate_non_empty("input file path")),
    );
    CommandSpec::new(
        "prepass-write",
        "Write Pre-Pass Findings",
        "Validates pre-pass review findings JSON and writes answered local threads.",
        steps,
    )
}

fn create_session_mode_step(help: &str) -> StepSpec {
    StepSpec::new(
        "session_mode",
        "Session Mode",
        help,
        StepKind::Select(vec![
            SelectOption::new("pr", "GitHub Pull Request")
                .with_help("Target a GitHub pull request by number and owner/name repository."),
            SelectOption::new("local", "Local Worktree Review")
                .with_help("Target the current worktree and branch without a linked PR."),
        ]),
    )
    .with_default("pr")
}

fn create_state_path_spec() -> CommandSpec {
    CommandSpec::new(
        "state-path",
        "Show Review State Path",
        "Prints the local directory holding a pull request or local worktree's review state.",
        vec![
            create_session_mode_step(
                "Choose whether to print the state path for a GitHub PR or the current local worktree.",
            ),
            create_required_pr_step()
                .with_when(|answers| has_answer_value(answers, "session_mode", "pr")),
            create_required_repo_step()
                .with_when(|answers| has_answer_value(answers, "session_mode", "pr")),
        ],
    )
}

fn create_serve_spec() -> CommandSpec {
    CommandSpec::new(
        "serve",
        "Run Review Engine Daemon",
        "Serves a pull request or local worktree review session as JSON-RPC over stdin and stdout.",
        vec![
            create_session_mode_step(
                "Choose whether to serve a GitHub pull request or an unlinked local worktree review.",
            ),
            create_required_pr_step()
                .with_when(|answers| has_answer_value(answers, "session_mode", "pr")),
            create_required_repo_step()
                .with_when(|answers| has_answer_value(answers, "session_mode", "pr")),
            StepSpec::new(
                "base",
                "Base Git Ref (Optional)",
                "Enter a base git ref to diff against, or leave blank to auto-detect.",
                StepKind::Text {
                    placeholder: Some("develop (blank auto-detects)".to_owned()),
                },
            )
            .with_when(|answers| has_answer_value(answers, "session_mode", "local"))
            .with_validate(validate_optional_git_ref),
            StepSpec::new(
                "poll",
                "Poll Interval (Seconds)",
                "Enter seconds between background syncs, or 0 to sync only on request.",
                StepKind::Text {
                    placeholder: Some(DEFAULT_POLL_SECONDS.to_owned()),
                },
            )
            .with_default(DEFAULT_POLL_SECONDS)
            .with_validate(validate_u64),
        ],
    )
}

fn create_guide_spec() -> CommandSpec {
    CommandSpec::new(
        "guide",
        "Print Agent Review Guide",
        "Prints the agent review workflow and reply contract to stdout.",
        Vec::new(),
    )
}
