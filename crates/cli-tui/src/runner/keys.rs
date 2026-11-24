//! Translation of crossterm key events into semantic [`KeyAction`] values.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::state::KeyAction;

pub(super) const fn key_event_to_action(event: KeyEvent, is_text_input: bool) -> Option<KeyAction> {
    if !matches!(event.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        return None;
    }
    if event.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(event.code, KeyCode::Char('c' | 'C'))
    {
        return Some(KeyAction::Cancel);
    }
    if is_text_input {
        map_text_key(event)
    } else {
        map_menu_key(event)
    }
}

const fn map_menu_key(event: KeyEvent) -> Option<KeyAction> {
    let has_disallowed_modifier = event
        .modifiers
        .intersects(KeyModifiers::CONTROL.union(KeyModifiers::ALT));
    if has_disallowed_modifier {
        return None;
    }
    match event.code {
        KeyCode::Up | KeyCode::Char('k') => Some(KeyAction::Up),
        KeyCode::Down | KeyCode::Char('j') => Some(KeyAction::Down),
        KeyCode::Home | KeyCode::Char('g') => Some(KeyAction::First),
        KeyCode::End | KeyCode::Char('G') => Some(KeyAction::Last),
        KeyCode::Left | KeyCode::Char('h') | KeyCode::BackTab => Some(KeyAction::Back),
        KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab | KeyCode::Enter => {
            Some(KeyAction::Confirm)
        }
        KeyCode::Esc | KeyCode::Char('q') => Some(KeyAction::Cancel),
        _ => None,
    }
}

const fn map_text_key(event: KeyEvent) -> Option<KeyAction> {
    match event.code {
        KeyCode::BackTab => Some(KeyAction::Back),
        KeyCode::Tab | KeyCode::Enter => Some(KeyAction::Confirm),
        KeyCode::Esc => Some(KeyAction::Cancel),
        KeyCode::Left => Some(KeyAction::Left),
        KeyCode::Right => Some(KeyAction::Right),
        KeyCode::Home => Some(KeyAction::Home),
        KeyCode::End => Some(KeyAction::End),
        KeyCode::Backspace => Some(KeyAction::Backspace),
        KeyCode::Delete => Some(KeyAction::Delete),
        KeyCode::Char(character)
            if !event
                .modifiers
                .intersects(KeyModifiers::CONTROL.union(KeyModifiers::ALT)) =>
        {
            Some(KeyAction::Char(character))
        }
        _ => None,
    }
}
