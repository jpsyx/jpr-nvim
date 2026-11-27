//! Persisting which sidebar directories the reviewer collapsed.

use anyhow::Result;
use review_model::SessionView;

use super::ReviewSession;
use crate::reanchor::validate_safe_relative_path;

impl ReviewSession {
    /// Collapses or expands one sidebar directory and saves `local.json`.
    ///
    /// An unsafe path is rejected and the set is left unchanged. A request
    /// that does not change membership returns the current view without
    /// writing. A failed save restores the previous set.
    pub fn set_collapsed(&mut self, path: &str, collapsed: bool) -> Result<SessionView> {
        validate_safe_relative_path(path)?;
        if self.saved.local.collapsed_dirs.contains(path) == collapsed {
            return Ok(self.view());
        }
        let previous = self.saved.local.collapsed_dirs.clone();
        if collapsed {
            self.saved.local.collapsed_dirs.insert(path.to_owned());
        } else {
            self.saved.local.collapsed_dirs.remove(path);
        }
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
}
