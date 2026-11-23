//! Edge-case, validator, ambient-env, and end-to-end wizard tests for `tui_schema`.

use std::path::PathBuf;

use cli_tui::{Answers, CommandSpec, KeyAction, StepSpec, WizardOutcome, WizardState};

use super::convert::apply_answers_to_command_with_env;
use super::prefill::{TargetEnv, initial_answers_for_missing_inputs_with_env};
use super::steps::{resolve_agent_pr_default, resolve_checkout_loader_repo};
use super::{answers_to_command, build_command_specs};
use crate::cli::Command;

fn answers_from(pairs: &[(&str, &str)]) -> Answers {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn find_step<'a>(specs: &'a [CommandSpec], command_id: &str, step_id: &str) -> &'a StepSpec {
    specs
        .iter()
        .find(|spec| spec.id == command_id)
        .unwrap_or_else(|| panic!("missing spec `{command_id}`"))
        .steps
        .iter()
        .find(|step| step.id == step_id)
        .unwrap_or_else(|| panic!("missing step `{step_id}` in `{command_id}`"))
}

fn sample_reply(socket: Option<&str>, body: Option<&str>) -> Command {
    Command::Reply {
        thread_id: Some("loc-1".into()),
        body: body.map(str::to_owned),
        pr: None,
        repo: None,
        socket: socket.map(PathBuf::from),
    }
}

#[test]
fn checkout_loader_repo_uses_custom_repo_only_when_enabled() {
    assert_eq!(
        resolve_checkout_loader_repo(&answers_from(&[
            ("custom_repo", "false"),
            ("repo", "octo/widgets"),
        ])),
        None
    );
    assert_eq!(
        resolve_checkout_loader_repo(&answers_from(&[
            ("custom_repo", "true"),
            ("repo", "  octo/widgets  "),
        ])),
        Some("octo/widgets".to_owned())
    );
    assert_eq!(
        resolve_checkout_loader_repo(&answers_from(&[("custom_repo", "true"), ("repo", "   ")])),
        None
    );
}

#[test]
fn apply_answers_preserves_ambient_jpr_socket_and_keeps_explicit_or_edited_sockets() {
    let partial_reply = sample_reply(None, None);
    let ambient = Some("/tmp/ambient.sock");
    let ambient_answers = answers_from(&[
        ("target_mode", "socket"),
        ("socket", "/tmp/ambient.sock"),
        ("thread_id", "loc-1"),
        ("body", "Fixed."),
    ]);
    assert_eq!(
        apply_answers_to_command_with_env(&partial_reply, &ambient_answers, ambient).unwrap(),
        sample_reply(None, Some("Fixed."))
    );

    let edited_answers = answers_from(&[
        ("target_mode", "socket"),
        ("socket", "/tmp/other.sock"),
        ("thread_id", "loc-1"),
        ("body", "Fixed."),
    ]);
    assert_eq!(
        apply_answers_to_command_with_env(&partial_reply, &edited_answers, ambient).unwrap(),
        sample_reply(Some("/tmp/other.sock"), Some("Fixed."))
    );

    let explicit_reply = sample_reply(Some("/tmp/ambient.sock"), None);
    assert_eq!(
        apply_answers_to_command_with_env(&explicit_reply, &ambient_answers, ambient).unwrap(),
        sample_reply(Some("/tmp/ambient.sock"), Some("Fixed."))
    );
}

#[test]
fn agent_pr_default_skips_env_when_repo_is_explicit_and_non_agent_commands_omit_default() {
    assert_eq!(resolve_agent_pr_default(&Answers::new(), Some("42")), "42");
    assert_eq!(
        resolve_agent_pr_default(&answers_from(&[("repo", "  ")]), Some("42")),
        "42"
    );
    assert_eq!(
        resolve_agent_pr_default(&answers_from(&[("repo", "octo/widgets")]), Some("42")),
        ""
    );

    let specs = build_command_specs();
    assert!(
        find_step(&specs, "state-path", "pr")
            .default_value
            .is_none()
    );
    assert!(find_step(&specs, "serve", "pr").default_value.is_none());
    assert!(find_step(&specs, "threads", "pr").default_value.is_some());
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
fn checkout_wizard_with_prefilled_repo_completes_right_after_pr_without_reprompting() {
    let specs = build_command_specs();
    let spec = specs.iter().find(|item| item.id == "checkout").unwrap();
    let original = Command::Checkout {
        pr: None,
        repo: Some("octo/widgets".into()),
        worktree_cmd: None,
    };
    let empty_env = TargetEnv {
        socket: None,
        pr: None,
    };
    let (_, initial_answers) =
        initial_answers_for_missing_inputs_with_env(&original, empty_env).unwrap();

    let mut wizard = WizardState::new(spec, initial_answers, false);
    assert_eq!(
        wizard.current_step(spec).map(|step| step.id.as_str()),
        Some("source")
    );
    for action in [
        KeyAction::Down,
        KeyAction::Confirm,
        KeyAction::Char('4'),
        KeyAction::Char('2'),
    ] {
        assert_eq!(wizard.handle_key(spec, action), WizardOutcome::Continue);
    }
    let WizardOutcome::Completed(final_answers) = wizard.handle_key(spec, KeyAction::Confirm)
    else {
        panic!("expected wizard completion right after pr_manual");
    };
    assert_eq!(
        answers_to_command("checkout", &final_answers).unwrap(),
        Command::Checkout {
            pr: Some(42),
            repo: Some("octo/widgets".into()),
            worktree_cmd: None,
        }
    );
}

#[test]
fn answers_to_command_rejects_invalid_and_incomplete_inputs() {
    assert!(answers_to_command("unknown", &Answers::new()).is_err());
    assert!(answers_to_command("prs", &answers_from(&[("limit", "0")])).is_err());
    assert!(answers_to_command("prs", &answers_from(&[("limit", "abc")])).is_err());
    assert!(
        answers_to_command(
            "checkout",
            &answers_from(&[("source", "bogus"), ("pr", "7")]),
        )
        .is_err()
    );
    assert!(answers_to_command("state-path", &answers_from(&[("pr", "abc")])).is_err());
    assert!(
        answers_to_command("state-path", &answers_from(&[("pr", "7"), ("repo", "bad")])).is_err()
    );
    assert!(
        answers_to_command(
            "serve",
            &answers_from(&[("pr", "7"), ("repo", "octo/widgets"), ("poll", "-1")]),
        )
        .is_err()
    );
    assert!(answers_to_command("threads", &Answers::new()).is_err());
    assert!(
        answers_to_command(
            "prepass-write",
            &answers_from(&[("target_mode", "socket"), ("socket", "/tmp/a.sock")]),
        )
        .is_err()
    );
}

#[test]
fn step_validators_reject_invalid_values_and_accept_valid_inputs() {
    let specs = build_command_specs();
    let empty = Answers::new();

    let limit_check = find_step(&specs, "prs", "limit").validate.as_ref().unwrap();
    assert!(limit_check("1", &empty).is_ok());
    assert!(limit_check("0", &empty).is_err());
    assert!(limit_check("nope", &empty).is_err());

    let repo_check = find_step(&specs, "state-path", "repo")
        .validate
        .as_ref()
        .unwrap();
    assert!(repo_check("octo/widgets", &empty).is_ok());
    assert!(repo_check("widgets", &empty).is_err());

    let optional_repo_check = find_step(&specs, "threads", "repo")
        .validate
        .as_ref()
        .unwrap();
    assert!(optional_repo_check("   ", &empty).is_ok());
    assert!(optional_repo_check("octo/widgets", &empty).is_ok());
    assert!(optional_repo_check("bad", &empty).is_err());

    let pr_check = find_step(&specs, "checkout", "pr_manual")
        .validate
        .as_ref()
        .unwrap();
    assert!(pr_check("#12", &empty).is_ok());
    assert!(pr_check("xyz", &empty).is_err());

    let poll_check = find_step(&specs, "serve", "poll")
        .validate
        .as_ref()
        .unwrap();
    assert!(poll_check("0", &empty).is_ok());
    assert!(poll_check("abc", &empty).is_err());

    let body_check = find_step(&specs, "reply", "body")
        .validate
        .as_ref()
        .unwrap();
    assert!(body_check("Done.", &empty).is_ok());
    assert!(body_check("   ", &empty).is_err());
}
