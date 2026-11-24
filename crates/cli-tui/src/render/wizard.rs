//! Wizard step header, progress dots, option rows, text input, and footer rendering.

use crate::schema::{SelectOption, StepKind, StepSpec};
use crate::state::WizardState;

use super::text::{append_wrapped_help, append_wrapped_plain_lines, paint};
use super::{SGR_ACCENT, SGR_ERROR, SGR_HEADING, SGR_MUTED, SGR_REVERSE, SGR_VALUE, SGR_WARNING};

pub(super) fn append_wizard_header(
    lines: &mut Vec<String>,
    step: &StepSpec,
    state: &WizardState,
    total_steps: usize,
    width: usize,
    is_color_enabled: bool,
) {
    lines.push(format_wizard_title(
        state.step_index(),
        total_steps,
        &step.label,
        is_color_enabled,
    ));
    append_wrapped_plain_lines(lines, &step.help, "", width, SGR_MUTED, is_color_enabled);

    if let Some(error_message) = state.validation_error() {
        let error_text = format!("Error: {error_message}");
        append_wrapped_plain_lines(lines, &error_text, "", width, SGR_ERROR, is_color_enabled);
    }
}

fn format_wizard_title(
    step_index: usize,
    total_steps: usize,
    step_label: &str,
    is_color_enabled: bool,
) -> String {
    let step_number = step_index + 1;
    let heading = paint(
        &format!("Step {step_number} of {total_steps} · {step_label}"),
        SGR_HEADING,
        is_color_enabled,
    );
    let dots = build_progress_dots(step_index, total_steps, is_color_enabled);
    format!("{heading}  {dots}")
}

fn build_progress_dots(step_index: usize, total_steps: usize, is_color_enabled: bool) -> String {
    (0..total_steps)
        .map(|index| {
            if index <= step_index {
                paint("●", SGR_ACCENT, is_color_enabled)
            } else {
                paint("○", SGR_MUTED, is_color_enabled)
            }
        })
        .collect::<Vec<String>>()
        .join(" ")
}

pub(super) fn append_wizard_body(
    lines: &mut Vec<String>,
    step: &StepSpec,
    state: &WizardState,
    width: usize,
    is_color_enabled: bool,
) {
    match &step.kind {
        StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
            append_option_list(lines, state, width, is_color_enabled);
        }
        StepKind::Text { placeholder } => {
            lines.push(format_text_input(
                state.input_text(),
                state.cursor_char_index(),
                placeholder.as_deref(),
                is_color_enabled,
            ));
        }
    }
}

fn append_option_list(
    lines: &mut Vec<String>,
    state: &WizardState,
    width: usize,
    is_color_enabled: bool,
) {
    let options = state.loaded_options();
    if options.is_empty() {
        lines.push(paint(
            "  (no options available)",
            SGR_MUTED,
            is_color_enabled,
        ));
        return;
    }
    let clamped_selected = state.selected_option_index().min(options.len() - 1);
    for (index, option) in options.iter().enumerate() {
        let is_selected = index == clamped_selected;
        lines.push(format_option_row(option, is_selected, is_color_enabled));
        if is_selected
            && let Some(help_text) = option.help.as_deref()
            && !help_text.trim().is_empty()
        {
            append_wrapped_help(lines, help_text, width, is_color_enabled);
        }
    }
}

fn format_option_row(option: &SelectOption, is_selected: bool, is_color_enabled: bool) -> String {
    let primary = if is_selected {
        paint(&format!("▸ {}", option.label), SGR_ACCENT, is_color_enabled)
    } else {
        format!("  {}", option.label)
    };
    match option.badge.as_deref() {
        Some(badge) => {
            let badge_tag = paint(&format!("[{badge}]"), SGR_WARNING, is_color_enabled);
            format!("{primary}  {badge_tag}")
        }
        None => primary,
    }
}

fn format_text_input(
    input_text: &str,
    cursor_char_index: usize,
    placeholder: Option<&str>,
    is_color_enabled: bool,
) -> String {
    let prompt_prefix = paint("> ", SGR_ACCENT, is_color_enabled);
    if input_text.is_empty() {
        return format_empty_text_input(&prompt_prefix, placeholder, is_color_enabled);
    }
    if !is_color_enabled {
        return format!("{prompt_prefix}{input_text}");
    }
    format_colored_text_input(&prompt_prefix, input_text, cursor_char_index)
}

fn format_empty_text_input(
    prompt_prefix: &str,
    placeholder: Option<&str>,
    is_color_enabled: bool,
) -> String {
    let cursor_block = if is_color_enabled {
        paint(" ", SGR_REVERSE, true)
    } else {
        String::new()
    };
    match placeholder {
        Some(hint) if !hint.trim().is_empty() => {
            let styled_hint = if is_color_enabled {
                paint(hint, SGR_MUTED, true)
            } else {
                format!("({hint})")
            };
            format!("{prompt_prefix}{cursor_block}{styled_hint}")
        }
        _ => format!("{prompt_prefix}{cursor_block}"),
    }
}

fn format_colored_text_input(
    prompt_prefix: &str,
    input_text: &str,
    cursor_char_index: usize,
) -> String {
    let chars: Vec<char> = input_text.chars().collect();
    let clamped_cursor = cursor_char_index.min(chars.len());
    let before: String = chars[..clamped_cursor].iter().collect();
    let (cursor_cell, after) = if clamped_cursor < chars.len() {
        let current_char = chars[clamped_cursor].to_string();
        let tail: String = chars[clamped_cursor + 1..].iter().collect();
        (paint(&current_char, SGR_REVERSE, true), tail)
    } else {
        (paint(" ", SGR_REVERSE, true), String::new())
    };
    format!(
        "{prompt_prefix}{}{cursor_cell}{}",
        paint(&before, SGR_VALUE, true),
        paint(&after, SGR_VALUE, true)
    )
}

pub(super) fn format_wizard_footer(
    step: &StepSpec,
    step_index: usize,
    total_steps: usize,
    can_return_to_palette: bool,
    is_color_enabled: bool,
) -> String {
    let is_last_step = step_index + 1 >= total_steps;
    let is_first_step = step_index == 0;
    let footer_text = match step.kind {
        StepKind::Text { .. } => {
            let confirm = if is_last_step {
                "[Enter/Tab] run"
            } else {
                "[Enter/Tab] next"
            };
            back_hint(is_first_step, can_return_to_palette, "[S-Tab]").map_or_else(
                || format!("{confirm}  [Esc] cancel"),
                |back| format!("{confirm}  {back}  [Esc] cancel"),
            )
        }
        StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
            let confirm = if is_last_step {
                "[Enter/l] run"
            } else {
                "[Enter/l] next"
            };
            back_hint(is_first_step, can_return_to_palette, "[h]").map_or_else(
                || format!("[j/k] move  {confirm}  [q/Esc] close"),
                |back| format!("[j/k] move  {back}  {confirm}  [q/Esc] close"),
            )
        }
    };
    paint(&footer_text, SGR_MUTED, is_color_enabled)
}

fn back_hint(is_first_step: bool, can_return_to_palette: bool, key: &str) -> Option<String> {
    if is_first_step && can_return_to_palette {
        Some(format!("{key} palette"))
    } else if !is_first_step {
        Some(format!("{key} back"))
    } else {
        None
    }
}
