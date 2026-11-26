//! Unit tests for runner key mapping, visual row measurement, and pre-raw-mode guards.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::schema::{Answers, CommandSpec};
use crate::state::KeyAction;

use super::keys::{KeyMode, key_event_to_action};
use super::terminal::count_visual_rows;
use super::{CommandOutcome, run_command, run_palette};

fn press(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent::new_with_kind(code, modifiers, KeyEventKind::Press)
}

#[test]
fn menu_key_mapping_maps_vim_and_arrow_keys_to_navigation_actions() {
    let cases = [
        (KeyCode::Up, KeyModifiers::NONE, KeyAction::Up),
        (KeyCode::Down, KeyModifiers::NONE, KeyAction::Down),
        (KeyCode::Left, KeyModifiers::NONE, KeyAction::Back),
        (KeyCode::Right, KeyModifiers::NONE, KeyAction::Confirm),
        (KeyCode::Char('j'), KeyModifiers::NONE, KeyAction::Down),
        (KeyCode::Char('k'), KeyModifiers::NONE, KeyAction::Up),
        (KeyCode::Char('h'), KeyModifiers::NONE, KeyAction::Back),
        (KeyCode::Char('l'), KeyModifiers::NONE, KeyAction::Confirm),
        (KeyCode::Char('G'), KeyModifiers::SHIFT, KeyAction::Last),
        (KeyCode::Char('q'), KeyModifiers::NONE, KeyAction::Cancel),
    ];
    for (code, modifiers, expected) in cases {
        assert_eq!(
            key_event_to_action(press(code, modifiers), KeyMode::Menu),
            Some(expected),
            "unexpected mapping for {code:?} with {modifiers:?}"
        );
    }
}

#[test]
fn menu_key_mapping_ignores_ctrl_and_alt_except_ctrl_c() {
    assert_eq!(
        key_event_to_action(
            press(KeyCode::Char('l'), KeyModifiers::CONTROL),
            KeyMode::Menu
        ),
        None
    );
    assert_eq!(
        key_event_to_action(
            press(KeyCode::Char('j'), KeyModifiers::CONTROL),
            KeyMode::Menu
        ),
        None
    );
    assert_eq!(
        key_event_to_action(press(KeyCode::Char('k'), KeyModifiers::ALT), KeyMode::Menu),
        None
    );
    assert_eq!(
        key_event_to_action(
            press(KeyCode::Char('q'), KeyModifiers::CONTROL),
            KeyMode::Menu
        ),
        None
    );
    assert_eq!(
        key_event_to_action(
            press(KeyCode::Char('c'), KeyModifiers::CONTROL),
            KeyMode::Menu
        ),
        Some(KeyAction::Cancel)
    );
}

#[test]
fn text_key_mapping_treats_letters_as_input_and_ctrl_c_as_cancel() {
    assert_eq!(
        key_event_to_action(press(KeyCode::Char('j'), KeyModifiers::NONE), KeyMode::Text),
        Some(KeyAction::Char('j'))
    );
    assert_eq!(
        key_event_to_action(press(KeyCode::BackTab, KeyModifiers::SHIFT), KeyMode::Text),
        Some(KeyAction::Back)
    );
    assert_eq!(
        key_event_to_action(
            press(KeyCode::Char('c'), KeyModifiers::CONTROL),
            KeyMode::Text
        ),
        Some(KeyAction::Cancel)
    );
}

#[test]
fn palette_key_mapping_routes_typing_to_filter_and_ctrl_jku_to_navigation_and_clear() {
    let cases = [
        (KeyCode::Char('j'), KeyModifiers::CONTROL, KeyAction::Down),
        (KeyCode::Char('k'), KeyModifiers::CONTROL, KeyAction::Up),
        (
            KeyCode::Char('u'),
            KeyModifiers::CONTROL,
            KeyAction::ClearLine,
        ),
        (KeyCode::Down, KeyModifiers::NONE, KeyAction::Down),
        (KeyCode::Up, KeyModifiers::NONE, KeyAction::Up),
        (KeyCode::Enter, KeyModifiers::NONE, KeyAction::Confirm),
        (KeyCode::Tab, KeyModifiers::NONE, KeyAction::Confirm),
        (KeyCode::Esc, KeyModifiers::NONE, KeyAction::Cancel),
        (KeyCode::Char('c'), KeyModifiers::CONTROL, KeyAction::Cancel),
        (KeyCode::Char('j'), KeyModifiers::NONE, KeyAction::Char('j')),
        (KeyCode::Char('k'), KeyModifiers::NONE, KeyAction::Char('k')),
        (KeyCode::Char('q'), KeyModifiers::NONE, KeyAction::Char('q')),
        (KeyCode::Backspace, KeyModifiers::NONE, KeyAction::Backspace),
        (KeyCode::Delete, KeyModifiers::NONE, KeyAction::Delete),
        (KeyCode::Left, KeyModifiers::NONE, KeyAction::Left),
        (KeyCode::Right, KeyModifiers::NONE, KeyAction::Right),
        (KeyCode::Home, KeyModifiers::NONE, KeyAction::Home),
        (KeyCode::End, KeyModifiers::NONE, KeyAction::End),
    ];
    for (code, modifiers, expected) in cases {
        assert_eq!(
            key_event_to_action(press(code, modifiers), KeyMode::Palette),
            Some(expected),
            "unexpected palette mapping for {code:?} with {modifiers:?}"
        );
    }
}

#[test]
fn key_release_events_are_ignored() {
    let release =
        KeyEvent::new_with_kind(KeyCode::Enter, KeyModifiers::NONE, KeyEventKind::Release);
    assert_eq!(key_event_to_action(release, KeyMode::Menu), None);
}

#[test]
fn count_visual_rows_strips_ansi_and_accounts_for_soft_wrapping() {
    assert_eq!(count_visual_rows("", 80), 1);
    assert_eq!(count_visual_rows("short", 10), 1);
    assert_eq!(count_visual_rows("0123456789", 10), 1);
    assert_eq!(count_visual_rows("0123456789a", 10), 2);
    assert_eq!(count_visual_rows("\x1b[1;96m▸ hello\x1b[0m", 10), 1);
    assert_eq!(
        count_visual_rows("\x1b[90m012345678901234567890\x1b[0m", 10),
        3
    );
    assert_eq!(count_visual_rows("🦀🦀🦀🦀🦀", 4), 2);
}

#[test]
fn run_command_completes_immediately_when_no_active_steps_remain() {
    let guide = CommandSpec::new("guide", "Guide", "Print review guide.", vec![]);
    let outcome = run_command(&guide, Answers::new()).unwrap();
    assert_eq!(outcome, CommandOutcome::Completed(Answers::new()));
}

#[test]
fn run_command_and_run_palette_reject_invalid_schemas_before_raw_mode() {
    let invalid = CommandSpec::new("", "Bad", "Missing id.", vec![]);
    assert!(run_command(&invalid, Answers::new()).is_err());
    assert!(run_palette("Palette", &[invalid]).is_err());
}
