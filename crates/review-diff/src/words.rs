//! The words that changed between two versions of one line, as byte ranges.

use std::ops::Range;

use review_model::WordRange;
use similar::{Algorithm, DiffTag, capture_diff_slices, diff_ratio};

/// Below this share of unchanged tokens, two lines count as replaced rather
/// than edited and get no word highlights: marking nearly every word says
/// less than marking none.
const MIN_SIMILARITY: f32 = 0.5;

/// The changed words of `old` and of `new`, or `None` when the two lines are
/// too different for word highlights to help.
#[must_use]
pub fn create_word_ranges_from_lines(
    old: &str,
    new: &str,
) -> Option<(Vec<WordRange>, Vec<WordRange>)> {
    let old_tokens = text_to_tokens(old);
    let new_tokens = text_to_tokens(new);
    let old_words: Vec<&str> = old_tokens.iter().map(|token| token.1).collect();
    let new_words: Vec<&str> = new_tokens.iter().map(|token| token.1).collect();
    let token_edits = capture_diff_slices(Algorithm::Myers, &old_words, &new_words);
    if diff_ratio(&token_edits, old_words.len(), new_words.len()) < MIN_SIMILARITY {
        return None;
    }
    let mut old_ranges = Vec::new();
    let mut new_ranges = Vec::new();
    for token_edit in &token_edits {
        let (tag, old_span, new_span) = token_edit.as_tag_tuple();
        if tag != DiffTag::Equal {
            push_span(&mut old_ranges, &old_tokens, old_span);
            push_span(&mut new_ranges, &new_tokens, new_span);
        }
    }
    Some((old_ranges, new_ranges))
}

/// Adds the bytes `tokens[span]` cover to `ranges`, unless the span is empty.
fn push_span(ranges: &mut Vec<WordRange>, tokens: &[(usize, &str)], span: Range<usize>) {
    if span.is_empty() {
        return;
    }
    let (start, _) = tokens[span.start];
    let (last_token_start, last_token) = tokens[span.end - 1];
    ranges.push(WordRange {
        start,
        end: last_token_start + last_token.len(),
    });
}

/// What a character is, for splitting a line into tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CharClass {
    Word,
    Space,
    Other,
}

impl CharClass {
    fn from_char(character: char) -> Self {
        if character.is_alphanumeric() || character == '_' {
            Self::Word
        } else if character.is_whitespace() {
            Self::Space
        } else {
            Self::Other
        }
    }
}

/// `text` as tokens with their byte offsets: a run of word characters, a run
/// of whitespace, or any other single character.
fn text_to_tokens(text: &str) -> Vec<(usize, &str)> {
    let mut tokens = Vec::new();
    let mut start = 0;
    let mut previous_class: Option<CharClass> = None;
    for (index, character) in text.char_indices() {
        let class = CharClass::from_char(character);
        if previous_class
            .is_some_and(|previous_class| previous_class != class || class == CharClass::Other)
        {
            tokens.push((start, &text[start..index]));
            start = index;
        }
        previous_class = Some(class);
    }
    if start < text.len() {
        tokens.push((start, &text[start..]));
    }
    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_word_ranges_from_pairs(pairs: &[(usize, usize)]) -> Vec<WordRange> {
        pairs
            .iter()
            .map(|&(start, end)| WordRange { start, end })
            .collect()
    }

    #[test]
    fn a_changed_number_highlights_only_the_number() {
        let (old, new) = create_word_ranges_from_lines("let x = 1;", "let x = 2;").unwrap();
        assert_eq!(old, create_word_ranges_from_pairs(&[(8, 9)]));
        assert_eq!(new, create_word_ranges_from_pairs(&[(8, 9)]));
    }

    #[test]
    fn punctuation_splits_words() {
        let (old, new) =
            create_word_ranges_from_lines("call(alpha, beta)", "call(alpha, gamma)").unwrap();
        assert_eq!(old, create_word_ranges_from_pairs(&[(12, 16)]));
        assert_eq!(new, create_word_ranges_from_pairs(&[(12, 17)]));
    }

    #[test]
    fn an_insertion_highlights_only_the_new_side() {
        let (old, new) = create_word_ranges_from_lines("a + b", "a + b + c").unwrap();
        assert_eq!(old, Vec::new());
        assert_eq!(new, create_word_ranges_from_pairs(&[(5, 9)]));
    }

    #[test]
    fn lines_with_little_in_common_get_no_word_highlights() {
        assert_eq!(
            create_word_ranges_from_lines("fn alpha() {}", "struct Beta;"),
            None
        );
    }

    #[test]
    fn offsets_are_bytes_in_utf8_text() {
        let (old, new) = create_word_ranges_from_lines("café = 1", "café = 2").unwrap();
        assert_eq!(old, create_word_ranges_from_pairs(&[(8, 9)]));
        assert_eq!(new, create_word_ranges_from_pairs(&[(8, 9)]));
    }

    #[test]
    fn identical_lines_have_no_changed_words() {
        assert_eq!(
            create_word_ranges_from_lines("same", "same"),
            Some((vec![], vec![]))
        );
    }

    #[test]
    fn tokens_group_words_and_spaces_but_not_punctuation() {
        let texts: Vec<&str> = text_to_tokens("a_b  (c)")
            .into_iter()
            .map(|token| token.1)
            .collect();
        assert_eq!(texts, ["a_b", "  ", "(", "c", ")"]);
    }
}
