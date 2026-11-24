//! Raw-mode RAII guard, stderr frame clearing, visual row measurement, and color detection.

use std::io::{IsTerminal, Write};

use anyhow::{Context, Result};
use crossterm::cursor;
use crossterm::terminal::{self, ClearType};
use crossterm::{execute, queue};

const DEFAULT_TERMINAL_WIDTH: usize = 80;
const MIN_TERMINAL_WIDTH: usize = 1;

/// RAII guard that enables terminal raw mode, hides the cursor, renders frames
/// exclusively to stderr, and restores terminal state on drop.
pub(super) struct RawModeGuard {
    rendered_lines: u16,
}

impl RawModeGuard {
    pub(super) fn new() -> Result<Self> {
        terminal::enable_raw_mode().context("enabling terminal raw mode")?;
        let mut stderr = std::io::stderr();
        if let Err(error) = execute!(stderr, cursor::Hide) {
            let _ = terminal::disable_raw_mode();
            return Err(error).context("hiding terminal cursor");
        }
        Ok(Self { rendered_lines: 0 })
    }

    pub(super) fn render_frame(&mut self, frame: &str, columns: usize) -> Result<()> {
        let mut stderr = std::io::stderr();
        clear_previous_frame(&mut stderr, self.rendered_lines)
            .context("clearing previous TUI frame on stderr")?;
        self.rendered_lines = 0;

        for line in frame.split('\n') {
            write!(stderr, "{line}\r\n").context("writing TUI frame line to stderr")?;
            let visual_rows = count_visual_rows(line, columns);
            self.rendered_lines = self.rendered_lines.saturating_add(visual_rows);
        }
        stderr.flush().context("flushing TUI frame to stderr")?;
        Ok(())
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let mut stderr = std::io::stderr();
        let _ = clear_previous_frame(&mut stderr, self.rendered_lines);
        let _ = execute!(stderr, cursor::Show);
        let _ = stderr.flush();
        let _ = terminal::disable_raw_mode();
    }
}

fn clear_previous_frame(stderr: &mut std::io::Stderr, rendered_lines: u16) -> std::io::Result<()> {
    if rendered_lines > 0 {
        queue!(stderr, cursor::MoveUp(rendered_lines))?;
    }
    queue!(
        stderr,
        cursor::MoveToColumn(0),
        terminal::Clear(ClearType::FromCursorDown)
    )
}

/// Computes the number of visual terminal rows occupied by `line` at `columns`
/// width, ignoring ANSI CSI escape sequences.
pub(super) fn count_visual_rows(line: &str, columns: usize) -> u16 {
    let visible_chars = visible_char_count(line);
    let rows = visible_chars.div_ceil(columns.max(1)).max(1);
    u16::try_from(rows).unwrap_or(u16::MAX)
}

fn visible_char_count(line: &str) -> usize {
    let mut visible_count = 0;
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\x1b' && chars.peek() == Some(&'[') {
            let _ = chars.next();
            for escape_char in chars.by_ref() {
                if ('@'..='~').contains(&escape_char) {
                    break;
                }
            }
        } else {
            visible_count += 1;
        }
    }
    visible_count
}

pub(super) fn terminal_width() -> usize {
    terminal::size().map_or(DEFAULT_TERMINAL_WIDTH, |(columns, _)| {
        usize::from(columns).max(MIN_TERMINAL_WIDTH)
    })
}

pub(super) fn should_use_color() -> bool {
    std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}
