//! The viewed rules: what a mark means, and how a queued mark wins over a
//! pull.

use std::collections::BTreeMap;

use review_model::{ChangedFile, ViewedState};

/// The state a file is in once marked viewed (`true`) or unviewed (`false`).
#[must_use]
pub const fn viewed_flag_to_state(viewed: bool) -> ViewedState {
    if viewed {
        ViewedState::Viewed
    } else {
        ViewedState::Unviewed
    }
}

/// Applies the marks still queued for the forge to `files`, whether just
/// pulled from the forge or read back from the store, so neither a pull
/// taken before a mark lands nor a file saved behind the queue undoes it.
pub fn apply_queued(files: &mut [ChangedFile], queued: &BTreeMap<String, bool>) {
    for file in files {
        if let Some(viewed) = queued.get(&file.path) {
            file.viewed = viewed_flag_to_state(*viewed);
        }
    }
}

/// Drops the queued marks for paths `files` no longer has. After a force-push
/// or a rename the forge refuses such a mark every time, and since sending
/// stops at the first refusal, it would hold up every mark queued after it.
pub fn drop_stale_marks(queued: &mut BTreeMap<String, bool>, files: &[ChangedFile]) {
    queued.retain(|path, _| files.iter().any(|file| file.path == *path));
}

/// Whether `path` lies inside directory `dir` (recursively across nested
/// subdirectories), ignoring trailing slashes on `dir` and preventing prefix
/// collisions like `src_extra/` matching `src`.
#[must_use]
pub fn is_path_in_directory(path: &str, dir: &str) -> bool {
    let normalized = dir.trim_end_matches('/');
    if normalized.is_empty() {
        return false;
    }
    path.strip_prefix(normalized)
        .is_some_and(|rest| rest.starts_with('/'))
}

/// Collects changed file paths under `dir` and their target viewed flag.
///
/// Returns `None` when no file lies under `dir`, `Some((paths, true))` when
/// any matching file is not `Viewed`, and `Some((paths, false))` when all are
/// already `Viewed`.
#[must_use]
pub fn collect_directory_toggle_paths(
    files: &[ChangedFile],
    dir: &str,
) -> Option<(Vec<String>, bool)> {
    let mut paths = Vec::new();
    let mut has_unviewed = false;
    for file in files {
        if is_path_in_directory(&file.path, dir) {
            paths.push(file.path.clone());
            if file.viewed != ViewedState::Viewed {
                has_unviewed = true;
            }
        }
    }
    if paths.is_empty() {
        None
    } else {
        Some((paths, has_unviewed))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use review_model::ViewedState;

    use super::*;
    use crate::fakes::changed_file;

    #[test]
    fn a_mark_is_viewed_or_unviewed() {
        assert_eq!(viewed_flag_to_state(true), ViewedState::Viewed);
        assert_eq!(viewed_flag_to_state(false), ViewedState::Unviewed);
    }

    #[test]
    fn a_queued_mark_wins_over_the_pulled_state() {
        let mut files = vec![
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Dismissed),
            changed_file("c.rs", ViewedState::Viewed),
        ];
        let queued = BTreeMap::from([("a.rs".to_owned(), false), ("b.rs".to_owned(), true)]);
        apply_queued(&mut files, &queued);
        let states: Vec<ViewedState> = files.iter().map(|file| file.viewed).collect();
        assert_eq!(
            states,
            [
                ViewedState::Unviewed,
                ViewedState::Viewed,
                ViewedState::Viewed
            ]
        );
    }

    #[test]
    fn a_queued_mark_for_a_file_no_longer_changed_is_dropped() {
        let files = [changed_file("b.rs", ViewedState::Unviewed)];
        let mut queued = BTreeMap::from([("a.rs".to_owned(), false), ("b.rs".to_owned(), true)]);
        drop_stale_marks(&mut queued, &files);
        assert_eq!(queued, BTreeMap::from([("b.rs".to_owned(), true)]));
    }

    #[test]
    fn directory_matching_checks_nested_paths_without_prefix_collisions() {
        assert!(is_path_in_directory("src/core/a.rs", "src"));
        assert!(is_path_in_directory("src/core/a.rs", "src/core/"));
        assert!(!is_path_in_directory("src_extra/a.rs", "src"));
        assert!(!is_path_in_directory("src", "src"));
        assert!(!is_path_in_directory("src/a.rs", ""));
        assert!(!is_path_in_directory("src/a.rs", "/"));
    }

    #[test]
    fn directory_toggle_marks_all_viewed_when_any_descendant_is_not_viewed() {
        let mixed = [
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/sub/b.rs", ViewedState::Unviewed),
            changed_file("README.md", ViewedState::Unviewed),
        ];
        assert_eq!(
            collect_directory_toggle_paths(&mixed, "src"),
            Some((vec!["src/a.rs".to_owned(), "src/sub/b.rs".to_owned()], true))
        );

        let with_dismissed = [
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/sub/b.rs", ViewedState::Dismissed),
        ];
        assert_eq!(
            collect_directory_toggle_paths(&with_dismissed, "src"),
            Some((vec!["src/a.rs".to_owned(), "src/sub/b.rs".to_owned()], true))
        );

        let all_viewed = [
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/sub/b.rs", ViewedState::Viewed),
        ];
        assert_eq!(
            collect_directory_toggle_paths(&all_viewed, "src"),
            Some((
                vec!["src/a.rs".to_owned(), "src/sub/b.rs".to_owned()],
                false
            ))
        );
        assert_eq!(collect_directory_toggle_paths(&all_viewed, "docs"), None);
    }
}
