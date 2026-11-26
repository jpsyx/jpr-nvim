//! Pure navigation and fuzzy-filter state for the top-level command palette.

use crate::schema::CommandSpec;

use super::KeyAction;
use super::fuzzy::filter_command_indices;

/// Outcome of handling one key action in [`PaletteState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaletteAction {
    /// Stay in the palette and redraw.
    Continue,
    /// The user selected the command at the given index in the unfiltered command slice.
    Selected(usize),
    /// The user cancelled the palette.
    Cancelled,
}

/// Pure navigation and live-filter state for the top-level command palette.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PaletteState {
    selected_index: usize,
    query: String,
    cursor_char_index: usize,
}

impl PaletteState {
    /// Creates a palette state focused on the first command with an empty filter.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            selected_index: 0,
            query: String::new(),
            cursor_char_index: 0,
        }
    }

    /// Creates a palette state focused on `selected_index` with an empty filter.
    #[must_use]
    pub const fn with_selected(selected_index: usize) -> Self {
        Self {
            selected_index,
            query: String::new(),
            cursor_char_index: 0,
        }
    }

    /// Returns the index of the currently highlighted command within the filtered list.
    #[must_use]
    pub const fn selected_index(&self) -> usize {
        self.selected_index
    }

    /// Returns the current filter query text.
    #[must_use]
    pub fn query(&self) -> &str {
        &self.query
    }

    /// Returns the character cursor offset inside [`Self::query`].
    #[must_use]
    pub const fn cursor_char_index(&self) -> usize {
        self.cursor_char_index
    }

    /// Clears the filter query and resets the cursor and selection to the start.
    pub fn clear_query(&mut self) {
        self.query.clear();
        self.cursor_char_index = 0;
        self.selected_index = 0;
    }

    /// Returns the indices into `commands` matching the current filter query.
    #[must_use]
    pub fn filtered_command_indices(&self, commands: &[CommandSpec]) -> Vec<usize> {
        filter_command_indices(commands, &self.query)
    }

    /// Applies `action` against `commands`, updating the filter or selection.
    pub fn handle_key(&mut self, action: KeyAction, commands: &[CommandSpec]) -> PaletteAction {
        if self.apply_query_edit(action) {
            return PaletteAction::Continue;
        }
        let filtered_indices = self.filtered_command_indices(commands);
        self.apply_navigation_action(action, &filtered_indices)
    }

    const fn apply_navigation_action(
        &mut self,
        action: KeyAction,
        filtered_indices: &[usize],
    ) -> PaletteAction {
        let match_count = filtered_indices.len();
        if match_count == 0 {
            return match action {
                KeyAction::Cancel => PaletteAction::Cancelled,
                _ => PaletteAction::Continue,
            };
        }
        if self.selected_index >= match_count {
            self.selected_index = match_count - 1;
        }
        match action {
            KeyAction::Up => {
                self.selected_index = (self.selected_index + match_count - 1) % match_count;
                PaletteAction::Continue
            }
            KeyAction::Down => {
                self.selected_index = (self.selected_index + 1) % match_count;
                PaletteAction::Continue
            }
            KeyAction::First => {
                self.selected_index = 0;
                PaletteAction::Continue
            }
            KeyAction::Last => {
                self.selected_index = match_count - 1;
                PaletteAction::Continue
            }
            KeyAction::Confirm => PaletteAction::Selected(filtered_indices[self.selected_index]),
            KeyAction::Cancel => PaletteAction::Cancelled,
            _ => PaletteAction::Continue,
        }
    }

    fn apply_query_edit(&mut self, action: KeyAction) -> bool {
        let char_count = self.query.chars().count();
        match action {
            KeyAction::Left => self.cursor_char_index = self.cursor_char_index.saturating_sub(1),
            KeyAction::Right if self.cursor_char_index < char_count => self.cursor_char_index += 1,
            KeyAction::Home => self.cursor_char_index = 0,
            KeyAction::End => self.cursor_char_index = char_count,
            KeyAction::ClearLine => self.clear_query(),
            KeyAction::Char(character) => {
                let byte_index = char_to_byte_index(&self.query, self.cursor_char_index);
                self.query.insert(byte_index, character);
                self.cursor_char_index += 1;
                self.selected_index = 0;
            }
            KeyAction::Backspace if self.cursor_char_index > 0 => {
                let start_byte = char_to_byte_index(&self.query, self.cursor_char_index - 1);
                let end_byte = char_to_byte_index(&self.query, self.cursor_char_index);
                self.query.replace_range(start_byte..end_byte, "");
                self.cursor_char_index -= 1;
                self.selected_index = 0;
            }
            KeyAction::Delete if self.cursor_char_index < char_count => {
                let start_byte = char_to_byte_index(&self.query, self.cursor_char_index);
                let end_byte = char_to_byte_index(&self.query, self.cursor_char_index + 1);
                self.query.replace_range(start_byte..end_byte, "");
                self.selected_index = 0;
            }
            KeyAction::Right | KeyAction::Backspace | KeyAction::Delete => {}
            _ => return false,
        }
        true
    }
}

fn char_to_byte_index(text: &str, char_index: usize) -> usize {
    text.char_indices()
        .nth(char_index)
        .map_or(text.len(), |(byte_index, _)| byte_index)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_commands() -> Vec<CommandSpec> {
        vec![
            CommandSpec::new("prs", "List Open Pull Requests", "List PRs.", vec![]),
            CommandSpec::new("checkout", "Check Out Pull Request", "Checkout.", vec![]),
            CommandSpec::new("threads", "List Review Threads", "Threads.", vec![]),
        ]
    }

    #[test]
    fn palette_state_wraps_navigation_and_selects_or_cancels() {
        let commands = sample_commands();
        let mut palette = PaletteState::new();
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Up, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 2);

        assert_eq!(
            palette.handle_key(KeyAction::Down, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Last, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 2);

        assert_eq!(
            palette.handle_key(KeyAction::First, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.selected_index(), 0);

        assert_eq!(
            palette.handle_key(KeyAction::Down, &commands),
            PaletteAction::Continue
        );
        assert_eq!(
            palette.handle_key(KeyAction::Confirm, &commands),
            PaletteAction::Selected(1)
        );
        assert_eq!(
            palette.handle_key(KeyAction::Cancel, &commands),
            PaletteAction::Cancelled
        );
    }

    #[test]
    fn palette_state_filters_commands_edits_query_and_clears_line() {
        let commands = sample_commands();
        let mut palette = PaletteState::new();

        for ch in "thr".chars() {
            assert_eq!(
                palette.handle_key(KeyAction::Char(ch), &commands),
                PaletteAction::Continue
            );
        }
        assert_eq!(palette.query(), "thr");
        assert_eq!(palette.filtered_command_indices(&commands), vec![2]);
        assert_eq!(
            palette.handle_key(KeyAction::Confirm, &commands),
            PaletteAction::Selected(2)
        );

        assert_eq!(
            palette.handle_key(KeyAction::Left, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.cursor_char_index(), 2);
        assert_eq!(
            palette.handle_key(KeyAction::Delete, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.query(), "th");

        assert_eq!(
            palette.handle_key(KeyAction::ClearLine, &commands),
            PaletteAction::Continue
        );
        assert_eq!(palette.query(), "");
        assert_eq!(palette.cursor_char_index(), 0);
        assert_eq!(palette.filtered_command_indices(&commands), vec![0, 1, 2]);
    }

    #[test]
    fn palette_state_continues_on_empty_or_unmatched_list_and_clamps_selection() {
        let commands = sample_commands();
        let mut empty = PaletteState::new();
        assert_eq!(
            empty.handle_key(KeyAction::Up, &[]),
            PaletteAction::Continue
        );
        assert_eq!(
            empty.handle_key(KeyAction::Down, &[]),
            PaletteAction::Continue
        );
        assert_eq!(
            empty.handle_key(KeyAction::Confirm, &[]),
            PaletteAction::Continue
        );
        assert_eq!(
            empty.handle_key(KeyAction::Cancel, &[]),
            PaletteAction::Cancelled
        );

        let mut unmatched = PaletteState::new();
        for ch in "zzzz".chars() {
            let _ = unmatched.handle_key(KeyAction::Char(ch), &commands);
        }
        assert_eq!(
            unmatched.handle_key(KeyAction::Confirm, &commands),
            PaletteAction::Continue
        );
        assert_eq!(
            unmatched.handle_key(KeyAction::Cancel, &commands),
            PaletteAction::Cancelled
        );

        let mut clamped = PaletteState::with_selected(99);
        assert_eq!(
            clamped.handle_key(KeyAction::Confirm, &commands[..2]),
            PaletteAction::Selected(1)
        );
    }
}
