//! Pure deterministic subsequence fuzzy matcher for command palette filtering.

use crate::schema::CommandSpec;

const BASE_MATCH_SCORE: i64 = 10;
const CONSECUTIVE_BONUS: i64 = 15;
const START_OF_TEXT_BONUS: i64 = 20;
const WORD_BOUNDARY_BONUS: i64 = 12;
const EXACT_ID_BONUS: i64 = 100;

const fn is_word_separator(character: char) -> bool {
    matches!(character, ' ' | '-' | '_' | '/')
}

fn compute_char_score(
    haystack: &[char],
    matched_index: usize,
    previous_match_index: Option<usize>,
) -> i64 {
    let mut delta = BASE_MATCH_SCORE;
    if matched_index == 0 {
        return delta + START_OF_TEXT_BONUS;
    }
    if previous_match_index == Some(matched_index - 1) {
        return delta + CONSECUTIVE_BONUS;
    }
    if is_word_separator(haystack[matched_index - 1]) {
        delta += WORD_BOUNDARY_BONUS;
    }
    if let Some(previous_index) = previous_match_index {
        let gap = i64::try_from(matched_index - previous_index - 1).unwrap_or(i64::MAX);
        delta = delta.saturating_sub(gap);
    }
    delta
}

/// Scores how well `query` matches `candidate` as a case-insensitive subsequence.
///
/// Returns `Some(score)` when matched (positive for non-blank queries, `0` for blank
/// queries), or `None` when `query` is not a subsequence of `candidate`.
#[must_use]
pub fn score_match(query: &str, candidate: &str) -> Option<i64> {
    if query.trim().is_empty() {
        return Some(0);
    }
    if candidate.is_empty() {
        return None;
    }

    let needle: Vec<char> = query.to_lowercase().chars().collect();
    let haystack: Vec<char> = candidate.to_lowercase().chars().collect();
    if needle.len() > haystack.len() {
        return None;
    }

    let mut total_score: i64 = 0;
    let mut search_start = 0;
    let mut previous_match_index = None;

    for target_char in needle {
        let matched_offset = haystack[search_start..]
            .iter()
            .position(|&candidate_char| candidate_char == target_char)?;
        let matched_index = search_start + matched_offset;
        total_score += compute_char_score(&haystack, matched_index, previous_match_index);
        previous_match_index = Some(matched_index);
        search_start = matched_index + 1;
    }

    Some(total_score.max(1))
}

fn score_command(command: &CommandSpec, normalized_query: &str) -> Option<i64> {
    let label_score = score_match(normalized_query, &command.label);
    let mut id_score = score_match(normalized_query, &command.id);
    if let Some(score) = id_score.as_mut()
        && command.id.to_lowercase() == normalized_query
    {
        *score += EXACT_ID_BONUS;
    }
    match (label_score, id_score) {
        (Some(label), Some(id)) => Some(label.max(id)),
        (Some(label), None) => Some(label),
        (None, Some(id)) => Some(id),
        (None, None) => None,
    }
}

/// Returns the indices into `commands` that match `query`, ranked best-first.
///
/// Empty or whitespace-only queries return all command indices in original order.
#[must_use]
pub fn filter_command_indices(commands: &[CommandSpec], query: &str) -> Vec<usize> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return (0..commands.len()).collect();
    }

    let normalized_query = trimmed.to_lowercase();
    let mut scored: Vec<(usize, i64)> = commands
        .iter()
        .enumerate()
        .filter_map(|(index, command)| {
            score_command(command, &normalized_query).map(|score| (index, score))
        })
        .collect();

    scored.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    scored.into_iter().map(|(index, _)| index).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_commands() -> Vec<CommandSpec> {
        vec![
            CommandSpec::new("prs", "List Open Pull Requests", "List open PRs.", vec![]),
            CommandSpec::new("checkout", "Check Out Pull Request", "Checkout PR.", vec![]),
            CommandSpec::new("threads", "List Review Threads", "List threads.", vec![]),
            CommandSpec::new("open", "Open Pull Request", "Open PR.", vec![]),
        ]
    }

    #[test]
    fn empty_and_whitespace_queries_preserve_original_order() {
        let commands = sample_commands();
        assert_eq!(filter_command_indices(&commands, ""), vec![0, 1, 2, 3]);
        assert_eq!(
            filter_command_indices(&commands, "   \t "),
            vec![0, 1, 2, 3]
        );
    }

    #[test]
    fn fuzzy_matches_label_and_id_and_prioritizes_exact_id() {
        let commands = sample_commands();
        assert_eq!(filter_command_indices(&commands, "chk"), vec![1]);
        assert_eq!(
            filter_command_indices(&commands, "LRT").first().copied(),
            Some(2)
        );

        let open_matches = filter_command_indices(&commands, "open");
        assert_eq!(open_matches.first().copied(), Some(3));
        assert_eq!(open_matches.len(), 2);
    }

    #[test]
    fn ties_preserve_original_order_and_unmatched_query_returns_empty() {
        let tied = vec![
            CommandSpec::new("a", "Alpha One", "First.", vec![]),
            CommandSpec::new("b", "Alpha Two", "Second.", vec![]),
        ];
        assert_eq!(filter_command_indices(&tied, "alpha"), vec![0, 1]);
        assert_eq!(filter_command_indices(&tied, "zzzz"), Vec::<usize>::new());
        assert_eq!(score_match("xyz", "Alpha One"), None);
    }
}
