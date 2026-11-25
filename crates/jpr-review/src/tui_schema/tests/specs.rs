//! Command specification registration, branching, formatting, and step validator tests.

use clap::CommandFactory;
use cli_tui::{Answers, validate_command_specs};
use review_model::PullRequestSummary;

use super::super::{build_command_specs, pull_request_summary_to_option};
use super::{active_step_ids, find_spec, find_step};
use crate::cli::Cli;

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
fn local_serve_and_state_path_discriminants_hide_irrelevant_steps() {
    let specs = build_command_specs();
    let local_spec = find_spec(&specs, "local");
    assert_eq!(
        active_step_ids(&local_spec, &[("base_mode", "custom")]),
        vec!["base_mode", "base"]
    );
    assert_eq!(
        active_step_ids(
            &local_spec,
            &[("base_mode", "auto"), ("detect_pr", "false")],
        ),
        vec!["base_mode", "detect_pr"]
    );
    assert_eq!(
        active_step_ids(
            &local_spec,
            &[
                ("base_mode", "auto"),
                ("detect_pr", "true"),
                ("custom_repo", "true"),
            ],
        ),
        vec!["base_mode", "detect_pr", "custom_repo", "repo"]
    );

    let state_path_spec = find_spec(&specs, "state-path");
    assert_eq!(
        active_step_ids(&state_path_spec, &[("session_mode", "local")]),
        vec!["session_mode"]
    );
    assert_eq!(
        active_step_ids(&state_path_spec, &[("session_mode", "pr")]),
        vec!["session_mode", "pr", "repo"]
    );

    let serve_spec = find_spec(&specs, "serve");
    assert_eq!(
        active_step_ids(&serve_spec, &[("session_mode", "local")]),
        vec!["session_mode", "base", "poll"]
    );
    assert_eq!(
        active_step_ids(&serve_spec, &[("session_mode", "pr")]),
        vec!["session_mode", "pr", "repo", "poll"]
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

#[test]
fn step_validators_reject_invalid_values_and_accept_valid_inputs() {
    let specs = build_command_specs();
    let empty = Answers::new();
    let check =
        |cmd, step, value| find_step(&specs, cmd, step).validate.as_ref().unwrap()(value, &empty);

    assert!(check("prs", "limit", "1").is_ok());
    assert!(check("prs", "limit", "0").is_err());
    assert!(check("prs", "limit", "nope").is_err());

    assert!(check("state-path", "repo", "octo/widgets").is_ok());
    assert!(check("state-path", "repo", "widgets").is_err());

    assert!(check("threads", "repo", "   ").is_ok());
    assert!(check("threads", "repo", "octo/widgets").is_ok());
    assert!(check("threads", "repo", "bad").is_err());

    assert!(check("checkout", "pr_manual", "#12").is_ok());
    assert!(check("checkout", "pr_manual", "xyz").is_err());

    assert!(check("serve", "poll", "0").is_ok());
    assert!(check("serve", "poll", "abc").is_err());

    assert!(check("reply", "body", "Done.").is_ok());
    assert!(check("reply", "body", "   ").is_err());
}
