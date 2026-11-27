//! Which collapsed sidebar directories stay collapsed after a GitHub pull.

use std::collections::{BTreeMap, BTreeSet};

use review_model::{ChangedFile, ViewedState};

use crate::viewed::is_path_in_directory;

/// The collapsed set after a pull. A directory expands when a file inside it
/// newly needs review because GitHub says so, and a path with no remaining
/// file is dropped.
#[must_use]
pub fn create_collapsed_dirs_after_pull(
    collapsed: &BTreeSet<String>,
    previous: &BTreeMap<String, ViewedState>,
    forge: &BTreeMap<String, ViewedState>,
    reconciled: &[ChangedFile],
    local_only_paths: &[String],
) -> BTreeSet<String> {
    let mut remaining = collapsed.clone();
    for file in reconciled {
        if file_needs_review_from_forge(file, previous, forge) {
            remaining.retain(|dir| !is_path_in_directory(&file.path, dir));
        }
    }
    remaining.retain(|dir| directory_contains_file(dir, reconciled, local_only_paths));
    remaining
}

/// Path to viewed state, captured before a pull overwrites the files.
#[must_use]
pub fn viewed_states_from_files(files: &[ChangedFile]) -> BTreeMap<String, ViewedState> {
    files
        .iter()
        .map(|file| (file.path.clone(), file.viewed))
        .collect()
}

fn file_needs_review_from_forge(
    file: &ChangedFile,
    previous: &BTreeMap<String, ViewedState>,
    forge: &BTreeMap<String, ViewedState>,
) -> bool {
    let needs_review = is_unviewed_or_dismissed(file.viewed);
    let forge_agrees = forge
        .get(&file.path)
        .is_some_and(|state| is_unviewed_or_dismissed(*state));
    needs_review && forge_agrees && previous.get(&file.path) != Some(&file.viewed)
}

const fn is_unviewed_or_dismissed(state: ViewedState) -> bool {
    matches!(state, ViewedState::Unviewed | ViewedState::Dismissed)
}

fn directory_contains_file(
    dir: &str,
    reconciled: &[ChangedFile],
    local_only_paths: &[String],
) -> bool {
    reconciled
        .iter()
        .any(|file| is_path_in_directory(&file.path, dir))
        || local_only_paths
            .iter()
            .any(|path| is_path_in_directory(path, dir))
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use review_model::ViewedState;

    use super::create_collapsed_dirs_after_pull;
    use crate::fakes::changed_file;

    fn states(pairs: &[(&str, ViewedState)]) -> BTreeMap<String, ViewedState> {
        pairs
            .iter()
            .map(|(path, state)| ((*path).to_owned(), *state))
            .collect()
    }

    fn dirs(paths: &[&str]) -> BTreeSet<String> {
        paths.iter().map(|path| (*path).to_owned()).collect()
    }

    #[test]
    fn unchanged_unviewed_file_keeps_its_collapsed_parent() {
        let previous = states(&[
            ("src/a.rs", ViewedState::Unviewed),
            ("lib/c.rs", ViewedState::Unviewed),
        ]);
        let files = vec![
            changed_file("src/a.rs", ViewedState::Unviewed),
            changed_file("lib/c.rs", ViewedState::Unviewed),
        ];
        let collapsed = dirs(&["src", "lib"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &previous, &files, &[]),
            collapsed
        );
    }

    #[test]
    fn viewed_to_dismissed_expands_only_matching_ancestors() {
        let previous = states(&[
            ("src/a.rs", ViewedState::Viewed),
            ("lib/c.rs", ViewedState::Viewed),
        ]);
        let forge = states(&[
            ("src/a.rs", ViewedState::Dismissed),
            ("lib/c.rs", ViewedState::Viewed),
        ]);
        let files = vec![
            changed_file("src/a.rs", ViewedState::Dismissed),
            changed_file("lib/c.rs", ViewedState::Viewed),
        ];
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&["src", "lib"]),
                &previous,
                &forge,
                &files,
                &[]
            ),
            dirs(&["lib"])
        );
    }

    #[test]
    fn new_unviewed_file_expands_its_ancestors() {
        let forge = states(&[("src/b.rs", ViewedState::Unviewed)]);
        let files = vec![changed_file("src/b.rs", ViewedState::Unviewed)];
        assert!(
            create_collapsed_dirs_after_pull(
                &dirs(&["src"]),
                &BTreeMap::new(),
                &forge,
                &files,
                &[]
            )
            .is_empty()
        );
    }

    #[test]
    fn queued_viewed_overlay_does_not_expand() {
        let previous = states(&[("src/a.rs", ViewedState::Viewed)]);
        let forge = states(&[("src/a.rs", ViewedState::Unviewed)]);
        let files = vec![changed_file("src/a.rs", ViewedState::Viewed)];
        let collapsed = dirs(&["src"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &forge, &files, &[]),
            collapsed
        );
    }

    #[test]
    fn queued_unviewed_overlay_does_not_expand() {
        let previous = states(&[("src/a.rs", ViewedState::Viewed)]);
        let forge = states(&[("src/a.rs", ViewedState::Viewed)]);
        let files = vec![changed_file("src/a.rs", ViewedState::Unviewed)];
        let collapsed = dirs(&["src"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &forge, &files, &[]),
            collapsed
        );
    }

    #[test]
    fn prefix_boundary_and_joined_directory() {
        let forge = states(&[
            ("src/keep.rs", ViewedState::Viewed),
            ("src2/a.rs", ViewedState::Unviewed),
            ("docs/x/y.md", ViewedState::Dismissed),
        ]);
        let previous = states(&[("src/keep.rs", ViewedState::Viewed)]);
        let files = vec![
            changed_file("src/keep.rs", ViewedState::Viewed),
            changed_file("src2/a.rs", ViewedState::Unviewed),
            changed_file("docs/x/y.md", ViewedState::Dismissed),
        ];
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&["src", "src2", "docs/x"]),
                &previous,
                &forge,
                &files,
                &[]
            ),
            dirs(&["src"])
        );
    }

    #[test]
    fn local_only_file_keeps_a_collapsed_directory_and_an_empty_path_is_pruned() {
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&["notes", "gone"]),
                &BTreeMap::new(),
                &BTreeMap::new(),
                &[],
                &["notes/todo.rs".to_owned()]
            ),
            dirs(&["notes"])
        );
    }
}
