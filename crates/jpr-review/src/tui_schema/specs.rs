//! Declarative [`CommandSpec`] definitions for every `jpr-review` subcommand.

use cli_tui::{CommandSpec, SelectOption, StepKind, StepSpec};

use super::steps::{
    create_custom_repo_steps, create_open_pr_picker_step, create_required_pr_step,
    create_required_repo_step, create_target_steps, has_answer_value, non_empty_env,
    validate_non_empty, validate_positive_u32, validate_pr_number, validate_u64,
};

const DEFAULT_POLL_SECONDS: &str = "60";

/// Builds declarative interactive command specifications for every `jpr-review` subcommand.
#[must_use]
pub fn build_command_specs() -> Vec<CommandSpec> {
    vec![
        create_prs_spec(),
        create_checkout_spec(),
        create_threads_spec(),
        create_reply_spec(),
        create_prepass_write_spec(),
        create_state_path_spec(),
        create_serve_spec(),
        create_guide_spec(),
    ]
}

fn create_prs_spec() -> CommandSpec {
    let mut steps = create_custom_repo_steps(
        "Choose whether to list pull requests for the current checkout or another repository.",
        "Infer the repository from the current working directory.",
        "Query open pull requests from a specific GitHub repository.",
    );
    steps.push(
        StepSpec::new(
            "limit",
            "Maximum Pull Requests",
            "Enter the maximum number of open pull requests to return.",
            StepKind::Text {
                placeholder: Some("50".to_owned()),
            },
        )
        .with_default("50")
        .with_validate(validate_positive_u32),
    );
    CommandSpec::new(
        "prs",
        "List Open Pull Requests",
        "Lists open pull requests in a repository as a JSON array.",
        steps,
    )
}

fn create_checkout_spec() -> CommandSpec {
    let mut steps = create_checkout_pr_steps();
    steps.extend(create_custom_repo_steps(
        "Choose whether to verify the pull request against a specific repository.",
        "Use whichever repository the current directory resolves to.",
        "Require the pull request to belong to a specific GitHub repository.",
    ));
    steps.extend(create_custom_worktree_steps());
    CommandSpec::new(
        "checkout",
        "Check Out Pull Request",
        "Checks a pull request out into a worktree and prints its path as JSON.",
        steps,
    )
}

fn create_checkout_pr_steps() -> Vec<StepSpec> {
    vec![
        StepSpec::new(
            "source",
            "Pull Request Selection",
            "Choose whether to pick from open pull requests or enter a number directly.",
            StepKind::Select(vec![
                SelectOption::new("list", "Pick from Open PRs").with_help(
                    "Fetch open pull requests from GitHub and choose one from the list.",
                ),
                SelectOption::new("manual", "Enter PR Number")
                    .with_help("Type a pull request number directly without fetching open PRs."),
            ]),
        )
        .with_default("list"),
        create_open_pr_picker_step(),
        StepSpec::new(
            "pr_manual",
            "Pull Request Number",
            "Enter the pull request number to check out (for example 42 or #42).",
            StepKind::Text {
                placeholder: Some("42".to_owned()),
            },
        )
        .with_when(|answers| has_answer_value(answers, "source", "manual"))
        .with_validate(validate_pr_number),
    ]
}

fn create_custom_worktree_steps() -> Vec<StepSpec> {
    vec![
        StepSpec::new(
            "custom_worktree",
            "Worktree Strategy",
            "Choose between the default git worktree checkout or a custom shell command.",
            StepKind::Toggle {
                yes_label: "Custom worktree command".to_owned(),
                yes_help: "Run a custom shell template such as `wt pr {n}` to create the worktree."
                    .to_owned(),
                no_label: "Default git worktree".to_owned(),
                no_help: "Create the review worktree with jpr-review's built-in git checkout."
                    .to_owned(),
            },
        )
        .with_default_fn(|_| {
            if non_empty_env("JPR_WORKTREE_CMD").is_some() {
                "true".to_owned()
            } else {
                "false".to_owned()
            }
        }),
        StepSpec::new(
            "worktree_cmd",
            "Worktree Command Template",
            "Enter the shell command that creates the worktree and prints its path (`{n}` is the PR number).",
            StepKind::Text {
                placeholder: Some("wt pr {n}".to_owned()),
            },
        )
        .with_default_fn(|_| non_empty_env("JPR_WORKTREE_CMD").unwrap_or_default())
        .with_when(|answers| has_answer_value(answers, "custom_worktree", "true"))
        .with_validate(validate_non_empty("worktree command")),
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

fn create_state_path_spec() -> CommandSpec {
    CommandSpec::new(
        "state-path",
        "Show Review State Path",
        "Prints the local directory holding a pull request's review state.",
        vec![create_required_pr_step(), create_required_repo_step()],
    )
}

fn create_serve_spec() -> CommandSpec {
    CommandSpec::new(
        "serve",
        "Run Review Engine Daemon",
        "Serves a pull request review session as JSON-RPC over stdin and stdout.",
        vec![
            create_required_pr_step(),
            create_required_repo_step(),
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
