//! Live anchor updates and worktree file change polling for `ReviewSession`.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::Result;
use review_diff::FileText;
use review_model::{AnchorKind, Event, LocalAnchorUpdate, Origin, SessionView, Side};

use super::ReviewSession;
use crate::reanchor::{
    AnchorDiskState, apply_anchor_update, collect_changed_digest_paths, hash_bounded_file_bytes,
    reanchor_thread_in_text, validate_safe_relative_path,
};

enum LoadedDiskText {
    Utf8(String),
    Skip,
}

impl ReviewSession {
    /// Updates `Origin::Local` anchor line bounds on `path` from live editor
    /// extmarks and refreshes their saved disk snapshots.
    pub fn update_local_anchors(
        &mut self,
        path: &str,
        updates: &[LocalAnchorUpdate],
    ) -> Result<SessionView> {
        validate_safe_relative_path(path)?;
        if updates.is_empty() {
            return Ok(self.view());
        }
        let disk_state = self.read_anchor_disk_state(path)?;
        let mut did_change = false;
        for update in updates {
            if let Some(thread) = self.threads.iter_mut().find(|thread| {
                thread.id == update.thread_id
                    && thread.origin == Origin::Local
                    && thread.anchor.file.as_deref() == Some(path)
                    && thread.anchor.side == Side::Right
                    && matches!(thread.anchor.kind, AnchorKind::Line | AnchorKind::Range)
            }) && apply_anchor_update(thread, update, &disk_state)
            {
                did_change = true;
            }
        }
        if did_change {
            return self.save_and_announce_threads();
        }
        Ok(self.view())
    }

    /// Polls tracked worktree files on disk for content changes, re-anchoring
    /// any affected `Origin::Local` threads and emitting [`Event::FilesChanged`]
    /// or [`Event::WorktreeStatusChanged`].
    pub fn poll_worktree_files(&mut self) -> Result<Option<Vec<String>>> {
        let current_digests = self.collect_worktree_digests();
        let Some(previous_digests) = self.disk_digests.as_ref() else {
            if self.saved.session.pr.is_some() || !current_digests.is_empty() {
                self.disk_digests = Some(current_digests);
            }
            if let Some(paths) = self.announce_initial_local_files() {
                return Ok(Some(paths));
            }
            self.poll_worktree_status_change();
            return Ok(None);
        };
        let changed_paths = collect_changed_digest_paths(previous_digests, &current_digests);
        if changed_paths.is_empty() {
            self.poll_worktree_status_change();
            return Ok(None);
        }
        self.invalidate_base_renames();
        let _ = self.dismiss_edited_local_viewed(&changed_paths)?;
        self.refresh_local_files();
        let did_reanchor = self.reanchor_and_save_local_threads(&changed_paths)?;
        self.disk_digests = Some(current_digests);
        let view = self.view();
        self.publish(&Event::FilesChanged {
            paths: changed_paths.clone(),
            view: Box::new(view.clone()),
        });
        if did_reanchor {
            self.publish(&Event::ThreadsChanged {
                view: Box::new(view),
            });
        }
        Ok(Some(changed_paths))
    }

    /// Re-anchors local threads touching `changed_paths`, saves updated thread
    /// state, and rolls memory back if persistence fails.
    pub(super) fn reanchor_and_save_local_threads(
        &mut self,
        changed_paths: &[String],
    ) -> Result<bool> {
        let previous_threads = self.threads.clone();
        let previous_github_threads = self.saved.registry.threads.clone();
        let previous_local_threads = self.saved.local.threads.clone();
        let did_reanchor = self.reanchor_changed_local_threads(changed_paths);
        if did_reanchor && let Err(error) = self.split_and_save_threads() {
            self.threads = previous_threads;
            self.saved.registry.threads = previous_github_threads;
            self.saved.local.threads = previous_local_threads;
            return Err(error);
        }
        Ok(did_reanchor)
    }

    fn announce_initial_local_files(&mut self) -> Option<Vec<String>> {
        if self.base_cache.merge_base.is_empty() || !self.refresh_local_files() {
            return None;
        }
        let paths: Vec<String> = self
            .local_files
            .iter()
            .map(|file| file.path.clone())
            .collect();
        let view = self.view();
        self.publish(&Event::FilesChanged {
            paths: paths.clone(),
            view: Box::new(view),
        });
        Some(paths)
    }

    fn poll_worktree_status_change(&mut self) {
        let Some(status) = self.read_worktree_status() else {
            return;
        };
        let should_publish = self
            .last_worktree_status
            .as_ref()
            .is_some_and(|previous_status| previous_status != &status);
        if should_publish {
            let view = self.view_with_status(&status);
            self.publish(&Event::WorktreeStatusChanged {
                view: Box::new(view),
            });
        } else {
            self.last_worktree_status = Some(status);
        }
    }

    fn read_anchor_disk_state(&self, path: &str) -> Result<AnchorDiskState> {
        let Some(bytes) = self.ports.workspace.file_on_disk(path)? else {
            return Ok(AnchorDiskState::Missing);
        };
        Ok(
            bytes_to_utf8_text(bytes)
                .map_or(AnchorDiskState::UnreadableText, AnchorDiskState::Utf8),
        )
    }

    /// Returns deduplicated, sorted file paths referenced by `Origin::Local`
    /// threads so callers can re-anchor them after a HEAD move.
    pub(super) fn collect_local_thread_paths(&self) -> Vec<String> {
        self.threads
            .iter()
            .filter(|thread| thread.origin == Origin::Local)
            .filter_map(|thread| thread.anchor.file.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    fn collect_candidate_paths(&mut self) -> BTreeSet<String> {
        let mut candidates: BTreeSet<String> = self
            .saved
            .files
            .iter()
            .map(|file| file.path.clone())
            .collect();
        for thread in &self.threads {
            if thread.origin == Origin::Local
                && let Some(path) = thread.anchor.file.as_ref()
            {
                candidates.insert(path.clone());
            }
        }
        if let Some(previous_digests) = self.disk_digests.as_ref() {
            candidates.extend(previous_digests.keys().cloned());
        }
        if self.has_active_base() && self.prepare_base().is_ok() {
            let merge_base = self.base_cache.merge_base.clone();
            if let Ok(changed_paths) = self.ports.workspace.list_changed_files_since(&merge_base) {
                candidates.extend(changed_paths);
            }
        }
        candidates
    }

    /// Hashes candidate worktree files on disk so subsequent polls can detect
    /// edits without re-reading full contents in memory.
    pub(super) fn collect_worktree_digests(&mut self) -> BTreeMap<String, u64> {
        let candidates = self.collect_candidate_paths();
        let mut digests = BTreeMap::new();
        for path in candidates {
            match self.ports.workspace.file_on_disk(&path) {
                Ok(Some(bytes)) => {
                    digests.insert(
                        path,
                        hash_bounded_file_bytes(&bytes, super::diffs::MAX_DIFF_BYTES),
                    );
                }
                Ok(None) => {}
                Err(_) => {
                    if let Some(previous_digest) = self
                        .disk_digests
                        .as_ref()
                        .and_then(|map| map.get(&path))
                        .copied()
                    {
                        digests.insert(path, previous_digest);
                    }
                }
            }
        }
        digests
    }

    /// Re-anchors `Origin::Local` threads whose file paths appear in
    /// `changed_paths` against current disk text, returning whether any thread
    /// changed.
    pub(super) fn reanchor_changed_local_threads(&mut self, changed_paths: &[String]) -> bool {
        let changed_set: BTreeSet<&str> = changed_paths.iter().map(String::as_str).collect();
        let mut loaded_texts: BTreeMap<String, LoadedDiskText> = BTreeMap::new();
        let mut did_reanchor = false;
        for thread in &mut self.threads {
            if thread.origin != Origin::Local {
                continue;
            }
            let Some(path) = thread.anchor.file.as_deref() else {
                continue;
            };
            if !changed_set.contains(path) {
                continue;
            }
            if !loaded_texts.contains_key(path) {
                let loaded = match self.ports.workspace.file_on_disk(path) {
                    Ok(Some(bytes)) => {
                        bytes_to_utf8_text(bytes).map_or(LoadedDiskText::Skip, LoadedDiskText::Utf8)
                    }
                    Ok(None) => LoadedDiskText::Utf8(String::new()),
                    Err(_) => LoadedDiskText::Skip,
                };
                loaded_texts.insert(path.to_owned(), loaded);
            }
            if let Some(LoadedDiskText::Utf8(content)) = loaded_texts.get(path)
                && reanchor_thread_in_text(thread, content)
            {
                did_reanchor = true;
            }
        }
        did_reanchor
    }
}

fn bytes_to_utf8_text(bytes: Vec<u8>) -> Option<String> {
    if bytes.len() > super::diffs::MAX_DIFF_BYTES {
        return None;
    }
    FileText::from_bytes(Some(bytes))
        .as_text()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests;
