//! Text wrapping and ANSI color styling helpers for frame rendering.

use super::{HELP_INDENT, SGR_MUTED};

pub(super) fn append_wrapped_help(
    lines: &mut Vec<String>,
    help_text: &str,
    width: usize,
    is_color_enabled: bool,
) {
    append_wrapped_plain_lines(
        lines,
        help_text,
        HELP_INDENT,
        width,
        SGR_MUTED,
        is_color_enabled,
    );
}

pub(super) fn append_wrapped_plain_lines(
    lines: &mut Vec<String>,
    text: &str,
    indent: &str,
    width: usize,
    sgr_code: &str,
    is_color_enabled: bool,
) {
    let indent_width = indent.chars().count();
    let effective_indent = if indent_width < width { indent } else { "" };
    let available_width = width
        .saturating_sub(effective_indent.chars().count())
        .max(1);
    for wrapped_line in wrap_text(text, available_width) {
        lines.push(format!(
            "{effective_indent}{}",
            paint(&wrapped_line, sgr_code, is_color_enabled)
        ));
    }
}

pub(super) fn wrap_text(text: &str, max_columns: usize) -> Vec<String> {
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
    if !current_line.is_empty() || wrapped_lines.is_empty() {
        wrapped_lines.push(current_line);
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
    let word_len = word.chars().count();
    if word_len <= limit {
        current_line.push_str(word);
        *current_len = word_len;
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

pub(super) fn paint(text: &str, sgr_code: &str, is_color_enabled: bool) -> String {
    if is_color_enabled {
        format!("\x1b[{sgr_code}m{text}\x1b[0m")
    } else {
        text.to_owned()
    }
}
