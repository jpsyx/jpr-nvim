//! The in-memory [`Workspace`] fake: a checkout with files at the merge base,
//! files on disk, and renames.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow, bail};
use review_model::{PullRequest, WorktreeStatus};

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
    ref_shas: HashMap<String, String>,
    status_remote_shas: Vec<Option<String>>,
    status_override: Option<WorktreeStatus>,
    push_failure: Option<String>,
    pushed_refs: Vec<(String, String)>,
    pushed_prs: Vec<PullRequest>,
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

    /// Sets the commit SHA reported by [`Workspace::resolve_ref`] for `reference`.
    pub fn set_ref_sha(&self, reference: &str, sha: &str) {
        self.lock()
            .ref_shas
            .insert(reference.to_owned(), sha.to_owned());
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

    /// Every [`PullRequest`] passed to [`Workspace::push_head`].
    #[must_use]
    pub fn pushed_prs(&self) -> Vec<PullRequest> {
        self.lock().pushed_prs.clone()
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

    fn resolve_ref(&self, reference: &str) -> Result<String> {
        let state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        Ok(state
            .ref_shas
            .get(reference)
            .cloned()
            .unwrap_or_else(|| "base000".to_owned()))
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

    fn push_head(&self, pr: &PullRequest) -> Result<String> {
        let mut state = self.lock();
        if let Some(message) = &state.push_failure {
            return Err(anyhow!("{message}"));
        }
        let current_head = state.current_head_commit();
        state
            .pushed_refs
            .push((pr.head_ref.clone(), current_head.clone()));
        state.pushed_prs.push(pr.clone());
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
mod tests;
