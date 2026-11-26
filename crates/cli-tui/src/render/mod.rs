//! Pure string rendering for the command palette and step-by-step wizard.

mod text;
mod wizard;

#[cfg(test)]
mod tests;

use crate::schema::{CommandSpec, get_active_steps_from_command};
use crate::state::{PaletteState, WizardState};

use self::text::{append_wrapped_help, paint};
use self::wizard::{
    append_wizard_body, append_wizard_header, format_text_input, format_wizard_footer,
};

pub(super) const SGR_HEADING: &str = "1;95";
pub(super) const SGR_ACCENT: &str = "1;96";
pub(super) const SGR_VALUE: &str = "97";
pub(super) const SGR_MUTED: &str = "90";
pub(super) const SGR_WARNING: &str = "93";
pub(super) const SGR_ERROR: &str = "91";
pub(super) const SGR_REVERSE: &str = "7";
pub(super) const HELP_INDENT: &str = "    ";
const PALETTE_PLACEHOLDER: &str = "Type to filter commands...";
const PALETTE_FOOTER: &str =
    "[type] filter  [Ctrl+j/k] move  [Ctrl+u] clear  [Enter] select  [Esc] close";

/// Renders the command palette frame as a `\n`-delimited string.
///
/// When `is_color_enabled` is `false`, zero ANSI escape sequences (`\x1b[`) are emitted.
#[must_use]
pub fn render_palette(
    title: &str,
    commands: &[CommandSpec],
    state: &PaletteState,
    width: usize,
    is_color_enabled: bool,
) -> String {
    let mut lines = vec![
        paint(title, SGR_HEADING, is_color_enabled),
        format_text_input(
            state.query(),
            state.cursor_char_index(),
            Some(PALETTE_PLACEHOLDER),
            is_color_enabled,
        ),
        String::new(),
    ];

    let filtered_indices = state.filtered_command_indices(commands);
    if filtered_indices.is_empty() {
        let empty_label = if !commands.is_empty() && !state.query().trim().is_empty() {
            "  (no matching commands)"
        } else {
            "  (no commands available)"
        };
        lines.push(paint(empty_label, SGR_MUTED, is_color_enabled));
    } else {
        let clamped_selected = state.selected_index().min(filtered_indices.len() - 1);
        for (visible_index, command_index) in filtered_indices.into_iter().enumerate() {
            let command = &commands[command_index];
            let is_selected = visible_index == clamped_selected;
            lines.push(format_palette_row(command, is_selected, is_color_enabled));
            if is_selected {
                append_wrapped_help(&mut lines, &command.help, width, is_color_enabled);
            }
        }
    }

    lines.push(String::new());
    lines.push(paint(PALETTE_FOOTER, SGR_MUTED, is_color_enabled));
    lines.join("\n")
}

/// Renders the active step of a command wizard as a `\n`-delimited string.
///
/// When `is_color_enabled` is `false`, zero ANSI escape sequences (`\x1b[`) are emitted.
#[must_use]
pub fn render_wizard(
    command: &CommandSpec,
    state: &WizardState,
    width: usize,
    is_color_enabled: bool,
) -> String {
    let active_steps = get_active_steps_from_command(command, state.answers());
    let Some(current_step) = active_steps.get(state.step_index()).copied() else {
        return paint(&command.label, SGR_HEADING, is_color_enabled);
    };

    let mut lines = Vec::new();
    append_wizard_header(
        &mut lines,
        current_step,
        state,
        active_steps.len(),
        width,
        is_color_enabled,
    );
    lines.push(String::new());
    append_wizard_body(&mut lines, current_step, state, width, is_color_enabled);
    lines.push(String::new());
    lines.push(format_wizard_footer(
        current_step,
        state.step_index(),
        active_steps.len(),
        state.can_return_to_palette(),
        is_color_enabled,
    ));
    lines.join("\n")
}

fn format_palette_row(command: &CommandSpec, is_selected: bool, is_color_enabled: bool) -> String {
    let id_tag = paint(&format!("[{}]", command.id), SGR_MUTED, is_color_enabled);
    if is_selected {
        let label = paint(
            &format!("▸ {}", command.label),
            SGR_ACCENT,
            is_color_enabled,
        );
        format!("{label}  {id_tag}")
    } else {
        format!("  {}  {id_tag}", command.label)
    }
}
