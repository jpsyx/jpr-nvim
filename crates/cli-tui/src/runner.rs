//! Terminal runner wiring raw-mode input and stderr rendering to the pure TUI engine.

use std::io::{IsTerminal, Write};

use anyhow::{Context, Result, anyhow};
use crossterm::cursor;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::terminal::{self, ClearType};
use crossterm::{execute, queue};

use crate::render::{render_palette, render_wizard};
use crate::schema::{Answers, CommandSpec, prune_inactive_answers, validate_command_specs};
use crate::state::{
    KeyAction, PaletteAction, PaletteState, WizardOutcome, WizardState, has_unanswered_active_step,
};

const DEFAULT_TERMINAL_WIDTH: usize = 80;
const MIN_TERMINAL_WIDTH: usize = 1;

/// Outcome of running the interactive top-level command palette.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaletteOutcome {
    /// The user chose a command and finished all of its active steps.
    Completed {
        /// Identifier of the selected [`CommandSpec`].
        command_id: String,
        /// Pruned answers collected for that command.
        answers: Answers,
    },
    /// The user closed the palette without running a command.
    Cancelled,
}

/// Outcome of running a single command's interactive stepper.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandOutcome {
    /// All active steps completed with pruned answers.
    Completed(Answers),
    /// The user cancelled the wizard before completing it.
    Cancelled,
}

/// Returns `true` when both standard input and standard error are attached to a TTY.
#[must_use]
pub fn is_interactive_terminal() -> bool {
    std::io::stdin().is_terminal() && std::io::stderr().is_terminal()
}

/// Runs the interactive command palette on stderr, looping cleanly between the
/// palette and a selected command's wizard when the user steps back from step 1.
pub fn run_palette(title: &str, commands: &[CommandSpec]) -> Result<PaletteOutcome> {
    validate_command_specs(commands)
        .map_err(|message| anyhow!("invalid command schema: {message}"))?;
    if commands.is_empty() {
        return Ok(PaletteOutcome::Cancelled);
    }

    let mut terminal_guard = RawModeGuard::new()?;
    let mut palette_state = PaletteState::new();
    let use_color = should_use_color();

    loop {
        let selected_index = match run_palette_loop(
            &mut terminal_guard,
            title,
            commands,
            &mut palette_state,
            use_color,
        )? {
            PaletteAction::Selected(index) => index,
            PaletteAction::Cancelled => return Ok(PaletteOutcome::Cancelled),
            PaletteAction::Continue => continue,
        };

        if let Some(outcome) =
            run_selected_command(&mut terminal_guard, &commands[selected_index], use_color)?
        {
            return Ok(outcome);
        }
    }
}

fn run_selected_command(
    terminal_guard: &mut RawModeGuard,
    command: &CommandSpec,
    use_color: bool,
) -> Result<Option<PaletteOutcome>> {
    let mut wizard_state = WizardState::new(command, Answers::new(), true);
    if let Some(answers) = wizard_state.immediate_completion(command) {
        return Ok(Some(PaletteOutcome::Completed {
            command_id: command.id.clone(),
            answers,
        }));
    }

    match run_wizard_loop(terminal_guard, command, &mut wizard_state, use_color)? {
        WizardOutcome::Completed(answers) => Ok(Some(PaletteOutcome::Completed {
            command_id: command.id.clone(),
            answers,
        })),
        WizardOutcome::Cancelled => Ok(Some(PaletteOutcome::Cancelled)),
        WizardOutcome::BackToPalette | WizardOutcome::Continue => Ok(None),
    }
}

/// Runs the interactive stepper for a single command on stderr.
///
/// Returns [`CommandOutcome::Completed`] immediately (without touching the
/// terminal) when zero active steps remain unanswered in `initial_answers`.
pub fn run_command(command: &CommandSpec, initial_answers: Answers) -> Result<CommandOutcome> {
    validate_command_specs(std::slice::from_ref(command))
        .map_err(|message| anyhow!("invalid command schema: {message}"))?;

    if !has_unanswered_active_step(command, &initial_answers) {
        return Ok(CommandOutcome::Completed(prune_inactive_answers(
            command,
            &initial_answers,
        )));
    }

    let mut wizard_state = WizardState::new(command, initial_answers, false);
    if let Some(answers) = wizard_state.immediate_completion(command) {
        return Ok(CommandOutcome::Completed(answers));
    }

    let mut terminal_guard = RawModeGuard::new()?;
    let use_color = should_use_color();
    match run_wizard_loop(&mut terminal_guard, command, &mut wizard_state, use_color)? {
        WizardOutcome::Completed(answers) => Ok(CommandOutcome::Completed(answers)),
        WizardOutcome::Cancelled | WizardOutcome::BackToPalette | WizardOutcome::Continue => {
            Ok(CommandOutcome::Cancelled)
        }
    }
}

/// RAII guard that enables terminal raw mode, hides the cursor, renders frames
/// exclusively to stderr, and restores terminal state on drop.
struct RawModeGuard {
    rendered_lines: u16,
}

impl RawModeGuard {
    fn new() -> Result<Self> {
        terminal::enable_raw_mode().context("enabling terminal raw mode")?;
        let mut stderr = std::io::stderr();
        if let Err(error) = execute!(stderr, cursor::Hide) {
            let _ = terminal::disable_raw_mode();
            return Err(error).context("hiding terminal cursor");
        }
        Ok(Self { rendered_lines: 0 })
    }

    fn render_frame(&mut self, frame: &str, columns: usize) -> Result<()> {
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

fn run_palette_loop(
    terminal_guard: &mut RawModeGuard,
    title: &str,
    commands: &[CommandSpec],
    palette_state: &mut PaletteState,
    use_color: bool,
) -> Result<PaletteAction> {
    loop {
        let width = terminal_width();
        let frame = render_palette(title, commands, palette_state, width, use_color);
        terminal_guard.render_frame(&frame, width)?;

        if let Event::Key(key_event) = event::read().context("reading terminal input event")? {
            let Some(action) = key_event_to_action(key_event, false) else {
                continue;
            };
            match palette_state.handle_key(action, commands.len()) {
                PaletteAction::Continue => {}
                outcome @ (PaletteAction::Selected(_) | PaletteAction::Cancelled) => {
                    return Ok(outcome);
                }
            }
        }
    }
}

fn run_wizard_loop(
    terminal_guard: &mut RawModeGuard,
    command: &CommandSpec,
    wizard_state: &mut WizardState,
    use_color: bool,
) -> Result<WizardOutcome> {
    loop {
        let width = terminal_width();
        let frame = render_wizard(command, wizard_state, width, use_color);
        terminal_guard.render_frame(&frame, width)?;

        if let Event::Key(key_event) = event::read().context("reading terminal input event")? {
            let is_text_input = wizard_state.is_text_step(command);
            let Some(action) = key_event_to_action(key_event, is_text_input) else {
                continue;
            };
            match wizard_state.handle_key(command, action) {
                WizardOutcome::Continue => {}
                outcome => return Ok(outcome),
            }
        }
    }
}

pub(crate) const fn key_event_to_action(event: KeyEvent, is_text_input: bool) -> Option<KeyAction> {
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

/// Computes the number of visual terminal rows occupied by `line` at `columns`
/// width, ignoring ANSI CSI escape sequences.
pub(crate) fn count_visual_rows(line: &str, columns: usize) -> u16 {
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

fn terminal_width() -> usize {
    terminal::size().map_or(DEFAULT_TERMINAL_WIDTH, |(columns, _)| {
        usize::from(columns).max(MIN_TERMINAL_WIDTH)
    })
}

fn should_use_color() -> bool {
    std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEventKind;

    fn press(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new_with_kind(code, modifiers, KeyEventKind::Press)
    }

    #[test]
    fn menu_key_mapping_supports_vim_and_arrow_keys() {
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('j'), KeyModifiers::NONE), false),
            Some(KeyAction::Down)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('k'), KeyModifiers::NONE), false),
            Some(KeyAction::Up)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('h'), KeyModifiers::NONE), false),
            Some(KeyAction::Back)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('l'), KeyModifiers::NONE), false),
            Some(KeyAction::Confirm)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('G'), KeyModifiers::SHIFT), false),
            Some(KeyAction::Last)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('q'), KeyModifiers::NONE), false),
            Some(KeyAction::Cancel)
        );
    }

    #[test]
    fn menu_key_mapping_ignores_ctrl_and_alt_except_ctrl_c() {
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('l'), KeyModifiers::CONTROL), false),
            None
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('j'), KeyModifiers::CONTROL), false),
            None
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('k'), KeyModifiers::ALT), false),
            None
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('q'), KeyModifiers::CONTROL), false),
            None
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('c'), KeyModifiers::CONTROL), false),
            Some(KeyAction::Cancel)
        );
    }

    #[test]
    fn text_key_mapping_treats_letters_as_input_and_ctrl_c_as_cancel() {
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('j'), KeyModifiers::NONE), true),
            Some(KeyAction::Char('j'))
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::BackTab, KeyModifiers::SHIFT), true),
            Some(KeyAction::Back)
        );
        assert_eq!(
            key_event_to_action(press(KeyCode::Char('c'), KeyModifiers::CONTROL), true),
            Some(KeyAction::Cancel)
        );
    }

    #[test]
    fn key_release_events_are_ignored() {
        let release =
            KeyEvent::new_with_kind(KeyCode::Enter, KeyModifiers::NONE, KeyEventKind::Release);
        assert_eq!(key_event_to_action(release, false), None);
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
}
