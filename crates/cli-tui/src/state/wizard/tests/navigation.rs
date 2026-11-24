//! Navigation, branching, dynamic select, validation, and prefill tests for [`WizardState`].

use std::sync::Arc;

use crate::schema::{Answers, CommandSpec, SelectOption, StepKind, StepSpec};
use crate::state::KeyAction;

use super::super::{WizardOutcome, WizardState, has_unanswered_active_step};
use super::{branching_command, press_keys, type_text};

fn dynamic_and_toggle_command() -> CommandSpec {
    CommandSpec::new(
        "review",
        "Review",
        "Run review.",
        vec![
            StepSpec::new(
                "pr",
                "Pull Request",
                "Pick an open PR.",
                StepKind::DynamicSelect(Arc::new(|_| {
                    Ok(vec![
                        SelectOption::new("10", "#10 Add auth"),
                        SelectOption::new("12", "#12 Fix parser"),
                    ])
                })),
            )
            .with_default("12"),
            StepSpec::new(
                "is_local_only",
                "Local Only",
                "Filter to local-only threads.",
                StepKind::Toggle {
                    yes_label: "Local only".to_owned(),
                    yes_help: "Include only unsynced local threads.".to_owned(),
                    no_label: "All threads".to_owned(),
                    no_help: "Include both remote and local threads.".to_owned(),
                },
            ),
        ],
    )
}

fn failing_or_empty_dynamic_command() -> CommandSpec {
    CommandSpec::new(
        "checkout",
        "Check Out",
        "Check out a PR.",
        vec![
            StepSpec::new(
                "source",
                "Source",
                "Pick source.",
                StepKind::Select(vec![
                    SelectOption::new("err", "Failing list"),
                    SelectOption::new("empty", "Empty list"),
                ]),
            ),
            StepSpec::new(
                "pr",
                "Pull Request",
                "Pick an open PR.",
                StepKind::DynamicSelect(Arc::new(|answers| {
                    if answers.get("source").map(String::as_str) == Some("err") {
                        Err(anyhow::anyhow!("gh auth missing"))
                    } else {
                        Ok(vec![])
                    }
                })),
            ),
        ],
    )
}

#[test]
fn wizard_switches_branch_after_step_back_and_prunes_stale_answers_on_completion() {
    let command = branching_command();
    let mut wizard = WizardState::new(&command, Answers::new(), true);

    assert_eq!(
        (wizard.step_index(), wizard.selected_option_index()),
        (0, 0)
    );
    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);
    assert_eq!(wizard.step_index(), 1);
    assert_eq!(wizard.input_text(), "/tmp/default.sock");

    press_keys(&mut wizard, &command, &[KeyAction::Back]);
    assert_eq!(wizard.step_index(), 0);
    assert_eq!(
        wizard.answers().get("socket").map(String::as_str),
        Some("/tmp/default.sock")
    );

    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Down, KeyAction::Confirm],
    );
    assert_eq!(
        wizard.current_step(&command).map(|step| step.id.as_str()),
        Some("pr")
    );

    type_text(&mut wizard, &command, "77");
    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);
    assert_eq!(
        (wizard.step_index(), wizard.input_text()),
        (2, "octo/widgets")
    );

    assert_eq!(
        wizard.handle_key(&command, KeyAction::Confirm),
        WizardOutcome::Completed(Answers::from([
            ("target_mode".to_owned(), "pr".to_owned()),
            ("pr".to_owned(), "77".to_owned()),
            ("repo".to_owned(), "octo/widgets".to_owned()),
        ]))
    );
}

#[test]
fn wizard_multi_round_discriminant_toggle_restores_draft_and_prunes() {
    let command = branching_command();
    let mut wizard = WizardState::new(&command, Answers::new(), false);

    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Confirm, KeyAction::Char('2'), KeyAction::Back],
    );
    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Down, KeyAction::Confirm],
    );
    type_text(&mut wizard, &command, "15");
    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);
    assert_eq!(wizard.step_index(), 2);

    press_keys(&mut wizard, &command, &[KeyAction::Back, KeyAction::Back]);
    assert_eq!(wizard.step_index(), 0);

    press_keys(&mut wizard, &command, &[KeyAction::Up, KeyAction::Confirm]);
    assert_eq!(wizard.input_text(), "/tmp/default.sock2");
    assert_eq!(
        wizard.handle_key(&command, KeyAction::Confirm),
        WizardOutcome::Completed(Answers::from([
            ("target_mode".to_owned(), "socket".to_owned()),
            ("socket".to_owned(), "/tmp/default.sock2".to_owned()),
        ]))
    );
}

#[test]
fn wizard_validation_failure_keeps_focus_and_sets_error() {
    let command = branching_command();
    let initial = Answers::from([("target_mode".to_owned(), "pr".to_owned())]);
    let mut wizard = WizardState::new(&command, initial, false);

    assert_eq!(wizard.step_index(), 1);
    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Char('x'), KeyAction::Confirm],
    );
    assert_eq!(wizard.step_index(), 1);
    assert_eq!(
        wizard.validation_error(),
        Some("Pull request must be a positive integer.")
    );
}

#[test]
fn wizard_back_on_first_step_never_mutates_answers_and_respects_palette_flag() {
    let command = branching_command();

    let mut from_palette = WizardState::new(&command, Answers::new(), true);
    assert_eq!(
        from_palette.handle_key(&command, KeyAction::Back),
        WizardOutcome::BackToPalette
    );
    assert!(from_palette.answers().is_empty());

    let mut direct = WizardState::new(&command, Answers::new(), false);
    press_keys(&mut direct, &command, &[KeyAction::Back]);
    assert_eq!(direct.step_index(), 0);
    assert!(direct.answers().is_empty());
}

#[test]
fn wizard_zero_step_command_completes_immediately_but_cancel_always_cancels() {
    let command = CommandSpec::new(
        "guide",
        "Print Agent Review Guide",
        "Prints the review workflow guide.",
        vec![],
    );
    let mut wizard = WizardState::new(&command, Answers::new(), true);
    assert_eq!(wizard.immediate_completion(&command), Some(Answers::new()));
    assert!(!has_unanswered_active_step(&command, &Answers::new()));
    assert_eq!(
        wizard.handle_key(&command, KeyAction::Cancel),
        WizardOutcome::Cancelled
    );
}

#[test]
fn wizard_preselects_dynamic_select_default_and_toggles_boolean_to_true() {
    let command = dynamic_and_toggle_command();
    let mut wizard = WizardState::new(&command, Answers::new(), false);

    assert_eq!(wizard.selected_option_index(), 1);
    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);

    assert_eq!(wizard.selected_option_index(), 0);
    press_keys(&mut wizard, &command, &[KeyAction::Down]);
    assert_eq!(
        wizard.handle_key(&command, KeyAction::Confirm),
        WizardOutcome::Completed(Answers::from([
            ("pr".to_owned(), "12".to_owned()),
            ("is_local_only".to_owned(), "true".to_owned()),
        ]))
    );
}

#[test]
fn wizard_sets_error_ignores_navigation_and_allows_back_on_failed_or_empty_dynamic_select() {
    let command = failing_or_empty_dynamic_command();
    let mut wizard = WizardState::new(&command, Answers::new(), false);

    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);
    assert_eq!(wizard.validation_error(), Some("gh auth missing"));
    press_keys(
        &mut wizard,
        &command,
        &[
            KeyAction::Up,
            KeyAction::Down,
            KeyAction::First,
            KeyAction::Last,
            KeyAction::Confirm,
            KeyAction::Back,
        ],
    );
    assert_eq!(wizard.step_index(), 0);

    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Down, KeyAction::Confirm],
    );
    assert!(wizard.validation_error().is_some());
    press_keys(&mut wizard, &command, &[KeyAction::Down, KeyAction::Back]);
    assert_eq!(wizard.step_index(), 0);
}

#[test]
fn wizard_skips_prefilled_step_until_revisited_via_back() {
    let command = branching_command();
    let initial = Answers::from([("pr".to_owned(), "42".to_owned())]);
    let mut wizard = WizardState::new(&command, initial, false);

    // Advancing from unprefilled step 0 skips prefilled step 1 (`pr`) straight to step 2 (`repo`).
    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::Down, KeyAction::Confirm],
    );
    assert_eq!(wizard.step_index(), 2);
    assert_eq!(
        wizard.current_step(&command).map(|step| step.id.as_str()),
        Some("repo")
    );

    // Stepping Back lands on `pr` and unmarks it; stepping Back again returns to `target_mode`.
    press_keys(&mut wizard, &command, &[KeyAction::Back]);
    assert_eq!((wizard.step_index(), wizard.input_text()), (1, "42"));
    press_keys(&mut wizard, &command, &[KeyAction::Back]);
    assert_eq!(wizard.step_index(), 0);

    // Advancing forward again must now stop on `pr` instead of skipping it.
    press_keys(&mut wizard, &command, &[KeyAction::Confirm]);
    assert_eq!(wizard.step_index(), 1);
    assert_eq!(
        wizard.current_step(&command).map(|step| step.id.as_str()),
        Some("pr")
    );
}

#[test]
fn wizard_completes_when_trailing_steps_are_prefilled() {
    let command = branching_command();
    let initial = Answers::from([
        ("target_mode".to_owned(), "pr".to_owned()),
        ("repo".to_owned(), "octo/widgets".to_owned()),
    ]);
    let mut wizard = WizardState::new(&command, initial, false);
    assert_eq!(wizard.step_index(), 1);

    type_text(&mut wizard, &command, "9");
    assert_eq!(
        wizard.handle_key(&command, KeyAction::Confirm),
        WizardOutcome::Completed(Answers::from([
            ("target_mode".to_owned(), "pr".to_owned()),
            ("pr".to_owned(), "9".to_owned()),
            ("repo".to_owned(), "octo/widgets".to_owned()),
        ]))
    );
}
