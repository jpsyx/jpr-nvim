//! Terminal runner wiring raw-mode input and stderr rendering to the pure TUI engine.

mod keys;
mod terminal;

#[cfg(test)]
mod tests;

use std::io::IsTerminal;

use anyhow::{Context, Result, anyhow};
use crossterm::event::{self, Event};

use crate::render::{render_palette, render_wizard};
use crate::schema::{Answers, CommandSpec, prune_inactive_answers, validate_command_specs};
use crate::state::{
    PaletteAction, PaletteState, WizardOutcome, WizardState, has_unanswered_active_step,
};

use self::keys::{KeyMode, key_event_to_action};
use self::terminal::{RawModeGuard, should_use_color, terminal_width};

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

/// Prompts the user to pick a command and complete its interactive steps on stderr.
///
/// Returns [`PaletteOutcome::Completed`] with the selected command ID and its
/// pruned answers, or [`PaletteOutcome::Cancelled`] when closed without running
/// a command.
pub fn run_palette(title: &str, commands: &[CommandSpec]) -> Result<PaletteOutcome> {
    validate_command_specs(commands)
        .map_err(|message| anyhow!("invalid command schema: {message}"))?;
    if commands.is_empty() {
        return Ok(PaletteOutcome::Cancelled);
    }

    let mut terminal_guard = RawModeGuard::new()?;
    let mut palette_state = PaletteState::new();
    let is_color_enabled = should_use_color();

    loop {
        let selected_index = match run_palette_loop(
            &mut terminal_guard,
            title,
            commands,
            &mut palette_state,
            is_color_enabled,
        )? {
            PaletteAction::Selected(index) => index,
            PaletteAction::Cancelled => return Ok(PaletteOutcome::Cancelled),
            PaletteAction::Continue => continue,
        };

        if let Some(outcome) = run_selected_command(
            &mut terminal_guard,
            &commands[selected_index],
            is_color_enabled,
        )? {
            return Ok(outcome);
        }
        palette_state.clear_query();
    }
}

fn run_selected_command(
    terminal_guard: &mut RawModeGuard,
    command: &CommandSpec,
    is_color_enabled: bool,
) -> Result<Option<PaletteOutcome>> {
    let mut wizard_state = WizardState::new(command, Answers::new(), true);
    if let Some(answers) = wizard_state.immediate_completion(command) {
        return Ok(Some(PaletteOutcome::Completed {
            command_id: command.id.clone(),
            answers,
        }));
    }

    match run_wizard_loop(terminal_guard, command, &mut wizard_state, is_color_enabled)? {
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
    let is_color_enabled = should_use_color();
    match run_wizard_loop(
        &mut terminal_guard,
        command,
        &mut wizard_state,
        is_color_enabled,
    )? {
        WizardOutcome::Completed(answers) => Ok(CommandOutcome::Completed(answers)),
        WizardOutcome::Cancelled | WizardOutcome::BackToPalette | WizardOutcome::Continue => {
            Ok(CommandOutcome::Cancelled)
        }
    }
}

fn run_palette_loop(
    terminal_guard: &mut RawModeGuard,
    title: &str,
    commands: &[CommandSpec],
    palette_state: &mut PaletteState,
    is_color_enabled: bool,
) -> Result<PaletteAction> {
    loop {
        let width = terminal_width();
        let frame = render_palette(title, commands, palette_state, width, is_color_enabled);
        terminal_guard.render_frame(&frame, width)?;

        if let Event::Key(key_event) = event::read().context("reading terminal input event")? {
            let Some(action) = key_event_to_action(key_event, KeyMode::Palette) else {
                continue;
            };
            match palette_state.handle_key(action, commands) {
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
    is_color_enabled: bool,
) -> Result<WizardOutcome> {
    loop {
        let width = terminal_width();
        let frame = render_wizard(command, wizard_state, width, is_color_enabled);
        terminal_guard.render_frame(&frame, width)?;

        if let Event::Key(key_event) = event::read().context("reading terminal input event")? {
            let mode = if wizard_state.is_text_step(command) {
                KeyMode::Text
            } else {
                KeyMode::Menu
            };
            let Some(action) = key_event_to_action(key_event, mode) else {
                continue;
            };
            match wizard_state.handle_key(command, action) {
                WizardOutcome::Continue => {}
                outcome => return Ok(outcome),
            }
        }
    }
}
