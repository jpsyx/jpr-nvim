//! Persisting which sidebar directories the reviewer collapsed.

use anyhow::Result;
use review_model::SessionView;

use super::ReviewSession;
use crate::collapsed::create_collapsed_dirs_after_expand;
use crate::reanchor::validate_safe_relative_path;
use crate::tree::create_file_tree_from_paths;

impl ReviewSession {
    /// Collapses or expands one sidebar directory and saves `local.json`.
    ///
    /// An unsafe path is rejected and the set is left unchanged. A request
    /// that does not change membership returns the current view without
    /// writing. A failed save restores the previous set.
    pub fn set_collapsed(&mut self, path: &str, collapsed: bool) -> Result<SessionView> {
        validate_safe_relative_path(path)?;
        let updated = if collapsed {
            let mut next_set = self.saved.local.collapsed_dirs.clone();
            next_set.insert(path.to_owned());
            next_set
        } else {
            let effective = self.effective_files();
            let tree =
                create_file_tree_from_paths(effective.iter().map(|(file, _)| file.path.as_str()));
            create_collapsed_dirs_after_expand(&self.saved.local.collapsed_dirs, path, &tree)
        };
        if updated == self.saved.local.collapsed_dirs {
            return Ok(self.view());
        }
        let previous = std::mem::replace(&mut self.saved.local.collapsed_dirs, updated);
        if let Err(error) = self.ports.store.save(&self.saved) {
            self.saved.local.collapsed_dirs = previous;
            return Err(error);
        }
        Ok(self.view())
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::super::test_support::Fakes;

    fn paths(values: &[&str]) -> BTreeSet<String> {
        values.iter().map(|path| (*path).to_owned()).collect()
    }

    #[test]
    fn set_collapsed_persists_and_round_trips_on_the_view() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let view = session.set_collapsed("src/core", true).unwrap();
        assert_eq!(view.collapsed_dirs, paths(&["src/core"]));
        assert_eq!(
            fakes.store.saved().local.collapsed_dirs,
            paths(&["src/core"])
        );
        let cleared = session.set_collapsed("src/core", false).unwrap();
        assert!(cleared.collapsed_dirs.is_empty());
        assert!(fakes.store.saved().local.collapsed_dirs.is_empty());
    }

    #[test]
    fn set_collapsed_same_value_leaves_the_set_unchanged() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        session.set_collapsed("src", true).unwrap();
        let view = session.set_collapsed("src", true).unwrap();
        assert_eq!(view.collapsed_dirs, paths(&["src"]));
    }

    #[test]
    fn set_collapsed_rejects_an_unsafe_path_without_changing_the_set() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        assert!(session.set_collapsed("../src", true).is_err());
        assert!(session.set_collapsed("src//core", true).is_err());
        assert!(fakes.store.saved().local.collapsed_dirs.is_empty());
    }

    #[test]
    fn set_collapsed_restores_the_set_when_the_save_fails() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.store.fail_saves_with(Some("disk full"));
        let error = session.set_collapsed("src", true).unwrap_err();
        assert!(error.to_string().contains("disk full"));
        assert!(session.view().collapsed_dirs.is_empty());
        assert!(fakes.store.saved().local.collapsed_dirs.is_empty());
    }

    #[test]
    fn set_viewed_does_not_expand_a_collapsed_directory() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        session.set_collapsed("src", true).unwrap();
        session.set_viewed("src/a.rs", false).unwrap();
        assert_eq!(session.view().collapsed_dirs, paths(&["src"]));
    }

    #[test]
    fn collapsing_and_expanding_parent_preserves_independent_subdir_states() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        session.set_collapsed("apps/other", true).unwrap();
        session.set_collapsed("apps", true).unwrap();
        assert_eq!(
            session.view().collapsed_dirs,
            paths(&["apps", "apps/other"])
        );
        let expanded = session.set_collapsed("apps", false).unwrap();
        assert_eq!(expanded.collapsed_dirs, paths(&["apps/other"]));
    }

    #[test]
    fn expanding_joined_directory_clears_swallowed_collapsed_prefix_only() {
        let fakes = Fakes::new(100);
        let mut snapshot = super::super::test_support::create_snapshot();
        snapshot.files = vec![crate::fakes::changed_file(
            "docs/x/y.md",
            review_model::ViewedState::Viewed,
        )];
        fakes.forge.set_snapshot(snapshot.clone());
        let mut session = fakes.open_synced();
        session.set_collapsed("docs", true).unwrap();
        let expanded = session.set_collapsed("docs/x", false).unwrap();
        assert!(expanded.collapsed_dirs.is_empty());

        // When `docs` is its own row alongside `docs/x`, expanding `docs/x` leaves `docs` alone.
        snapshot.files.push(crate::fakes::changed_file(
            "docs/root.md",
            review_model::ViewedState::Viewed,
        ));
        fakes.forge.set_snapshot(snapshot);
        session.sync().unwrap();
        session.set_collapsed("docs", true).unwrap();
        session.set_collapsed("docs/x", true).unwrap();
        let kept_parent = session.set_collapsed("docs/x", false).unwrap();
        assert_eq!(kept_parent.collapsed_dirs, paths(&["docs"]));
    }
}
