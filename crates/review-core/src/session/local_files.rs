//! Local worktree file merging, rename migration, and immediate worktree refresh.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::Result;
use review_diff::{FileText, create_file_diff_view_from_texts};
use review_model::{ChangedFile, Event, Origin, SessionView, ViewedState};
use serde::{Deserialize, Serialize};

use super::ReviewSession;
use super::diffs::MAX_DIFF_BYTES;
use crate::reanchor::{
    collect_changed_digest_paths, hash_bounded_file_bytes, validate_safe_relative_path,
};

/// One repository-relative file or directory rename reported by a frontend.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PathRename {
    /// Previous repository-relative path.
    pub old_path: String,
    /// New repository-relative path.
    pub new_path: String,
}

/// Rewrites `path` when it equals `rename.old_path` or sits inside the
/// `rename.old_path/` directory prefix.
#[must_use]
pub fn rewrite_renamed_path(path: &str, rename: &PathRename) -> Option<String> {
    if path == rename.old_path {
        return Some(rename.new_path.clone());
    }
    let suffix = path
        .strip_prefix(rename.old_path.as_str())
        .and_then(|rest| rest.strip_prefix('/'))?;
    Some(format!("{}/{suffix}", rename.new_path))
}

fn apply_renames_to_path(path: &str, renames: &[PathRename]) -> Option<String> {
    let mut current: Option<String> = None;
    for rename in renames {
        let candidate = current.as_deref().unwrap_or(path);
        if let Some(updated) = rewrite_renamed_path(candidate, rename) {
            current = Some(updated);
        }
    }
    current
}

impl ReviewSession {
    /// Returns every pull-request file (`is_local_only = false`) followed by
    /// local-only worktree files (`is_local_only = true`).
    pub(super) fn effective_files(&self) -> Vec<(ChangedFile, bool)> {
        let mut combined = Vec::with_capacity(self.saved.files.len() + self.local_files.len());
        for file in &self.saved.files {
            combined.push((file.clone(), false));
        }
        for file in &self.local_files {
            let mut local_file = file.clone();
            local_file.viewed = self
                .saved
                .local
                .local_viewed
                .get(&file.path)
                .copied()
                .unwrap_or(ViewedState::Unviewed);
            combined.push((local_file, true));
        }
        combined
    }

    /// Returns whether `path` is present in either `saved.files` or `local_files`.
    pub(super) fn has_effective_file(&self, path: &str) -> bool {
        self.saved.files.iter().any(|file| file.path == path)
            || self.local_files.iter().any(|file| file.path == path)
    }

    /// Returns whether `path` exists only in `local_files` and not `saved.files`.
    pub(super) fn is_local_only_file(&self, path: &str) -> bool {
        !self.saved.files.iter().any(|file| file.path == path)
            && self.local_files.iter().any(|file| file.path == path)
    }

    /// Recomputes `local_files` from the worktree delta since `merge_base`,
    /// caching line counts per `(path, disk_digest)`. Returns whether the list changed.
    pub(super) fn refresh_local_files(&mut self) -> bool {
        if !self.has_active_base() || self.prepare_base().is_err() {
            return false;
        }
        let merge_base = self.base_cache.merge_base.clone();
        let Ok(changed_paths) = self.ports.workspace.list_changed_files_since(&merge_base) else {
            return false;
        };
        let saved_paths: BTreeSet<String> = self
            .saved
            .files
            .iter()
            .map(|file| file.path.clone())
            .collect();
        let mut next_local_files = Vec::new();
        let mut active_local_paths = BTreeSet::new();
        for path in changed_paths {
            if saved_paths.contains(&path) {
                continue;
            }
            active_local_paths.insert(path.clone());
            next_local_files.push(self.build_local_changed_file(&path));
        }
        self.local_file_counts
            .retain(|path, _| active_local_paths.contains(path));
        let did_change = self.local_files != next_local_files;
        self.local_files = next_local_files;
        did_change
    }

    /// Migrates local thread anchors and `local_viewed` entries for `renames`,
    /// refreshes local worktree files, digests, and git status, and returns the
    /// updated [`SessionView`].
    pub fn refresh_worktree(&mut self, renames: &[PathRename]) -> Result<SessionView> {
        for rename in renames {
            validate_safe_relative_path(&rename.old_path)?;
            validate_safe_relative_path(&rename.new_path)?;
        }
        let (did_migrate_threads, did_migrate_local) = self.migrate_renames(renames);
        if did_migrate_threads || did_migrate_local {
            self.split_and_save_threads()?;
        }
        self.invalidate_base_renames();
        self.local_file_counts.clear();
        let did_local_files_change = self.refresh_local_files();
        let current_digests = self.collect_worktree_digests();
        let (changed_paths, edited_paths) =
            collect_refresh_changed_paths(self.disk_digests.as_ref(), &current_digests, renames);
        if !edited_paths.is_empty() && self.dismiss_edited_local_viewed(&edited_paths)? {
            self.refresh_local_files();
        }
        self.disk_digests = Some(current_digests);
        let did_reanchor = if changed_paths.is_empty() {
            false
        } else {
            self.reanchor_and_save_local_threads(&changed_paths)?
        };
        let status = self.current_worktree_status();
        let view = self.view_with_status(&status);
        self.emit_refresh_events(
            &view,
            &status,
            &changed_paths,
            did_local_files_change,
            did_migrate_threads || did_reanchor,
        );
        Ok(view)
    }

    /// Transitions any local-only `Viewed` file in `changed_paths` to `Dismissed`.
    pub(super) fn dismiss_edited_local_viewed(&mut self, changed_paths: &[String]) -> Result<bool> {
        let mut did_dismiss = false;
        for path in changed_paths {
            if self.is_local_only_file(path)
                && self.saved.local.local_viewed.get(path) == Some(&ViewedState::Viewed)
            {
                self.saved
                    .local
                    .local_viewed
                    .insert(path.clone(), ViewedState::Dismissed);
                did_dismiss = true;
            }
        }
        if did_dismiss {
            self.ports.store.save(&self.saved)?;
        }
        Ok(did_dismiss)
    }

    /// Promotes `local_viewed` entries for files newly present in `incoming_files`
    /// into `queued_viewed`, removing adopted entries from `local_viewed`.
    pub(super) fn promote_adopted_local_viewed(&mut self, incoming_files: &[ChangedFile]) -> bool {
        let mut did_promote = false;
        for file in incoming_files {
            if let Some(state) = self.saved.local.local_viewed.remove(&file.path)
                && state == ViewedState::Viewed
            {
                self.saved
                    .registry
                    .queued_viewed
                    .insert(file.path.clone(), true);
                did_promote = true;
            }
        }
        did_promote
    }

    /// Drops `local_viewed` entries for paths that are no longer in `local_files`.
    pub(super) fn prune_stale_local_viewed(&mut self) {
        let active_local: BTreeSet<&str> = self
            .local_files
            .iter()
            .map(|file| file.path.as_str())
            .collect();
        self.saved
            .local
            .local_viewed
            .retain(|path, _| active_local.contains(path.as_str()));
    }

    fn build_local_changed_file(&mut self, path: &str) -> ChangedFile {
        let disk_bytes = self.ports.workspace.file_on_disk(path).ok().flatten();
        let digest = disk_bytes
            .as_deref()
            .map_or(0, |bytes| hash_bounded_file_bytes(bytes, MAX_DIFF_BYTES));
        let (additions, deletions) = if let Some(&(cached_digest, counts)) =
            self.local_file_counts.get(path)
            && cached_digest == digest
        {
            counts
        } else {
            let counts = self.compute_local_file_counts(path, disk_bytes);
            self.local_file_counts
                .insert(path.to_owned(), (digest, counts));
            counts
        };
        let viewed = self
            .saved
            .local
            .local_viewed
            .get(path)
            .copied()
            .unwrap_or(ViewedState::Unviewed);
        ChangedFile {
            path: path.to_owned(),
            additions,
            deletions,
            viewed,
        }
    }

    fn compute_local_file_counts(&mut self, path: &str, disk_bytes: Option<Vec<u8>>) -> (u64, u64) {
        if disk_bytes
            .as_deref()
            .is_some_and(|bytes| bytes.len() > MAX_DIFF_BYTES)
        {
            return (0, 0);
        }
        let Ok(base_text) = self.base_text_after_prepare(path) else {
            return (0, 0);
        };
        let current_text = FileText::from_bytes(disk_bytes);
        if base_text.is_binary() || current_text.is_binary() {
            return (0, 0);
        }
        let diff = create_file_diff_view_from_texts(path, &base_text, &current_text);
        let additions = u64::try_from(diff.added.len()).unwrap_or(u64::MAX);
        let deletions = diff
            .removed
            .iter()
            .map(|block| u64::try_from(block.lines.len()).unwrap_or(u64::MAX))
            .sum();
        (additions, deletions)
    }

    fn migrate_renames(&mut self, renames: &[PathRename]) -> (bool, bool) {
        if renames.is_empty() {
            return (false, false);
        }
        let mut did_migrate_threads = false;
        for thread in &mut self.threads {
            if thread.origin == Origin::Local
                && let Some(path) = thread.anchor.file.as_deref()
                && let Some(updated) = apply_renames_to_path(path, renames)
            {
                thread.anchor.file = Some(updated);
                did_migrate_threads = true;
            }
        }
        let mut did_migrate_viewed = false;
        let mut updated_viewed = BTreeMap::new();
        for (path, state) in std::mem::take(&mut self.saved.local.local_viewed) {
            if let Some(updated) = apply_renames_to_path(&path, renames) {
                updated_viewed.insert(updated, state);
                did_migrate_viewed = true;
            } else {
                updated_viewed.insert(path, state);
            }
        }
        self.saved.local.local_viewed = updated_viewed;
        (did_migrate_threads, did_migrate_viewed)
    }

    fn emit_refresh_events(
        &mut self,
        view: &SessionView,
        status: &review_model::WorktreeStatus,
        changed_paths: &[String],
        did_local_files_change: bool,
        did_threads_change: bool,
    ) {
        if did_threads_change {
            self.publish(&Event::ThreadsChanged {
                view: Box::new(view.clone()),
            });
        }
        if !changed_paths.is_empty() || did_local_files_change {
            self.publish(&Event::FilesChanged {
                paths: changed_paths.to_vec(),
                view: Box::new(view.clone()),
            });
        } else if self
            .last_worktree_status
            .as_ref()
            .is_some_and(|previous| previous != status)
        {
            self.publish(&Event::WorktreeStatusChanged {
                view: Box::new(view.clone()),
            });
        } else {
            self.last_worktree_status = Some(status.clone());
        }
    }
}

fn collect_refresh_changed_paths(
    previous_digests: Option<&BTreeMap<String, u64>>,
    current_digests: &BTreeMap<String, u64>,
    renames: &[PathRename],
) -> (Vec<String>, Vec<String>) {
    let Some(previous) = previous_digests else {
        return (collect_rename_paths(renames), Vec::new());
    };
    let changed = collect_changed_digest_paths(previous, current_digests);
    let edited = changed
        .iter()
        .filter(|path| previous.contains_key(*path))
        .cloned()
        .collect();
    (changed, edited)
}

fn collect_rename_paths(renames: &[PathRename]) -> Vec<String> {
    let mut paths = BTreeSet::new();
    for rename in renames {
        paths.insert(rename.old_path.clone());
        paths.insert(rename.new_path.clone());
    }
    paths.into_iter().collect()
}

#[cfg(test)]
mod tests;
