//! Unit tests for `tui_schema` command specifications and conversions.

use std::path::PathBuf;

use clap::CommandFactory;
use cli_tui::{Answers, CommandSpec, WizardState, resolve_active_steps, validate_command_specs};
use review_model::PullRequestSummary;

use super::prefill::{TargetEnv, initial_answers_for_missing_inputs_with_env};
use super::{
    answers_to_command, build_command_specs, initial_answers_for_missing_inputs,
    pull_request_summary_to_option,
};
use crate::cli::{Cli, Command};

fn find_spec(specs: &[CommandSpec], command_id: &str) -> CommandSpec {
    specs
        .iter()
        .find(|spec| spec.id == command_id)
        .cloned()
        .unwrap_or_else(|| panic!("missing spec for `{command_id}`"))
}

fn answers_from(pairs: &[(&str, &str)]) -> Answers {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn active_step_ids(spec: &CommandSpec, pairs: &[(&str, &str)]) -> Vec<String> {
    let answers = answers_from(pairs);
    resolve_active_steps(spec, &answers)
        .into_iter()
        .map(|step| step.id.clone())
        .collect()
}

fn assert_converts(command_id: &str, pairs: &[(&str, &str)], expected: &Command) {
    let actual = answers_to_command(command_id, &answers_from(pairs))
        .unwrap_or_else(|error| panic!("conversion failed for `{command_id}`: {error:#}"));
    assert_eq!(&actual, expected);
}

#[test]
fn every_cli_subcommand_is_registered_in_tui_schema() {
    let specs = build_command_specs();
    validate_command_specs(&specs).expect("schema should validate cleanly");

    let cli_command = Cli::command();
    let cli_subcommand_names: Vec<&str> = cli_command
        .get_subcommands()
        .filter(|subcommand| subcommand.get_name() != "help")
        .map(clap::Command::get_name)
        .collect();

    assert_eq!(specs.len(), cli_subcommand_names.len());
    for name in cli_subcommand_names {
        let spec = find_spec(&specs, name);
        assert!(
            !spec.label.trim().is_empty() && spec.label != spec.id,
            "command `{name}` must have a human-readable label distinct from its id"
        );
        assert!(
            !spec.help.trim().is_empty(),
            "command `{name}` must have non-empty helper text"
        );
    }
}

#[test]
fn checkout_discriminants_branch_between_default_and_custom_options() {
    let checkout_spec = find_spec(&build_command_specs(), "checkout");

    assert_eq!(
        active_step_ids(
            &checkout_spec,
            &[
                ("source", "list"),
                ("custom_repo", "false"),
                ("custom_worktree", "false"),
            ],
        ),
        vec!["source", "pr", "custom_repo", "custom_worktree"]
    );

    assert_eq!(
        active_step_ids(
            &checkout_spec,
            &[
                ("source", "manual"),
                ("custom_repo", "true"),
                ("custom_worktree", "true"),
            ],
        ),
        vec![
            "source",
            "pr_manual",
            "custom_repo",
            "repo",
            "custom_worktree",
            "worktree_cmd",
        ]
    );
}

#[test]
fn threads_discriminant_branches_between_socket_and_pr_repo() {
    let threads_spec = find_spec(&build_command_specs(), "threads");

    assert_eq!(
        active_step_ids(&threads_spec, &[("target_mode", "socket")]),
        vec!["target_mode", "socket", "is_local_only"]
    );

    assert_eq!(
        active_step_ids(&threads_spec, &[("target_mode", "pr")]),
        vec!["target_mode", "pr", "repo", "is_local_only"]
    );
}

#[test]
fn prepass_write_discriminant_branches_between_file_and_stdin() {
    let prepass_spec = find_spec(&build_command_specs(), "prepass-write");

    assert_eq!(
        active_step_ids(
            &prepass_spec,
            &[("target_mode", "socket"), ("input_mode", "file")],
        ),
        vec!["target_mode", "socket", "input_mode", "input"]
    );

    assert_eq!(
        active_step_ids(
            &prepass_spec,
            &[("target_mode", "pr"), ("input_mode", "stdin")],
        ),
        vec!["target_mode", "pr", "repo", "input_mode"]
    );
}

#[test]
fn answers_to_command_builds_typed_commands_for_every_subcommand() {
    assert_converts(
        "prs",
        &[
            ("custom_repo", "true"),
            ("repo", "octo/widgets"),
            ("limit", "25"),
        ],
        &Command::Prs {
            repo: Some("octo/widgets".into()),
            limit: 25,
        },
    );
    assert_converts(
        "checkout",
        &[
            ("source", "manual"),
            ("pr_manual", "#19"),
            ("custom_repo", "true"),
            ("repo", "octo/widgets"),
            ("custom_worktree", "true"),
            ("worktree_cmd", "wt pr {n}"),
        ],
        &Command::Checkout {
            pr: Some(19),
            repo: Some("octo/widgets".into()),
            worktree_cmd: Some("wt pr {n}".into()),
        },
    );
    assert_converts(
        "threads",
        &[
            ("target_mode", "socket"),
            ("socket", "/tmp/jpr.sock"),
            ("is_local_only", "true"),
        ],
        &Command::Threads {
            pr: None,
            repo: None,
            socket: Some(PathBuf::from("/tmp/jpr.sock")),
            is_local_only: true,
        },
    );
    assert_converts_remaining_subcommands();
}

fn assert_converts_remaining_subcommands() {
    assert_converts(
        "reply",
        &[
            ("target_mode", "pr"),
            ("pr", "7"),
            ("repo", ""),
            ("thread_id", "loc-1"),
            ("body", "Fixed in abc1234."),
        ],
        &Command::Reply {
            thread_id: Some("loc-1".into()),
            body: Some("Fixed in abc1234.".into()),
            pr: Some(7),
            repo: None,
            socket: None,
        },
    );
    assert_converts(
        "prepass-write",
        &[
            ("target_mode", "pr"),
            ("pr", "7"),
            ("repo", "octo/widgets"),
            ("input_mode", "file"),
            ("input", "findings.json"),
        ],
        &Command::PrepassWrite {
            input: Some(PathBuf::from("findings.json")),
            pr: Some(7),
            repo: Some("octo/widgets".into()),
            socket: None,
        },
    );
    assert_converts_state_and_daemon_subcommands();
}

fn assert_converts_state_and_daemon_subcommands() {
    assert_converts(
        "state-path",
        &[("pr", "7"), ("repo", "octo/widgets")],
        &Command::StatePath {
            pr: Some(7),
            repo: Some("octo/widgets".into()),
        },
    );
    assert_converts(
        "serve",
        &[("pr", "7"), ("repo", "octo/widgets"), ("poll", "30")],
        &Command::Serve {
            pr: 7,
            repo: "octo/widgets".into(),
            poll: 30,
        },
    );
    assert_converts("guide", &[], &Command::Guide);
}

#[test]
fn initial_answers_for_missing_inputs_prefills_supplied_flags_and_skips_complete_commands() {
    let specs = build_command_specs();
    assert_partial_checkout_prefill(&specs);
    assert_partial_reply_prefill(&specs);
    assert_partial_state_path_prefill(&specs);

    assert_eq!(
        initial_answers_for_missing_inputs(&Command::Prs {
            repo: None,
            limit: 50,
        }),
        None
    );
    assert_eq!(initial_answers_for_missing_inputs(&Command::Guide), None);
}

fn assert_partial_checkout_prefill(specs: &[CommandSpec]) {
    assert_eq!(
        initial_answers_for_missing_inputs(&Command::Checkout {
            pr: Some(7),
            repo: None,
            worktree_cmd: None,
        }),
        None
    );
    let (id, answers) = initial_answers_for_missing_inputs(&Command::Checkout {
        pr: None,
        repo: Some("octo/widgets".into()),
        worktree_cmd: Some("wt pr {n}".into()),
    })
    .expect("checkout without --pr needs interactive input");
    assert_eq!(id, "checkout");
    assert_eq!(
        answers,
        answers_from(&[
            ("custom_repo", "true"),
            ("repo", "octo/widgets"),
            ("custom_worktree", "true"),
            ("worktree_cmd", "wt pr {n}"),
        ])
    );
    let spec = find_spec(specs, id);
    let wizard = WizardState::new(&spec, answers, false);
    assert_eq!(
        wizard.current_step(&spec).map(|step| step.id.as_str()),
        Some("source")
    );
}

fn assert_partial_reply_prefill(specs: &[CommandSpec]) {
    assert_eq!(
        initial_answers_for_missing_inputs(&Command::Reply {
            thread_id: Some("loc-1".into()),
            body: Some("Done.".into()),
            pr: Some(7),
            repo: None,
            socket: None,
        }),
        None
    );
    let (id, answers) = initial_answers_for_missing_inputs(&Command::Reply {
        thread_id: Some("loc-1".into()),
        body: None,
        pr: Some(7),
        repo: Some("octo/widgets".into()),
        socket: None,
    })
    .expect("reply without --body needs interactive input");
    assert_eq!(id, "reply");
    assert_eq!(
        answers,
        answers_from(&[
            ("target_mode", "pr"),
            ("pr", "7"),
            ("repo", "octo/widgets"),
            ("thread_id", "loc-1"),
        ])
    );
    let spec = find_spec(specs, id);
    let wizard = WizardState::new(&spec, answers, false);
    assert_eq!(
        wizard.current_step(&spec).map(|step| step.id.as_str()),
        Some("body")
    );
}

fn assert_partial_state_path_prefill(specs: &[CommandSpec]) {
    assert_eq!(
        initial_answers_for_missing_inputs(&Command::StatePath {
            pr: Some(7),
            repo: Some("octo/widgets".into()),
        }),
        None
    );
    let (id, answers) = initial_answers_for_missing_inputs(&Command::StatePath {
        pr: Some(7),
        repo: None,
    })
    .expect("state-path without --repo needs interactive input");
    assert_eq!(id, "state-path");
    assert_eq!(answers, answers_from(&[("pr", "7")]));
    let spec = find_spec(specs, id);
    let wizard = WizardState::new(&spec, answers, false);
    assert_eq!(
        wizard.current_step(&spec).map(|step| step.id.as_str()),
        Some("repo")
    );
}

#[test]
fn target_commands_respect_env_and_explicit_repo_rules() {
    let env = |socket, pr| TargetEnv { socket, pr };
    let bare_threads = Command::Threads {
        pr: None,
        repo: None,
        socket: None,
        is_local_only: true,
    };
    let (command_id, answers) =
        initial_answers_for_missing_inputs_with_env(&bare_threads, env(None, None))
            .expect("threads without target needs interactive input");
    assert_eq!(command_id, "threads");
    assert_eq!(answers, answers_from(&[("is_local_only", "true")]));

    assert_eq!(
        initial_answers_for_missing_inputs_with_env(
            &bare_threads,
            env(Some("/tmp/jpr.sock"), None),
        ),
        None
    );

    let repo_only_threads = Command::Threads {
        pr: None,
        repo: Some("octo/widgets".into()),
        socket: None,
        is_local_only: false,
    };
    let (_, repo_answers) = initial_answers_for_missing_inputs_with_env(
        &repo_only_threads,
        env(Some("/tmp/jpr.sock"), Some("99")),
    )
    .expect("explicit --repo without --pr must still ask for pr");
    assert_eq!(
        repo_answers,
        answers_from(&[
            ("target_mode", "pr"),
            ("repo", "octo/widgets"),
            ("is_local_only", "false"),
        ])
    );
}

#[test]
fn pull_request_summary_formats_label_optional_draft_badge_and_hover_help() {
    let draft_pr = PullRequestSummary {
        number: 42,
        title: "Add command palette".into(),
        author: "alice".into(),
        head_ref: "feat/palette".into(),
        is_draft: true,
        updated_at: "2026-11-23T15:00:00Z".into(),
    };
    let option = pull_request_summary_to_option(&draft_pr);
    assert_eq!(option.value, "42");
    assert_eq!(option.label, "#42  Add command palette");
    assert_eq!(option.badge.as_deref(), Some("draft"));
    assert_eq!(option.help.as_deref(), Some("@alice \u{00b7} feat/palette"));

    let ready_pr = PullRequestSummary {
        is_draft: false,
        ..draft_pr
    };
    assert_eq!(pull_request_summary_to_option(&ready_pr).badge, None);
}
