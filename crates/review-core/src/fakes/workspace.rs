//! The in-memory [`Workspace`] fake: a checkout with files at the merge base,
//! files on disk, and renames.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow, bail};

use crate::ports::Workspace;

/// The merge base a [`FakeWorkspace`] reports for any base commit.
pub const FAKE_MERGE_BASE: &str = "merge000";

#[derive(Debug, Default)]
struct WorkspaceState {
    base: HashMap<String, Vec<u8>>,
    disk: HashMap<String, Vec<u8>>,
    renames: Vec<(String, String)>,
    merge_base_calls: usize,
    failure: Option<String>,
}

/// A checkout held in memory, for session and server tests.
///
/// It holds files at the merge base, files on disk, and renames. Clones share
/// state, so a test keeps one to fill and inspect while the session holds
/// another.
#[derive(Debug, Clone, Default)]
pub struct FakeWorkspace {
    state: Arc<Mutex<WorkspaceState>>,
}

impl FakeWorkspace {
    /// Puts `text` at `path` in the merge base.
    pub fn put_base(&self, path: &str, text: &str) {
        self.lock()
            .base
            .insert(path.to_owned(), text.as_bytes().to_vec());
    }

    /// Puts `text` at `path` on disk.
    pub fn put_disk(&self, path: &str, text: &str) {
        self.lock()
            .disk
            .insert(path.to_owned(), text.as_bytes().to_vec());
    }

    /// Records that `old` was renamed to `new` since the merge base.
    pub fn rename(&self, old: &str, new: &str) {
        self.lock().renames.push((old.to_owned(), new.to_owned()));
    }

    /// Makes finding the merge base fail with `message`, or succeed again
    /// with `None`.
    pub fn fail_with(&self, message: Option<&str>) {
        self.lock().failure = message.map(str::to_owned);
    }

    /// How many times the merge base was looked up.
    #[must_use]
    pub fn merge_base_calls(&self) -> usize {
        self.lock().merge_base_calls
    }

    fn lock(&self) -> MutexGuard<'_, WorkspaceState> {
        self.state
            .lock()
            .expect("the fake workspace lock is poisoned")
    }
}

impl Workspace for FakeWorkspace {
    fn merge_base(&self, _base_sha: &str) -> Result<String> {
        {
            let mut state = self.lock();
            if let Some(message) = &state.failure {
                return Err(anyhow!("{message}"));
            }
            state.merge_base_calls += 1;
        }
        Ok(FAKE_MERGE_BASE.to_owned())
    }

    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>> {
        if commit != FAKE_MERGE_BASE {
            bail!("the fake workspace has no commit {commit}");
        }
        Ok(self.lock().base.get(path).cloned())
    }

    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.lock().disk.get(path).cloned())
    }

    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>> {
        if commit != FAKE_MERGE_BASE {
            bail!("the fake workspace has no commit {commit}");
        }
        Ok(self.lock().renames.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fake_workspace_answers_from_memory() {
        let workspace = FakeWorkspace::default();
        workspace.put_base("src/old.rs", "base\n");
        workspace.put_disk("src/a.rs", "disk\n");
        workspace.rename("src/old.rs", "src/a.rs");
        assert_eq!(workspace.merge_base("base000").unwrap(), FAKE_MERGE_BASE);
        assert_eq!(workspace.merge_base_calls(), 1);
        assert_eq!(
            workspace.file_at(FAKE_MERGE_BASE, "src/old.rs").unwrap(),
            Some(b"base\n".to_vec())
        );
        assert!(workspace.file_at("other", "src/old.rs").is_err());
        assert_eq!(
            workspace.file_on_disk("src/a.rs").unwrap(),
            Some(b"disk\n".to_vec())
        );
        assert_eq!(workspace.file_on_disk("src/b.rs").unwrap(), None);
        assert_eq!(
            workspace.renames(FAKE_MERGE_BASE).unwrap(),
            [("src/old.rs".to_owned(), "src/a.rs".to_owned())]
        );
        workspace.fail_with(Some("no network"));
        assert!(workspace.merge_base("base000").is_err());
    }
}
