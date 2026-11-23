//! Pure state machines for the command palette and step-by-step wizard.

mod palette;
mod wizard;

pub use palette::{PaletteAction, PaletteState};
pub use wizard::{WizardOutcome, WizardState, has_unanswered_active_step};

/// Semantic input actions handled by [`PaletteState`] and [`WizardState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    /// Move selection up one item.
    Up,
    /// Move selection down one item.
    Down,
    /// Jump to the first item.
    First,
    /// Jump to the last item.
    Last,
    /// Step back to the previous step or palette.
    Back,
    /// Confirm the current selection or text input.
    Confirm,
    /// Cancel and exit the interactive flow.
    Cancel,
    /// Move the text cursor one character left.
    Left,
    /// Move the text cursor one character right.
    Right,
    /// Move the text cursor to the start of the line.
    Home,
    /// Move the text cursor to the end of the line.
    End,
    /// Delete the character immediately before the text cursor.
    Backspace,
    /// Delete the character at the text cursor.
    Delete,
    /// Insert one Unicode scalar value at the text cursor.
    Char(char),
}
