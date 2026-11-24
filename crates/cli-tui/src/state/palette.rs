//! Pure navigation state for the top-level command palette.

use super::KeyAction;

/// Outcome of handling one key action in [`PaletteState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaletteAction {
    /// Stay in the palette and redraw.
    Continue,
    /// The user selected the command at the given index.
    Selected(usize),
    /// The user cancelled the palette.
    Cancelled,
}

/// Pure navigation state for the top-level command palette.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PaletteState {
    selected_index: usize,
}

impl PaletteState {
    /// Creates a palette state focused on the first command.
    #[must_use]
    pub const fn new() -> Self {
        Self { selected_index: 0 }
    }

    /// Creates a palette state focused on `selected_index`.
    #[must_use]
    pub const fn with_selected(selected_index: usize) -> Self {
        Self { selected_index }
    }

    /// Returns the index of the currently highlighted command.
    #[must_use]
    pub const fn selected_index(&self) -> usize {
        self.selected_index
    }

    /// Applies `action` against a palette containing `command_count` entries.
    pub const fn handle_key(&mut self, action: KeyAction, command_count: usize) -> PaletteAction {
        if command_count == 0 {
            return match action {
                KeyAction::Cancel => PaletteAction::Cancelled,
                _ => PaletteAction::Continue,
            };
        }
        if self.selected_index >= command_count {
            self.selected_index = command_count - 1;
        }
        match action {
            KeyAction::Up => {
                self.selected_index = (self.selected_index + command_count - 1) % command_count;
                PaletteAction::Continue
            }
            KeyAction::Down => {
                self.selected_index = (self.selected_index + 1) % command_count;
                PaletteAction::Continue
            }
            KeyAction::First => {
                self.selected_index = 0;
                PaletteAction::Continue
            }
            KeyAction::Last => {
                self.selected_index = command_count - 1;
                PaletteAction::Continue
            }
            KeyAction::Confirm => PaletteAction::Selected(self.selected_index),
            KeyAction::Cancel => PaletteAction::Cancelled,
            _ => PaletteAction::Continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_state_wraps_navigation_and_selects_or_cancels() {
        let mut palette = PaletteState::new();
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Up, 3),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 2);

        assert_eq!(
            palette.handle_key(KeyAction::Down, 3),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Last, 3),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 2);

        assert_eq!(
            palette.handle_key(KeyAction::First, 3),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Down, 3),
            PaletteAction::Continue
        );
        assert_eq!(
            palette.handle_key(KeyAction::Confirm, 3),
            PaletteAction::Selected(1)
        );
        assert_eq!(
            palette.handle_key(KeyAction::Cancel, 3),
            PaletteAction::Cancelled
        );
    }

    #[test]
    fn palette_state_continues_on_empty_list_and_clamps_out_of_bounds_selection() {
        let mut empty = PaletteState::new();
        assert_eq!(empty.handle_key(KeyAction::Up, 0), PaletteAction::Continue);
        assert_eq!(
            empty.handle_key(KeyAction::Down, 0),
            PaletteAction::Continue
        );
        assert_eq!(
            empty.handle_key(KeyAction::Confirm, 0),
            PaletteAction::Continue
        );
        assert_eq!(
            empty.handle_key(KeyAction::Cancel, 0),
            PaletteAction::Cancelled
        );

        let mut clamped = PaletteState::with_selected(99);
        assert_eq!(
            clamped.handle_key(KeyAction::Confirm, 2),
            PaletteAction::Selected(1)
        );
    }
}
