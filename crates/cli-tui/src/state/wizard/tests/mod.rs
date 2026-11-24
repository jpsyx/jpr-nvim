//! Shared test fixtures and key-driving helpers for [`WizardState`] unit tests.

mod editing;
mod navigation;

use crate::schema::{Answers, CommandSpec, SelectOption, StepKind, StepSpec};
use crate::state::KeyAction;

use super::{WizardOutcome, WizardState};

pub(super) fn text_step(id: &str, label: &str, help: &str, placeholder: Option<&str>) -> StepSpec {
    StepSpec::new(
        id,
        label,
        help,
        StepKind::Text {
            placeholder: placeholder.map(str::to_owned),
        },
    )
}

pub(super) fn when_target_mode(expected: &'static str) -> impl Fn(&Answers) -> bool {
    move |answers| answers.get("target_mode").map(String::as_str) == Some(expected)
}

fn validate_positive_pr(value: &str, _answers: &Answers) -> Result<(), String> {
    value
        .trim()
        .parse::<u64>()
        .map(|_| ())
        .map_err(|_| "Pull request must be a positive integer.".to_owned())
}

pub(super) fn branching_command() -> CommandSpec {
    CommandSpec::new(
        "threads",
        "List Review Threads",
        "Lists review threads from a socket or pull request.",
        vec![
            StepSpec::new(
                "target_mode",
                "Target Source",
                "Pick socket or pull request.",
                StepKind::Select(vec![
                    SelectOption::new("socket", "Live Socket"),
                    SelectOption::new("pr", "Pull Request"),
                ]),
            )
            .with_default("socket"),
            text_step(
                "socket",
                "Socket Path",
                "Path to running daemon socket.",
                Some("/tmp/jpr.sock"),
            )
            .with_default("/tmp/default.sock")
            .with_when(when_target_mode("socket")),
            text_step(
                "pr",
                "Pull Request Number",
                "Numeric PR identifier.",
                Some("42"),
            )
            .with_when(when_target_mode("pr"))
            .with_validate(validate_positive_pr),
            text_step(
                "repo",
                "Repository",
                "Owner/name repository slug.",
                Some("octo/widgets"),
            )
            .with_default("octo/widgets")
            .with_when(when_target_mode("pr")),
        ],
    )
}

pub(super) fn press_keys(wizard: &mut WizardState, command: &CommandSpec, actions: &[KeyAction]) {
    for &action in actions {
        assert_eq!(wizard.handle_key(command, action), WizardOutcome::Continue);
    }
}

pub(super) fn type_text(wizard: &mut WizardState, command: &CommandSpec, text: &str) {
    for character in text.chars() {
        assert_eq!(
            wizard.handle_key(command, KeyAction::Char(character)),
            WizardOutcome::Continue
        );
    }
}
