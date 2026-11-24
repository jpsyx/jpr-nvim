//! Text-editing and UTF-8 cursor boundary unit tests for [`WizardState`].

use crate::schema::{Answers, CommandSpec};
use crate::state::KeyAction;

use super::super::WizardState;
use super::{press_keys, text_step, type_text};

fn reply_body_command() -> CommandSpec {
    CommandSpec::new(
        "reply",
        "Reply",
        "Send a reply.",
        vec![text_step("body", "Reply Body", "Type your reply.", None)],
    )
}

#[test]
fn wizard_ignores_out_of_bounds_cursor_keys_on_empty_text() {
    let command = reply_body_command();
    let mut wizard = WizardState::new(&command, Answers::new(), false);

    press_keys(
        &mut wizard,
        &command,
        &[
            KeyAction::Left,
            KeyAction::Right,
            KeyAction::Home,
            KeyAction::End,
            KeyAction::Backspace,
            KeyAction::Delete,
        ],
    );
    assert_eq!(wizard.input_text(), "");
    assert_eq!(wizard.cursor_char_index(), 0);
}

#[test]
fn wizard_edits_utf8_text_on_char_boundaries() {
    let command = reply_body_command();
    let mut wizard = WizardState::new(&command, Answers::new(), false);

    type_text(&mut wizard, &command, "héllo🦀");
    assert_eq!(
        (wizard.input_text(), wizard.cursor_char_index()),
        ("héllo🦀", 6)
    );

    // Right and Delete past end are no-ops; moving left past 🦀 inserts before it.
    press_keys(
        &mut wizard,
        &command,
        &[
            KeyAction::Right,
            KeyAction::Delete,
            KeyAction::Left,
            KeyAction::Char('!'),
        ],
    );
    assert_eq!(wizard.input_text(), "héllo!🦀");

    // Home clamps Left/Backspace, then Right + Delete removes 'é' and Backspace removes 'h'.
    press_keys(
        &mut wizard,
        &command,
        &[
            KeyAction::Home,
            KeyAction::Left,
            KeyAction::Backspace,
            KeyAction::Right,
            KeyAction::Delete,
            KeyAction::Backspace,
        ],
    );
    assert_eq!(wizard.input_text(), "llo!🦀");

    press_keys(
        &mut wizard,
        &command,
        &[KeyAction::End, KeyAction::Backspace],
    );
    assert_eq!(wizard.input_text(), "llo!");
}
