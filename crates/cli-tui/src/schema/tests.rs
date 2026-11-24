//! Unit tests for `cli-tui` command schemas, validation, and answer pruning.

use super::*;

fn text_step(id: &str, label: &str, help: &str, placeholder: Option<&str>) -> StepSpec {
    StepSpec::new(
        id,
        label,
        help,
        StepKind::Text {
            placeholder: placeholder.map(str::to_owned),
        },
    )
}

fn when_equals(key: &'static str, expected: &'static str) -> impl Fn(&Answers) -> bool {
    move |answers| answers.get(key).map(String::as_str) == Some(expected)
}

fn sample_branching_command() -> CommandSpec {
    CommandSpec::new(
        "threads",
        "List Review Threads",
        "Lists review threads from a live daemon socket or a pull request.",
        vec![
            StepSpec::new(
                "target_mode",
                "Target Source",
                "Choose whether to query a running socket or a pull request.",
                StepKind::Select(vec![
                    SelectOption::new("socket", "Live Daemon Socket")
                        .with_help("Connect to an already running jpr-review daemon."),
                    SelectOption::new("pr", "Pull Request Number")
                        .with_help("Read stored state for a specific PR number."),
                ]),
            ),
            text_step(
                "socket",
                "Socket Path",
                "Enter the Unix socket path for the running daemon.",
                Some("/tmp/jpr.sock"),
            )
            .with_when(when_equals("target_mode", "socket")),
            text_step(
                "pr",
                "Pull Request Number",
                "Enter the pull request number to inspect.",
                Some("42"),
            )
            .with_when(when_equals("target_mode", "pr")),
            text_step(
                "repo",
                "Repository",
                "Enter the owner/name repository slug.",
                Some("octo/widgets"),
            )
            .with_when(when_equals("target_mode", "pr")),
        ],
    )
}

fn transitive_when_command() -> CommandSpec {
    CommandSpec::new(
        "deploy",
        "Deploy",
        "Run a deployment.",
        vec![
            StepSpec::new(
                "mode",
                "Mode",
                "Pick mode.",
                StepKind::Select(vec![
                    SelectOption::new("local", "Local"),
                    SelectOption::new("remote", "Remote"),
                ]),
            ),
            StepSpec::new(
                "region",
                "Region",
                "Pick region.",
                StepKind::Select(vec![
                    SelectOption::new("us", "US"),
                    SelectOption::new("eu", "EU"),
                ]),
            )
            .with_when(when_equals("mode", "remote")),
            text_step("eu_cluster", "EU Cluster", "Enter EU cluster name.", None)
                .with_when(when_equals("region", "eu")),
        ],
    )
}

#[test]
fn validate_accepts_well_formed_command_specs() {
    let commands = vec![
        sample_branching_command(),
        CommandSpec::new(
            "guide",
            "Print Agent Review Guide",
            "Prints the review workflow guide to stdout.",
            vec![],
        ),
    ];
    assert_eq!(validate_command_specs(&commands), Ok(()));
}

#[test]
fn validate_rejects_empty_command_fields() {
    let missing_label = vec![CommandSpec::new("guide", "   ", "Prints guide.", vec![])];
    assert!(validate_command_specs(&missing_label).is_err());

    let missing_help = vec![CommandSpec::new("guide", "Guide", "", vec![])];
    assert!(validate_command_specs(&missing_help).is_err());

    let missing_id = vec![CommandSpec::new("", "Guide", "Prints guide.", vec![])];
    assert!(validate_command_specs(&missing_id).is_err());
}

#[test]
fn validate_rejects_duplicate_command_ids() {
    let duplicate = vec![
        CommandSpec::new("guide", "Guide A", "First guide.", vec![]),
        CommandSpec::new("guide", "Guide B", "Second guide.", vec![]),
    ];
    let error = validate_command_specs(&duplicate).unwrap_err();
    assert!(error.contains("guide"));
}

#[test]
fn validate_rejects_duplicate_step_ids_and_empty_select_options() {
    let duplicate_steps = vec![CommandSpec::new(
        "cmd",
        "Command",
        "Does work.",
        vec![
            text_step("pr", "PR", "Enter PR.", None),
            text_step("pr", "PR Again", "Enter PR again.", None),
        ],
    )];
    assert!(validate_command_specs(&duplicate_steps).is_err());

    let empty_select = vec![CommandSpec::new(
        "cmd",
        "Command",
        "Does work.",
        vec![StepSpec::new(
            "mode",
            "Mode",
            "Pick mode.",
            StepKind::Select(vec![]),
        )],
    )];
    assert!(validate_command_specs(&empty_select).is_err());
}

#[test]
fn get_active_steps_from_command_filters_by_when_predicates() {
    let command = sample_branching_command();

    let socket_answers = Answers::from([("target_mode".to_owned(), "socket".to_owned())]);
    let socket_ids: Vec<&str> = get_active_steps_from_command(&command, &socket_answers)
        .into_iter()
        .map(|step| step.id.as_str())
        .collect();
    assert_eq!(socket_ids, vec!["target_mode", "socket"]);

    let pr_answers = Answers::from([("target_mode".to_owned(), "pr".to_owned())]);
    let pr_ids: Vec<&str> = get_active_steps_from_command(&command, &pr_answers)
        .into_iter()
        .map(|step| step.id.as_str())
        .collect();
    assert_eq!(pr_ids, vec!["target_mode", "pr", "repo"]);
}

#[test]
fn prune_inactive_answers_drops_stale_branch_keys() {
    let command = sample_branching_command();
    let dirty_answers = Answers::from([
        ("target_mode".to_owned(), "pr".to_owned()),
        ("socket".to_owned(), "/tmp/stale.sock".to_owned()),
        ("pr".to_owned(), "42".to_owned()),
        ("repo".to_owned(), "octo/widgets".to_owned()),
    ]);

    let pruned = prune_inactive_answers(&command, &dirty_answers);
    assert_eq!(
        pruned,
        Answers::from([
            ("target_mode".to_owned(), "pr".to_owned()),
            ("pr".to_owned(), "42".to_owned()),
            ("repo".to_owned(), "octo/widgets".to_owned()),
        ])
    );
}

#[test]
fn prune_inactive_answers_prunes_transitive_when_chains() {
    let command = transitive_when_command();
    let dirty = Answers::from([
        ("mode".to_owned(), "local".to_owned()),
        ("region".to_owned(), "eu".to_owned()),
        ("eu_cluster".to_owned(), "fra-1".to_owned()),
    ]);

    let pruned = prune_inactive_answers(&command, &dirty);
    assert_eq!(
        pruned,
        Answers::from([("mode".to_owned(), "local".to_owned())])
    );
}
