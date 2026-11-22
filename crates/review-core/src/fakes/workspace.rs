//! The in-memory [`Workspace`] fake: a checkout with files at the merge base,
//! files on disk, and renames.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow, bail};
use review_model::WorktreeStatus;

use crate::ports::{FastForwardOutcome, Workspace};

/// The merge base a [`FakeWorkspace`] reports for any base commit.
pub const FAKE_MERGE_BASE: &str = "merge000";

const DEFAULT_HEAD_COMMIT: &str = "abc123";

#[derive(Debug, Default)]
struct WorkspaceState {
    commits: HashMap<String, HashMap<String, Vec<u8>>>,
    disk: HashMap<String, Vec<u8>>,
    renames: Vec<(String, String)>,
    merge_base_calls: usize,
    failure: Option<String>,
    list_changed_failure: Option<String>,
    disk_read_failures: HashMap<String, String>,
    head_commit: Option<String>,
    head_commit_calls: usize,
    status_remote_shas: Vec<Option<String>>,
    status_override: Option<WorktreeStatus>,
    push_failure: Option<String>,
    pushed_refs: Vec<(String, String)>,
    fast_forward_override: Option<std::result::Result<FastForwardOutcome, String>>,
}

impl WorkspaceState {
    fn current_head_commit(&self) -> String {
        self.head_commit
            .clone()
            .unwrap_or_else(|| DEFAULT_HEAD_COMMIT.to_owned())
    }
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

    /// Sets the `HEAD` commit SHA reported by [`Workspace::head_commit`].
    pub fn set_head_commit(&self, sha: &str) {
        self.lock().head_commit = Some(sha.to_owned());
    }

    /// Overrides what [`Workspace::worktree_status`] returns, or clears the
    /// override when `None`.
    pub fn set_worktree_status(&self, status: Option<WorktreeStatus>) {
        self.lock().status_override = status;
    }

    /// Overrides what [`Workspace::fast_forward_to`] returns, or restores
    /// default fast-forward behavior when `None`.
    pub fn set_fast_forward_outcome(
        &self,
        outcome: Option<std::result::Result<FastForwardOutcome, String>>,
    ) {
        self.lock().fast_forward_override = outcome;
    }

    /// Makes [`Workspace::push_head`] fail with `message`, or succeed again
    /// when `None`.
    pub fn fail_push_with(&self, message: Option<&str>) {
        self.lock().push_failure = message.map(str::to_owned);
    }

    /// Every `(head_ref, head_commit)` pushed through [`Workspace::push_head`].
    #[must_use]
    pub fn pushed_refs(&self) -> Vec<(String, String)> {
        self.lock().pushed_refs.clone()
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

    /// How many times `HEAD` was looked up via [`Workspace::head_commit`].
    #[must_use]
    pub fn head_commit_calls(&self) -> usize {
        self.lock().head_commit_calls
    }

    /// Every `remote_head_sha` argument passed to [`Workspace::worktree_status`].
    #[must_use]
    pub fn status_remote_shas(&self) -> Vec<Option<String>> {
        self.lock().status_remote_shas.clone()
    }

    fn lock(&self) -> MutexGuard<'_, WorkspaceState> {
        self.state
            .lock()
            .expect("the fake workspace lock is poisoned")
    }
}

fn collect_changed_paths(
    disk: &HashMap<String, Vec<u8>>,
    commit_files: Option<&HashMap<String, Vec<u8>>>,
) -> Vec<String> {
    let mut changed: BTreeSet<String> = disk
        .iter()
        .filter(|(path, disk_bytes)| {
            commit_files.and_then(|files| files.get(*path)) != Some(*disk_bytes)
        })
        .map(|(path, _)| path.clone())
        .collect();
    if let Some(files) = commit_files {
        for path in files.keys() {
            if !disk.contains_key(path) {
                changed.insert(path.clone());
            }
        }
    }
    changed.into_iter().collect()
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
        let changed = collect_changed_paths(&state.disk, state.commits.get(commit));
        drop(state);
        Ok(changed)
    }

    fn head_commit(&self) -> Result<String> {
        let mut state = self.lock();
        state.head_commit_calls += 1;
        Ok(state.current_head_commit())
    }

    fn worktree_status(&self, remote_head_sha: Option<&str>) -> Result<WorktreeStatus> {
        let mut state = self.lock();
        state
            .status_remote_shas
            .push(remote_head_sha.map(str::to_owned));
        if let Some(status) = &state.status_override {
            return Ok(status.clone());
        }
        let head = state.current_head_commit();
        let Some(head_files) = state.commits.get(&head) else {
            return Ok(WorktreeStatus::default());
        };
        let modified_paths = collect_changed_paths(&state.disk, Some(head_files));
        drop(state);
        Ok(WorktreeStatus {
            is_dirty: !modified_paths.is_empty(),
            ahead: 0,
            behind: 0,
            modified_paths,
        })
    }

    fn push_head(&self, head_ref: &str) -> Result<String> {
        let mut state = self.lock();
        if let Some(message) = &state.push_failure {
            return Err(anyhow!("{message}"));
        }
        let current_head = state.current_head_commit();
        state
            .pushed_refs
            .push((head_ref.to_owned(), current_head.clone()));
        if let Some(status) = &mut state.status_override {
            status.ahead = 0;
        }
        drop(state);
        Ok(current_head)
    }

    fn fast_forward_to(&self, target_sha: &str) -> Result<FastForwardOutcome> {
        let mut state = self.lock();
        if let Some(override_result) = state.fast_forward_override.clone() {
            return match override_result {
                Ok(outcome) => {
                    if let FastForwardOutcome::FastForwarded { head_sha, .. }
                    | FastForwardOutcome::RestoreConflict { head_sha, .. } = &outcome
                    {
                        state.head_commit = Some(head_sha.clone());
                    }
                    drop(state);
                    Ok(outcome)
                }
                Err(message) => Err(anyhow!("{message}")),
            };
        }
        let previous_sha = state.current_head_commit();
        if previous_sha == target_sha {
            return Ok(FastForwardOutcome::AlreadyAtTarget {
                head_sha: previous_sha,
            });
        }
        state.head_commit = Some(target_sha.to_owned());
        drop(state);
        Ok(FastForwardOutcome::FastForwarded {
            previous_sha,
            head_sha: target_sha.to_owned(),
        })
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

    #[test]
    fn tracks_head_commit_worktree_status_and_pushed_refs() {
        let workspace = FakeWorkspace::default();
        assert_eq!(workspace.head_commit().unwrap(), "abc123");
        assert_eq!(
            workspace.worktree_status(Some("abc123")).unwrap(),
            review_model::WorktreeStatus::default()
        );

        workspace.put_at("abc123", "src/a.rs", "clean\n");
        workspace.put_disk("src/a.rs", "dirty\n");
        let derived = workspace.worktree_status(Some("abc123")).unwrap();
        assert!(derived.is_dirty);
        assert_eq!(derived.modified_paths, vec!["src/a.rs"]);

        workspace.set_head_commit("def456");
        workspace.set_worktree_status(Some(review_model::WorktreeStatus {
            is_dirty: false,
            ahead: 2,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        assert_eq!(workspace.push_head("fix/widget").unwrap(), "def456");
        assert_eq!(
            workspace.pushed_refs(),
            vec![("fix/widget".to_owned(), "def456".to_owned())]
        );
        assert_eq!(workspace.worktree_status(Some("def456")).unwrap().ahead, 0);

        workspace.fail_push_with(Some("remote rejected"));
        assert!(workspace.push_head("fix/widget").is_err());
    }

    #[test]
    fn fast_forward_to_defaults_to_noop_or_advancing_head() {
        let workspace = FakeWorkspace::default();
        assert_eq!(
            workspace.fast_forward_to("abc123").unwrap(),
            FastForwardOutcome::AlreadyAtTarget {
                head_sha: "abc123".into(),
            }
        );
        assert_eq!(workspace.head_commit().unwrap(), "abc123");

        assert_eq!(
            workspace.fast_forward_to("def456").unwrap(),
            FastForwardOutcome::FastForwarded {
                previous_sha: "abc123".into(),
                head_sha: "def456".into(),
            }
        );
        assert_eq!(workspace.head_commit().unwrap(), "def456");
    }

    #[test]
    fn fast_forward_to_override_steers_outcomes_and_syncs_head_commit() {
        let workspace = FakeWorkspace::default();
        let conflict = FastForwardOutcome::RestoreConflict {
            previous_sha: "abc123".into(),
            head_sha: "def456".into(),
            conflicted_paths: vec!["src/a.rs".into()],
        };
        workspace.set_fast_forward_outcome(Some(Ok(conflict.clone())));
        assert_eq!(workspace.fast_forward_to("def456").unwrap(), conflict);
        assert_eq!(workspace.head_commit().unwrap(), "def456");

        let diverged = FastForwardOutcome::Diverged {
            head_sha: "def456".into(),
            target_sha: "999999".into(),
        };
        workspace.set_fast_forward_outcome(Some(Ok(diverged.clone())));
        assert_eq!(workspace.fast_forward_to("999999").unwrap(), diverged);
        assert_eq!(workspace.head_commit().unwrap(), "def456");

        workspace.set_fast_forward_outcome(Some(Err("fetch failed".into())));
        assert!(workspace.fast_forward_to("000111").is_err());
        assert_eq!(workspace.head_commit().unwrap(), "def456");

        workspace.set_fast_forward_outcome(None);
        assert_eq!(
            workspace.fast_forward_to("fedcba").unwrap(),
            FastForwardOutcome::FastForwarded {
                previous_sha: "def456".into(),
                head_sha: "fedcba".into(),
            }
        );
        assert_eq!(workspace.head_commit().unwrap(), "fedcba");
    }
}
