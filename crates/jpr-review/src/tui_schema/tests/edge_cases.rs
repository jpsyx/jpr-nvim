//! Edge-case, helper, and end-to-end wizard integration tests for `tui_schema`.

use cli_tui::{Answers, KeyAction, WizardOutcome, WizardState};

use super::super::prefill::{TargetEnv, initial_answers_for_missing_inputs_with_env};
use super::super::steps::{get_agent_pr_default_from_answers, get_checkout_repo_from_answers};
use super::super::{answers_to_command, build_command_specs};
use super::{answers_from, find_spec, find_step};
use crate::cli::Command;

#[test]
fn checkout_loader_repo_uses_custom_repo_only_when_enabled() {
    assert_eq!(
        get_checkout_repo_from_answers(&answers_from(&[
            ("custom_repo", "false"),
            ("repo", "octo/widgets"),
        ])),
        None
    );
    assert_eq!(
        get_checkout_repo_from_answers(&answers_from(&[
            ("custom_repo", "true"),
            ("repo", "  octo/widgets  "),
        ])),
        Some("octo/widgets".to_owned())
    );
    assert_eq!(
        get_checkout_repo_from_answers(&answers_from(&[("custom_repo", "true"), ("repo", "   ")])),
        None
    );
}

#[test]
fn agent_pr_default_skips_env_when_repo_is_explicit_and_non_agent_commands_omit_default() {
    assert_eq!(
        get_agent_pr_default_from_answers(&Answers::new(), Some("42")),
        "42"
    );
    assert_eq!(
        get_agent_pr_default_from_answers(&answers_from(&[("repo", "  ")]), Some("42")),
        "42"
    );
    assert_eq!(
        get_agent_pr_default_from_answers(&answers_from(&[("repo", "octo/widgets")]), Some("42")),
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
fn checkout_wizard_with_prefilled_repo_completes_right_after_pr_without_reprompting() {
    let specs = build_command_specs();
    let spec = find_spec(&specs, "checkout");
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

    let mut wizard = WizardState::new(&spec, initial_answers, false);
    assert_eq!(
        wizard.current_step(&spec).map(|step| step.id.as_str()),
        Some("source")
    );
    for action in [
        KeyAction::Down,
        KeyAction::Confirm,
        KeyAction::Char('4'),
        KeyAction::Char('2'),
    ] {
        assert_eq!(wizard.handle_key(&spec, action), WizardOutcome::Continue);
    }
    let WizardOutcome::Completed(final_answers) = wizard.handle_key(&spec, KeyAction::Confirm)
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
