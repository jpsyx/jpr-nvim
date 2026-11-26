//! Translation of crossterm key events into semantic [`KeyAction`] values.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::state::KeyAction;

/// Input interpretation mode for [`key_event_to_action`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum KeyMode {
    /// Normal-mode wizard menu or toggle step.
    Menu,
    /// Single-line wizard text-input step.
    Text,
    /// Type-to-filter top-level command palette.
    Palette,
}

pub(super) const fn key_event_to_action(event: KeyEvent, mode: KeyMode) -> Option<KeyAction> {
    if !matches!(event.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        return None;
    }
    if event.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(event.code, KeyCode::Char('c' | 'C'))
    {
        return Some(KeyAction::Cancel);
    }
    match mode {
        KeyMode::Menu => map_menu_key(event),
        KeyMode::Text => map_text_key(event),
        KeyMode::Palette => map_palette_key(event),
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

const fn map_palette_key(event: KeyEvent) -> Option<KeyAction> {
    if event.modifiers.contains(KeyModifiers::CONTROL)
        && !event.modifiers.contains(KeyModifiers::ALT)
    {
        return match event.code {
            KeyCode::Char('j' | 'J') => Some(KeyAction::Down),
            KeyCode::Char('k' | 'K') => Some(KeyAction::Up),
            KeyCode::Char('u' | 'U') => Some(KeyAction::ClearLine),
            _ => None,
        };
    }
    match event.code {
        KeyCode::Up => Some(KeyAction::Up),
        KeyCode::Down => Some(KeyAction::Down),
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
