//! Unit tests for palette and wizard frame rendering.

use super::*;
use crate::schema::{Answers, SelectOption, StepKind, StepSpec};
use crate::state::KeyAction;

fn sample_commands() -> Vec<CommandSpec> {
    vec![
        CommandSpec::new(
            "prs",
            "List Open Pull Requests",
            "Fetches open pull requests in the current or specified repository.",
            vec![],
        ),
        CommandSpec::new(
            "checkout",
            "Check Out Pull Request",
            "Checks out a pull request branch into a local worktree.",
            vec![],
        ),
    ]
}

fn sample_wizard_command() -> CommandSpec {
    CommandSpec::new(
        "threads",
        "List Review Threads",
        "Lists review threads.",
        vec![
            StepSpec::new(
                "target_mode",
                "Target Source",
                "Choose how to locate the review.",
                StepKind::Select(vec![
                    SelectOption::new("socket", "Live Socket")
                        .with_badge("fast")
                        .with_help("Connect directly to a running daemon."),
                    SelectOption::new("pr", "Pull Request")
                        .with_help("Read saved review state from disk."),
                ]),
            ),
            StepSpec::new(
                "pr",
                "Pull Request Number",
                "Enter the numeric PR ID.",
                StepKind::Text {
                    placeholder: Some("42".to_owned()),
                },
            )
            .with_default("99")
            .with_validate(|value, _| {
                value
                    .trim()
                    .parse::<u64>()
                    .map(|_| ())
                    .map_err(|_| "Must be a number.".to_owned())
            }),
            StepSpec::new(
                "repo",
                "Repository",
                "Owner and repo slug.",
                StepKind::Text {
                    placeholder: Some("octo/widgets".to_owned()),
                },
            ),
        ],
    )
}

#[test]
fn render_palette_shows_filter_prompt_labels_ids_and_hover_only_help() {
    let commands = sample_commands();
    let mut state = PaletteState::new();

    let first_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
    assert!(first_frame.contains("> (Type to filter commands...)"));
    assert!(first_frame.contains("▸ List Open Pull Requests  [prs]"));
    assert!(first_frame.contains("  Check Out Pull Request  [checkout]"));
    assert!(first_frame.contains("Fetches open pull requests"));
    assert!(!first_frame.contains("Checks out a pull request branch"));
    assert!(!first_frame.contains("\x1b["));

    let _ = state.handle_key(KeyAction::Down, &commands);
    let second_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
    assert!(second_frame.contains("  List Open Pull Requests  [prs]"));
    assert!(second_frame.contains("▸ Check Out Pull Request  [checkout]"));
    assert!(!second_frame.contains("Fetches open pull requests"));
    assert!(second_frame.contains("Checks out a pull request branch"));
    assert!(
        second_frame.contains(
            "[type] filter  [Ctrl+j/k] move  [Ctrl+u] clear  [Enter] select  [Esc] close"
        )
    );

    for ch in "chk".chars() {
        let _ = state.handle_key(KeyAction::Char(ch), &commands);
    }
    let filtered_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
    assert!(filtered_frame.contains("> chk"));
    assert!(filtered_frame.contains("▸ Check Out Pull Request  [checkout]"));
    assert!(!filtered_frame.contains("List Open Pull Requests"));

    for ch in "zzz".chars() {
        let _ = state.handle_key(KeyAction::Char(ch), &commands);
    }
    let no_match_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
    assert!(no_match_frame.contains("(no matching commands)"));
}

#[test]
fn render_palette_shows_empty_placeholder_and_clamps_out_of_bounds_index() {
    let empty = render_palette("Commands", &[], &PaletteState::with_selected(5), 80, false);
    assert!(empty.contains("(no commands available)"));

    let commands = sample_commands();
    let clamped = render_palette(
        "Commands",
        &commands,
        &PaletteState::with_selected(99),
        80,
        false,
    );
    assert!(clamped.contains("▸ Check Out Pull Request  [checkout]"));
    assert!(clamped.contains("Checks out a pull request branch"));
}

#[test]
fn render_palette_emits_ansi_dim_when_color_enabled() {
    let commands = sample_commands();
    let state = PaletteState::new();
    let colored = render_palette("jpr-review Commands", &commands, &state, 80, true);
    assert!(colored.contains("\x1b[90m"));
    assert!(colored.contains("[prs]"));
}

#[test]
fn render_wizard_shows_progress_hover_help_prefill_and_errors() {
    let command = sample_wizard_command();
    let mut wizard = WizardState::new(&command, Answers::new(), true);

    let step_one = render_wizard(&command, &wizard, 80, false);
    assert!(step_one.contains("Step 1 of 3 · Target Source"));
    assert!(step_one.contains("Choose how to locate the review."));
    assert!(step_one.contains("▸ Live Socket  [fast]"));
    assert!(step_one.contains("Connect directly to a running daemon."));
    assert!(!step_one.contains("Read saved review state from disk."));
    assert!(step_one.contains("[h] palette"));
    assert!(!step_one.contains("\x1b["));

    let _ = wizard.handle_key(&command, KeyAction::Confirm);
    let step_two = render_wizard(&command, &wizard, 80, false);
    assert!(step_two.contains("Step 2 of 3 · Pull Request Number"));
    assert!(step_two.contains("> 99"));
    assert!(step_two.contains("[Enter/Tab] next"));
    assert!(step_two.contains("[S-Tab] back"));
    assert!(!step_two.contains("\x1b["));

    let _ = wizard.handle_key(&command, KeyAction::Char('a'));
    let _ = wizard.handle_key(&command, KeyAction::Confirm);
    let step_two_error = render_wizard(&command, &wizard, 80, true);
    assert!(step_two_error.contains("\x1b[91m"));
    assert!(step_two_error.contains("Must be a number."));

    let _ = wizard.handle_key(&command, KeyAction::Backspace);
    let _ = wizard.handle_key(&command, KeyAction::Confirm);
    let step_three = render_wizard(&command, &wizard, 80, false);
    assert!(step_three.contains("Step 3 of 3 · Repository"));
    assert!(step_three.contains("> (octo/widgets)"));
    assert!(step_three.contains("[Enter/Tab] run"));
    assert!(!step_three.contains("\x1b["));
}

#[test]
fn render_palette_wraps_help_strictly_within_narrow_widths() {
    let commands = vec![CommandSpec::new(
        "checkout",
        "Check Out Pull Request",
        "Checks out a pull request branch into a local git worktree for side-by-side review.",
        vec![],
    )];
    let state = PaletteState::new();

    for width in [36, 14, 10, 4] {
        let frame = render_palette("Commands", &commands, &state, width, false);
        let lines: Vec<&str> = frame.lines().collect();
        let help_lines = &lines[4..lines.len() - 2];
        assert!(help_lines.len() >= 2);
        for line in help_lines {
            assert!(
                line.chars().count() <= width,
                "wrapped help line exceeded width {width}: {line:?}"
            );
        }
    }
}
