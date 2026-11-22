//! The in-memory [`Workspace`] fake: a checkout with files at the merge base,
//! files on disk, and renames.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow, bail};

use crate::ports::Workspace;

/// The merge base a [`FakeWorkspace`] reports for any base commit.
pub const FAKE_MERGE_BASE: &str = "merge000";

#[derive(Debug, Default)]
struct WorkspaceState {
    commits: HashMap<String, HashMap<String, Vec<u8>>>,
    disk: HashMap<String, Vec<u8>>,
    renames: Vec<(String, String)>,
    merge_base_calls: usize,
    failure: Option<String>,
    list_changed_failure: Option<String>,
    disk_read_failures: HashMap<String, String>,
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
        self.put_at(FAKE_MERGE_BASE, path, text);
    }

    /// Puts `text` at `path` for `commit`.
    pub fn put_at(&self, commit: &str, path: &str, text: &str) {
        self.lock()
            .commits
            .entry(commit.to_owned())
            .or_default()
            .insert(path.to_owned(), text.as_bytes().to_vec());
    }

    /// Puts `text` at `path` on disk.
    pub fn put_disk(&self, path: &str, text: &str) {
        self.write_disk(path, text.as_bytes());
    }

    /// Writes raw `bytes` at `path` on disk.
    pub fn write_disk(&self, path: &str, bytes: impl Into<Vec<u8>>) {
        self.lock().disk.insert(path.to_owned(), bytes.into());
    }

    /// Removes `path` from disk if present.
    pub fn remove_disk(&self, path: &str) {
        self.lock().disk.remove(path);
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

    /// Makes `list_changed_files_since` fail with `message`, or succeed again
    /// with `None`.
    pub fn fail_list_changed_with(&self, message: Option<&str>) {
        self.lock().list_changed_failure = message.map(str::to_owned);
    }

    /// Makes `file_on_disk(path)` fail with `message`, or succeed again with
    /// `None`.
    pub fn fail_disk_read_with(&self, path: &str, message: Option<&str>) {
        let mut state = self.lock();
        if let Some(reason) = message {
            state
                .disk_read_failures
                .insert(path.to_owned(), reason.to_owned());
        } else {
            state.disk_read_failures.remove(path);
        }
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
        let found = self
            .lock()
            .commits
            .get(commit)
            .map(|files| files.get(path).cloned());
        if let Some(bytes) = found {
            return Ok(bytes);
        }
        if commit == FAKE_MERGE_BASE {
            return Ok(None);
        }
        bail!("the fake workspace has no commit {commit}");
    }

    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>> {
        let state = self.lock();
        if let Some(message) = state.disk_read_failures.get(path) {
            return Err(anyhow!("{message}"));
        }
        Ok(state.disk.get(path).cloned())
    }

    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>> {
        if commit != FAKE_MERGE_BASE {
            bail!("the fake workspace has no commit {commit}");
        }
        Ok(self.lock().renames.clone())
    }

    fn list_changed_files_since(&self, commit: &str) -> Result<Vec<String>> {
        let state = self.lock();
        if let Some(message) = &state.list_changed_failure {
            return Err(anyhow!("{message}"));
        }
        let commit_files = state.commits.get(commit);
        let mut changed: BTreeSet<String> = state
            .disk
            .iter()
            .filter(|(path, disk_bytes)| {
                commit_files.and_then(|files| files.get(*path)) != Some(*disk_bytes)
            })
            .map(|(path, _)| path.clone())
            .collect();
        if let Some(files) = commit_files {
            for path in files.keys() {
                if !state.disk.contains_key(path) {
                    changed.insert(path.clone());
                }
            }
        }
        drop(state);
        Ok(changed.into_iter().collect())
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

    #[test]
    fn list_changed_files_since_detects_modified_untracked_and_deleted_files_sorted() {
        let workspace = FakeWorkspace::default();
        workspace.put_at("head1", "src/unchanged.rs", "same\n");
        workspace.put_at("head1", "src/modified.rs", "old\n");
        workspace.put_at("head1", "src/deleted.rs", "gone\n");
        workspace.write_disk("src/unchanged.rs", b"same\n");
        workspace.write_disk("src/untracked.rs", b"new file\n");
        workspace.write_disk("src/modified.rs", b"updated\n");
        workspace.write_disk("src/deleted.rs", b"gone\n");
        workspace.remove_disk("src/deleted.rs");
        assert_eq!(
            workspace.file_on_disk("src/modified.rs").unwrap(),
            Some(b"updated\n".to_vec())
        );
        assert_eq!(workspace.file_on_disk("src/deleted.rs").unwrap(), None);
        assert_eq!(
            workspace.list_changed_files_since("head1").unwrap(),
            vec!["src/deleted.rs", "src/modified.rs", "src/untracked.rs"]
        );
    }
}
