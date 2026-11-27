//! Pure rules for which collapsed sidebar directories stay collapsed.

use std::collections::{BTreeMap, BTreeSet};

use review_model::{ChangedFile, TreeRow, ViewedState};

use crate::viewed::is_path_in_directory;

/// Computes the persisted `collapsed_dirs` set after a GitHub pull.
///
/// Called by `ReviewSession::apply_collapsed_dirs_after_pull` on a successful
/// sync. Expands a directory only when a file inside it newly changes to
/// `Dismissed` on GitHub. When `should_prune_empty` is true, drops collapsed
/// paths with no remaining PR or local-only file.
#[must_use]
pub fn create_collapsed_dirs_after_pull(
    collapsed: &BTreeSet<String>,
    previous: &BTreeMap<String, ViewedState>,
    forge: &BTreeMap<String, ViewedState>,
    reconciled: &[ChangedFile],
    local_only_paths: &[String],
    should_prune_empty: bool,
) -> BTreeSet<String> {
    let dismissed_paths: Vec<String> = reconciled
        .iter()
        .filter(|file| file_became_dismissed_from_forge(file, previous, forge))
        .map(|file| file.path.clone())
        .collect();
    let mut remaining = create_collapsed_dirs_after_dismiss(collapsed, &dismissed_paths);
    if should_prune_empty {
        remaining.retain(|dir| directory_contains_file(dir, reconciled, local_only_paths));
    }
    remaining
}

/// Removes only the collapsed ancestor directories needed to reveal each newly
/// dismissed file path, leaving sibling and unrelated collapsed directories intact.
///
/// Called by `create_collapsed_dirs_after_pull` after a GitHub sync and by
/// `ReviewSession::dismiss_edited_local_viewed` when a local disk edit dismisses
/// a previously viewed local-only file.
#[must_use]
pub fn create_collapsed_dirs_after_dismiss(
    collapsed: &BTreeSet<String>,
    dismissed_paths: &[String],
) -> BTreeSet<String> {
    let mut remaining = collapsed.clone();
    for path in dismissed_paths {
        remaining.retain(|dir| !is_path_in_directory(path, dir));
    }
    remaining
}

/// Removes `path` from `collapsed` when expanding a sidebar directory, plus any
/// strict ancestor prefix swallowed into a lone-child joined row for `path`.
///
/// Called by `ReviewSession::set_collapsed` when expanding a directory so that
/// expanding a joined row like `docs/x` also clears a collapsed `docs` prefix
/// without clearing a separately rendered parent row.
#[must_use]
pub fn create_collapsed_dirs_after_expand(
    collapsed: &BTreeSet<String>,
    path: &str,
    tree: &[TreeRow],
) -> BTreeSet<String> {
    let mut remaining = collapsed.clone();
    remaining.remove(path);
    if tree.is_empty() {
        return remaining;
    }
    let tree_dir_paths = collect_tree_dir_paths(tree);
    if !tree_dir_paths.contains(path) {
        return remaining;
    }
    remaining.retain(|dir| !is_path_in_directory(path, dir) || tree_dir_paths.contains(dir));
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

fn file_became_dismissed_from_forge(
    file: &ChangedFile,
    previous: &BTreeMap<String, ViewedState>,
    forge: &BTreeMap<String, ViewedState>,
) -> bool {
    file.viewed == ViewedState::Dismissed
        && forge.get(&file.path) == Some(&ViewedState::Dismissed)
        && previous.get(&file.path) != Some(&ViewedState::Dismissed)
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

fn collect_tree_dir_paths(tree: &[TreeRow]) -> BTreeSet<String> {
    let mut dir_paths = BTreeSet::new();
    let mut stack: Vec<(usize, String)> = Vec::new();
    for row in tree {
        while stack.last().is_some_and(|(depth, _)| *depth >= row.depth) {
            stack.pop();
        }
        if row.file.is_some() {
            continue;
        }
        let segment = row.name.trim_end_matches('/');
        let dir_path = stack.last().map_or_else(
            || segment.to_owned(),
            |(_, parent)| format!("{parent}/{segment}"),
        );
        dir_paths.insert(dir_path.clone());
        stack.push((row.depth, dir_path));
    }
    dir_paths
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
            create_collapsed_dirs_after_pull(&collapsed, &previous, &previous, &files, &[], true),
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
                &[],
                true
            ),
            dirs(&["lib"])
        );
    }

    #[test]
    fn unchanged_dismissed_file_keeps_its_collapsed_parent() {
        let previous = states(&[
            ("src/a.rs", ViewedState::Dismissed),
            ("lib/c.rs", ViewedState::Viewed),
        ]);
        let files = vec![
            changed_file("src/a.rs", ViewedState::Dismissed),
            changed_file("lib/c.rs", ViewedState::Viewed),
        ];
        let collapsed = dirs(&["src", "lib"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &previous, &files, &[], true),
            collapsed
        );
    }

    #[test]
    fn new_or_unmarked_unviewed_file_keeps_its_collapsed_parent() {
        let previous = states(&[("src/a.rs", ViewedState::Viewed)]);
        let forge = states(&[
            ("src/a.rs", ViewedState::Unviewed),
            ("src/b.rs", ViewedState::Unviewed),
        ]);
        let files = vec![
            changed_file("src/a.rs", ViewedState::Unviewed),
            changed_file("src/b.rs", ViewedState::Unviewed),
        ];
        let collapsed = dirs(&["src"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &forge, &files, &[], true),
            collapsed
        );
    }

    #[test]
    fn dismissed_file_expands_only_necessary_ancestors_keeping_other_subdirs_collapsed() {
        let previous = states(&[
            ("apps/cli/sub/a.rs", ViewedState::Viewed),
            ("apps/cli/other/b.rs", ViewedState::Viewed),
            ("apps/web/c.rs", ViewedState::Viewed),
            ("lib/d.rs", ViewedState::Viewed),
        ]);
        let forge = states(&[
            ("apps/cli/sub/a.rs", ViewedState::Dismissed),
            ("apps/cli/other/b.rs", ViewedState::Viewed),
            ("apps/web/c.rs", ViewedState::Viewed),
            ("lib/d.rs", ViewedState::Viewed),
        ]);
        let files = vec![
            changed_file("apps/cli/sub/a.rs", ViewedState::Dismissed),
            changed_file("apps/cli/other/b.rs", ViewedState::Viewed),
            changed_file("apps/web/c.rs", ViewedState::Viewed),
            changed_file("lib/d.rs", ViewedState::Viewed),
        ];
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&[
                    "apps",
                    "apps/cli",
                    "apps/cli/sub",
                    "apps/cli/other",
                    "apps/web",
                    "lib",
                ]),
                &previous,
                &forge,
                &files,
                &[],
                true
            ),
            dirs(&["apps/cli/other", "apps/web", "lib"])
        );
    }

    #[test]
    fn queued_viewed_overlay_does_not_expand() {
        let previous = states(&[("src/a.rs", ViewedState::Viewed)]);
        let forge = states(&[("src/a.rs", ViewedState::Dismissed)]);
        let files = vec![changed_file("src/a.rs", ViewedState::Viewed)];
        let collapsed = dirs(&["src"]);
        assert_eq!(
            create_collapsed_dirs_after_pull(&collapsed, &previous, &forge, &files, &[], true),
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
            create_collapsed_dirs_after_pull(&collapsed, &previous, &forge, &files, &[], true),
            collapsed
        );
    }

    #[test]
    fn prefix_boundary_and_joined_directory() {
        let forge = states(&[
            ("src/keep.rs", ViewedState::Viewed),
            ("src2/a.rs", ViewedState::Dismissed),
            ("docs/x/y.md", ViewedState::Dismissed),
        ]);
        let previous = states(&[("src/keep.rs", ViewedState::Viewed)]);
        let files = vec![
            changed_file("src/keep.rs", ViewedState::Viewed),
            changed_file("src2/a.rs", ViewedState::Dismissed),
            changed_file("docs/x/y.md", ViewedState::Dismissed),
        ];
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&["src", "src2", "docs/x"]),
                &previous,
                &forge,
                &files,
                &[],
                true
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
                &["notes/todo.rs".to_owned()],
                true
            ),
            dirs(&["notes"])
        );
    }

    #[test]
    fn skipping_prune_preserves_unscanned_local_only_directories() {
        assert_eq!(
            create_collapsed_dirs_after_pull(
                &dirs(&["notes"]),
                &BTreeMap::new(),
                &BTreeMap::new(),
                &[],
                &[],
                false
            ),
            dirs(&["notes"])
        );
    }
}
