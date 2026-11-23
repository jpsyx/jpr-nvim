//! Pure string rendering for the command palette and step-by-step wizard.

use crate::schema::{CommandSpec, SelectOption, StepKind, StepSpec, resolve_active_steps};
use crate::state::{PaletteState, WizardState};

const SGR_HEADING: &str = "1;95";
const SGR_ACCENT: &str = "1;96";
const SGR_VALUE: &str = "97";
const SGR_MUTED: &str = "90";
const SGR_WARNING: &str = "93";
const SGR_ERROR: &str = "91";
const SGR_REVERSE: &str = "7";
const HELP_INDENT: &str = "    ";
const MIN_WRAP_WIDTH: usize = 12;

/// Renders the command palette frame as a `\n`-delimited string.
///
/// When `use_color` is `false`, zero ANSI escape sequences (`\x1b[`) are emitted.
#[must_use]
pub fn render_palette(
    title: &str,
    commands: &[CommandSpec],
    state: &PaletteState,
    width: usize,
    use_color: bool,
) -> String {
    let mut lines = Vec::new();
    lines.push(paint(title, SGR_HEADING, use_color));
    lines.push(String::new());

    for (index, command) in commands.iter().enumerate() {
        let is_selected = index == state.selected_index();
        lines.push(format_palette_row(command, is_selected, use_color));
        if is_selected {
            append_wrapped_help(&mut lines, &command.help, width, use_color);
        }
    }

    lines.push(String::new());
    lines.push(paint(
        "[j/k] move  [Enter/l] select  [q/Esc] close",
        SGR_MUTED,
        use_color,
    ));
    lines.join("\n")
}

/// Renders the active step of a command wizard as a `\n`-delimited string.
///
/// When `use_color` is `false`, zero ANSI escape sequences (`\x1b[`) are emitted.
#[must_use]
pub fn render_wizard(
    command: &CommandSpec,
    state: &WizardState,
    width: usize,
    use_color: bool,
) -> String {
    let active_steps = resolve_active_steps(command, state.answers());
    let Some(current_step) = active_steps.get(state.step_index()).copied() else {
        return paint(&command.label, SGR_HEADING, use_color);
    };

    let mut lines = Vec::new();
    lines.push(format_wizard_header(
        state.step_index(),
        active_steps.len(),
        &current_step.label,
        use_color,
    ));
    append_wrapped_plain_lines(
        &mut lines,
        &current_step.help,
        "",
        width,
        SGR_MUTED,
        use_color,
    );

    if let Some(error_message) = state.validation_error() {
        append_wrapped_plain_lines(
            &mut lines,
            &format!("Error: {error_message}"),
            "",
            width,
            SGR_ERROR,
            use_color,
        );
    }

    lines.push(String::new());
    append_wizard_body(&mut lines, current_step, state, width, use_color);
    lines.push(String::new());
    lines.push(format_wizard_footer(
        current_step,
        state.step_index(),
        active_steps.len(),
        state.can_return_to_palette(),
        use_color,
    ));
    lines.join("\n")
}

fn format_palette_row(command: &CommandSpec, is_selected: bool, use_color: bool) -> String {
    let id_tag = paint(&format!("[{}]", command.id), SGR_MUTED, use_color);
    if is_selected {
        let label = paint(&format!("▸ {}", command.label), SGR_ACCENT, use_color);
        format!("{label}  {id_tag}")
    } else {
        format!("  {}  {id_tag}", command.label)
    }
}

fn format_wizard_header(
    step_index: usize,
    total_steps: usize,
    step_label: &str,
    use_color: bool,
) -> String {
    let step_number = step_index + 1;
    let heading = paint(
        &format!("Step {step_number} of {total_steps} · {step_label}"),
        SGR_HEADING,
        use_color,
    );
    let dots = build_progress_dots(step_index, total_steps, use_color);
    format!("{heading}  {dots}")
}

fn build_progress_dots(step_index: usize, total_steps: usize, use_color: bool) -> String {
    let mut parts = Vec::with_capacity(total_steps);
    for index in 0..total_steps {
        if index <= step_index {
            parts.push(paint("●", SGR_ACCENT, use_color));
        } else {
            parts.push(paint("○", SGR_MUTED, use_color));
        }
    }
    parts.join(" ")
}

fn append_wizard_body(
    lines: &mut Vec<String>,
    step: &StepSpec,
    state: &WizardState,
    width: usize,
    use_color: bool,
) {
    match &step.kind {
        StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
            append_option_list(lines, state, width, use_color);
        }
        StepKind::Text { placeholder } => {
            lines.push(format_text_input(
                state.input_text(),
                state.cursor_char_index(),
                placeholder.as_deref(),
                use_color,
            ));
        }
    }
}

fn append_option_list(lines: &mut Vec<String>, state: &WizardState, width: usize, use_color: bool) {
    let options = state.loaded_options();
    if options.is_empty() {
        lines.push(paint("  (no options available)", SGR_MUTED, use_color));
        return;
    }
    for (index, option) in options.iter().enumerate() {
        let is_selected = index == state.selected_option_index();
        lines.push(format_option_row(option, is_selected, use_color));
        if is_selected
            && let Some(help_text) = option.help.as_deref()
            && !help_text.trim().is_empty()
        {
            append_wrapped_help(lines, help_text, width, use_color);
        }
    }
}

fn format_option_row(option: &SelectOption, is_selected: bool, use_color: bool) -> String {
    let primary = if is_selected {
        paint(&format!("▸ {}", option.label), SGR_ACCENT, use_color)
    } else {
        format!("  {}", option.label)
    };
    match option.badge.as_deref() {
        Some(badge) => {
            let badge_tag = paint(&format!("[{badge}]"), SGR_WARNING, use_color);
            format!("{primary}  {badge_tag}")
        }
        None => primary,
    }
}

fn format_text_input(
    input_text: &str,
    cursor_char_index: usize,
    placeholder: Option<&str>,
    use_color: bool,
) -> String {
    let prompt_prefix = paint("> ", SGR_ACCENT, use_color);
    if input_text.is_empty() {
        return format_empty_text_input(&prompt_prefix, placeholder, use_color);
    }
    if !use_color {
        return format!("{prompt_prefix}{input_text}");
    }
    format_colored_text_input(&prompt_prefix, input_text, cursor_char_index)
}

fn format_empty_text_input(
    prompt_prefix: &str,
    placeholder: Option<&str>,
    use_color: bool,
) -> String {
    let cursor_block = if use_color {
        paint(" ", SGR_REVERSE, true)
    } else {
        String::new()
    };
    match placeholder {
        Some(hint) if !hint.trim().is_empty() => {
            let styled_hint = if use_color {
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

fn format_wizard_footer(
    step: &StepSpec,
    step_index: usize,
    total_steps: usize,
    can_return_to_palette: bool,
    use_color: bool,
) -> String {
    let is_last_step = step_index + 1 >= total_steps;
    let is_first_step = step_index == 0;
    let footer_text = match step.kind {
        StepKind::Text { .. } => {
            build_text_footer(is_first_step, is_last_step, can_return_to_palette)
        }
        StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
            build_menu_footer(is_first_step, is_last_step, can_return_to_palette)
        }
    };
    paint(&footer_text, SGR_MUTED, use_color)
}

fn build_text_footer(
    is_first_step: bool,
    is_last_step: bool,
    can_return_to_palette: bool,
) -> String {
    let confirm_hint = if is_last_step {
        "[Enter/Tab] run"
    } else {
        "[Enter/Tab] next"
    };
    let back_hint = if is_first_step && can_return_to_palette {
        Some("[S-Tab] palette")
    } else if !is_first_step {
        Some("[S-Tab] back")
    } else {
        None
    };
    back_hint.map_or_else(
        || format!("{confirm_hint}  [Esc] cancel"),
        |hint| format!("{confirm_hint}  {hint}  [Esc] cancel"),
    )
}

fn build_menu_footer(
    is_first_step: bool,
    is_last_step: bool,
    can_return_to_palette: bool,
) -> String {
    let confirm_hint = if is_last_step {
        "[Enter/l] run"
    } else {
        "[Enter/l] next"
    };
    let back_hint = if is_first_step && can_return_to_palette {
        Some("[h] palette")
    } else if !is_first_step {
        Some("[h] back")
    } else {
        None
    };
    back_hint.map_or_else(
        || format!("[j/k] move  {confirm_hint}  [q/Esc] close"),
        |hint| format!("[j/k] move  {hint}  {confirm_hint}  [q/Esc] close"),
    )
}

fn append_wrapped_help(lines: &mut Vec<String>, help_text: &str, width: usize, use_color: bool) {
    append_wrapped_plain_lines(lines, help_text, HELP_INDENT, width, SGR_MUTED, use_color);
}

fn append_wrapped_plain_lines(
    lines: &mut Vec<String>,
    text: &str,
    indent: &str,
    width: usize,
    sgr_code: &str,
    use_color: bool,
) {
    let available_width = width
        .saturating_sub(indent.chars().count())
        .max(MIN_WRAP_WIDTH);
    for wrapped_line in wrap_text(text, available_width) {
        lines.push(format!(
            "{indent}{}",
            paint(&wrapped_line, sgr_code, use_color)
        ));
    }
}

fn wrap_text(text: &str, max_columns: usize) -> Vec<String> {
    let limit = max_columns.max(1);
    let mut wrapped_lines = Vec::new();
    let mut current_line = String::new();
    let mut current_len = 0;

    for word in text.split_whitespace() {
        let word_len = word.chars().count();
        if current_len == 0 {
            push_word_or_chunks(
                &mut wrapped_lines,
                &mut current_line,
                &mut current_len,
                word,
                limit,
            );
        } else if current_len + 1 + word_len <= limit {
            current_line.push(' ');
            current_line.push_str(word);
            current_len += 1 + word_len;
        } else {
            wrapped_lines.push(std::mem::take(&mut current_line));
            current_len = 0;
            push_word_or_chunks(
                &mut wrapped_lines,
                &mut current_line,
                &mut current_len,
                word,
                limit,
            );
        }
    }
    if !current_line.is_empty() {
        wrapped_lines.push(current_line);
    }
    if wrapped_lines.is_empty() {
        wrapped_lines.push(String::new());
    }
    wrapped_lines
}

fn push_word_or_chunks(
    wrapped_lines: &mut Vec<String>,
    current_line: &mut String,
    current_len: &mut usize,
    word: &str,
    limit: usize,
) {
    if word.chars().count() <= limit {
        current_line.push_str(word);
        *current_len = word.chars().count();
        return;
    }
    let mut chunk = String::new();
    let mut chunk_len = 0;
    for character in word.chars() {
        if chunk_len == limit {
            wrapped_lines.push(std::mem::take(&mut chunk));
            chunk_len = 0;
        }
        chunk.push(character);
        chunk_len += 1;
    }
    *current_line = chunk;
    *current_len = chunk_len;
}

fn paint(text: &str, sgr_code: &str, use_color: bool) -> String {
    if use_color {
        format!("\x1b[{sgr_code}m{text}\x1b[0m")
    } else {
        text.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{Answers, SelectOption, StepKind, StepSpec};
    use crate::state::KeyAction;

    fn sample_commands() -> Vec<CommandSpec> {
        vec![
            CommandSpec::new(
                "prs",
                "List Open Pull Requests",
                "Fetches open pull requests in the current or specified repository.",
                vec![],
            ),
            CommandSpec::new(
                "checkout",
                "Check Out Pull Request",
                "Checks out a pull request branch into a local worktree.",
                vec![],
            ),
        ]
    }

    #[test]
    fn render_palette_shows_labels_ids_and_hover_only_help() {
        let commands = sample_commands();
        let mut state = PaletteState::new();

        let first_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
        assert!(first_frame.contains("▸ List Open Pull Requests  [prs]"));
        assert!(first_frame.contains("  Check Out Pull Request  [checkout]"));
        assert!(first_frame.contains("Fetches open pull requests"));
        assert!(!first_frame.contains("Checks out a pull request branch"));
        assert!(!first_frame.contains("\x1b["));

        let _ = state.handle_key(KeyAction::Down, commands.len());
        let second_frame = render_palette("jpr-review Commands", &commands, &state, 80, false);
        assert!(second_frame.contains("  List Open Pull Requests  [prs]"));
        assert!(second_frame.contains("▸ Check Out Pull Request  [checkout]"));
        assert!(!second_frame.contains("Fetches open pull requests"));
        assert!(second_frame.contains("Checks out a pull request branch"));
        assert!(second_frame.contains("[j/k] move  [Enter/l] select  [q/Esc] close"));
    }

    #[test]
    fn render_palette_emits_ansi_dim_when_color_enabled() {
        let commands = sample_commands();
        let state = PaletteState::new();
        let colored = render_palette("jpr-review Commands", &commands, &state, 80, true);
        assert!(colored.contains("\x1b[90m"));
        assert!(colored.contains("[prs]"));
    }

    #[test]
    fn render_wizard_shows_progress_hover_help_prefill_and_errors() {
        let command = CommandSpec::new(
            "threads",
            "List Review Threads",
            "Lists review threads.",
            vec![
                StepSpec::new(
                    "target_mode",
                    "Target Source",
                    "Choose how to locate the review.",
                    StepKind::Select(vec![
                        SelectOption::new("socket", "Live Socket")
                            .with_badge("fast")
                            .with_help("Connect directly to a running daemon."),
                        SelectOption::new("pr", "Pull Request")
                            .with_help("Read saved review state from disk."),
                    ]),
                ),
                StepSpec::new(
                    "pr",
                    "Pull Request Number",
                    "Enter the numeric PR ID.",
                    StepKind::Text {
                        placeholder: Some("42".to_owned()),
                    },
                )
                .with_default("99")
                .with_validate(|value, _| {
                    if value.trim().parse::<u64>().is_ok() {
                        Ok(())
                    } else {
                        Err("Must be a number.".to_owned())
                    }
                }),
                StepSpec::new(
                    "repo",
                    "Repository",
                    "Owner and repo slug.",
                    StepKind::Text {
                        placeholder: Some("octo/widgets".to_owned()),
                    },
                ),
            ],
        );

        let mut wizard = WizardState::new(&command, Answers::new(), true);
        let step_one = render_wizard(&command, &wizard, 80, false);
        assert!(step_one.contains("Step 1 of 3 · Target Source"));
        assert!(step_one.contains("Choose how to locate the review."));
        assert!(step_one.contains("▸ Live Socket  [fast]"));
        assert!(step_one.contains("Connect directly to a running daemon."));
        assert!(!step_one.contains("Read saved review state from disk."));
        assert!(step_one.contains("[h] palette"));
        assert!(!step_one.contains("\x1b["));

        // Advance to step 2 (Text step with default "99").
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        let step_two = render_wizard(&command, &wizard, 80, false);
        assert!(step_two.contains("Step 2 of 3 · Pull Request Number"));
        assert!(step_two.contains("> 99"));
        assert!(step_two.contains("[Enter/Tab] next"));
        assert!(step_two.contains("[S-Tab] back"));
        assert!(!step_two.contains("\x1b["));

        // Enter invalid text and trigger validation error.
        let _ = wizard.handle_key(&command, KeyAction::Char('a'));
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        let step_two_error = render_wizard(&command, &wizard, 80, true);
        assert!(step_two_error.contains("\x1b[91m"));
        assert!(step_two_error.contains("Must be a number."));

        // Fix input and advance to final step (empty text with placeholder).
        let _ = wizard.handle_key(&command, KeyAction::Backspace);
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        let step_three = render_wizard(&command, &wizard, 80, false);
        assert!(step_three.contains("Step 3 of 3 · Repository"));
        assert!(step_three.contains("> (octo/widgets)"));
        assert!(step_three.contains("[Enter/Tab] run"));
        assert!(!step_three.contains("\x1b["));
    }

    #[test]
    fn render_palette_wraps_long_help_to_width_with_indent() {
        let commands = vec![CommandSpec::new(
            "checkout",
            "Check Out Pull Request",
            "Checks out a pull request branch into a local git worktree for side-by-side review.",
            vec![],
        )];
        let state = PaletteState::new();
        let frame = render_palette("Commands", &commands, &state, 36, false);
        let help_lines: Vec<&str> = frame
            .lines()
            .filter(|line| line.starts_with("    "))
            .collect();
        assert!(help_lines.len() >= 2);
        for line in help_lines {
            assert!(
                line.chars().count() <= 36,
                "wrapped help line exceeded width: {line:?}"
            );
        }
    }
}
