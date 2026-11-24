//! Unit tests for prefilling initial wizard answers from partial CLI flags and env vars.

use std::path::PathBuf;

use cli_tui::{CommandSpec, WizardState};

use super::super::prefill::{TargetEnv, initial_answers_for_missing_inputs_with_env};
use super::super::{build_command_specs, initial_answers_for_missing_inputs};
use super::{answers_from, find_spec};
use crate::cli::Command;

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
    let empty_env = TargetEnv {
        socket: None,
        pr: None,
    };
    let complete = Command::Reply {
        thread_id: Some("loc-1".into()),
        body: Some("Done.".into()),
        pr: Some(7),
        repo: None,
        socket: None,
    };
    assert_eq!(
        initial_answers_for_missing_inputs_with_env(&complete, empty_env),
        None
    );
    let partial = Command::Reply {
        thread_id: Some("loc-1".into()),
        body: None,
        pr: Some(7),
        repo: Some("octo/widgets".into()),
        socket: None,
    };
    let (id, answers) = initial_answers_for_missing_inputs_with_env(&partial, empty_env)
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
fn prepass_write_prefill_leaves_input_mode_unset_when_input_flag_is_omitted() {
    let empty_env = TargetEnv {
        socket: None,
        pr: None,
    };
    let bare = Command::PrepassWrite {
        input: None,
        pr: None,
        repo: None,
        socket: None,
    };
    let (id, bare_answers) =
        initial_answers_for_missing_inputs_with_env(&bare, empty_env).expect("needs target");
    assert_eq!(id, "prepass-write");
    assert!(!bare_answers.contains_key("input_mode"));

    let with_file = Command::PrepassWrite {
        input: Some(PathBuf::from("findings.json")),
        pr: None,
        repo: None,
        socket: None,
    };
    let (_, file_answers) =
        initial_answers_for_missing_inputs_with_env(&with_file, empty_env).expect("needs target");
    assert_eq!(
        file_answers,
        answers_from(&[("input_mode", "file"), ("input", "findings.json")])
    );
}

#[test]
fn malformed_jpr_pr_env_is_not_prefilled_into_initial_answers() {
    let partial_reply = Command::Reply {
        thread_id: Some("loc-1".into()),
        body: None,
        pr: None,
        repo: None,
        socket: None,
    };
    for invalid_pr in ["abc", "0"] {
        let env = TargetEnv {
            socket: None,
            pr: Some(invalid_pr),
        };
        let (_, answers) = initial_answers_for_missing_inputs_with_env(&partial_reply, env)
            .expect("partial reply needs interactive input");
        assert!(!answers.contains_key("pr"));
        assert!(!answers.contains_key("target_mode"));
    }

    let valid_env = TargetEnv {
        socket: None,
        pr: Some("42"),
    };
    let (_, valid_answers) = initial_answers_for_missing_inputs_with_env(&partial_reply, valid_env)
        .expect("partial reply still needs body");
    assert_eq!(
        valid_answers,
        answers_from(&[
            ("target_mode", "pr"),
            ("pr", "42"),
            ("repo", ""),
            ("thread_id", "loc-1"),
        ])
    );
}
