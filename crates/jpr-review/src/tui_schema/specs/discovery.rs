//! Declarative [`CommandSpec`] definitions for discovery and checkout subcommands.

use cli_tui::{CommandSpec, SelectOption, StepKind, StepSpec};

use super::super::steps::{
    create_custom_repo_steps, create_open_pr_picker_step, has_answer_value, non_empty_env,
    validate_git_ref, validate_non_empty, validate_owner, validate_positive_u32,
    validate_pr_number,
};

pub(super) fn create_local_spec() -> CommandSpec {
    let mut steps = create_local_base_steps();
    steps.extend(create_local_pr_detection_steps());
    CommandSpec::new(
        "local",
        "Inspect Current Worktree Review",
        "Inspects the current worktree for local review or active PR auto-detection as JSON.",
        steps,
    )
}

fn create_local_base_steps() -> Vec<StepSpec> {
    vec![
        StepSpec::new(
            "base_mode",
            "Base Branch Selection",
            "Auto-detect the base branch (and attach to an open PR if one exists) or pick a custom git ref.",
            StepKind::Select(vec![
                SelectOption::new("auto", "Auto-detect base branch").with_help(
                    "Use develop if present else main, and auto-attach if an open PR exists.",
                ),
                SelectOption::new("custom", "Custom git ref (local only)").with_help(
                    "Diff against a specific git ref such as HEAD or a branch; stays local-only.",
                ),
            ]),
        )
        .with_default("auto"),
        StepSpec::new(
            "base",
            "Base Git Ref",
            "Enter the git ref to diff the current worktree against (for example develop, main, or HEAD).",
            StepKind::Text {
                placeholder: Some("HEAD".to_owned()),
            },
        )
        .with_when(|answers| has_answer_value(answers, "base_mode", "custom"))
        .with_validate(validate_git_ref),
    ]
}

fn create_local_pr_detection_steps() -> Vec<StepSpec> {
    let mut steps = vec![
        StepSpec::new(
            "detect_pr",
            "Active PR Detection",
            "Choose whether to auto-attach when the current branch already has an open GitHub PR.",
            StepKind::Toggle {
                yes_label: "Auto-attach to open PR".to_owned(),
                yes_help: "Probe GitHub with gh pr view and attach in-place if an open PR exists."
                    .to_owned(),
                no_label: "Stay local only (--no-pr)".to_owned(),
                no_help: "Skip GitHub PR detection and start an unlinked local worktree review."
                    .to_owned(),
            },
        )
        .with_default("true")
        .with_when(|answers| has_answer_value(answers, "base_mode", "auto")),
    ];
    for mut step in create_custom_repo_steps(
        "Choose whether to probe a specific GitHub repository for an open PR.",
        "Let gh resolve the repository from the current worktree's remotes.",
        "Check a specific owner/name repository for an open PR.",
    ) {
        let existing_when = step.when.take();
        step = step.with_when(move |answers| {
            has_answer_value(answers, "base_mode", "auto")
                && has_answer_value(answers, "detect_pr", "true")
                && existing_when
                    .as_ref()
                    .is_none_or(|predicate| predicate(answers))
        });
        steps.push(step);
    }
    steps
}

pub(super) fn create_prs_spec() -> CommandSpec {
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

pub(super) fn create_checkout_spec() -> CommandSpec {
    let mut steps = create_checkout_pr_steps();
    steps.extend(create_custom_repo_steps(
        "Choose whether to target a specific GitHub repository (required outside a git repo).",
        "Use whichever repository the current directory resolves to.",
        "Verify or clone a specific GitHub repository (required outside a local git checkout).",
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

pub(super) fn create_owners_spec() -> CommandSpec {
    CommandSpec::new(
        "owners",
        "List GitHub Owners",
        "Lists the authenticated GitHub user profile and organizations as a JSON array.",
        Vec::new(),
    )
}

pub(super) fn create_repos_spec() -> CommandSpec {
    CommandSpec::new(
        "repos",
        "List GitHub Repositories",
        "Lists GitHub repositories for your account or a specific organization as a JSON array.",
        vec![
            StepSpec::new(
                "owner_scope",
                "Repository Owner",
                "Choose whether to list your personal repositories or repositories from a specific owner or organization.",
                StepKind::Toggle {
                    yes_label: "Specific owner or organization".to_owned(),
                    yes_help: "Enter a GitHub user or organization login to list its repositories."
                        .to_owned(),
                    no_label: "My personal repositories".to_owned(),
                    no_help: "List repositories owned by your authenticated GitHub account."
                        .to_owned(),
                },
            )
            .with_default("false"),
            StepSpec::new(
                "owner",
                "Owner or Organization Login",
                "Enter the GitHub user or organization login (for example octocat or acme-corp).",
                StepKind::Text {
                    placeholder: Some("octocat".to_owned()),
                },
            )
            .with_when(|answers| has_answer_value(answers, "owner_scope", "true"))
            .with_validate(validate_owner),
            StepSpec::new(
                "limit",
                "Maximum Repositories",
                "Enter the maximum number of repositories to return.",
                StepKind::Text {
                    placeholder: Some("100".to_owned()),
                },
            )
            .with_default("100")
            .with_validate(validate_positive_u32),
        ],
    )
}
