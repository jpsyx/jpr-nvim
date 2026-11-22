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
            self.disk_digests = Some(current_digests);
            self.poll_worktree_status_change();
            return Ok(None);
        };
        let changed_paths = collect_changed_digest_paths(previous_digests, &current_digests);
        if changed_paths.is_empty() {
            self.poll_worktree_status_change();
            return Ok(None);
        }
        let did_reanchor = self.reanchor_changed_local_threads(&changed_paths);
        if did_reanchor {
            self.split_and_save_threads()?;
        }
        self.disk_digests = Some(current_digests);
        let view = self.view();
        self.last_worktree_status = Some(view.worktree_status.clone());
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

    fn poll_worktree_status_change(&mut self) {
        let Some(status) = self.read_worktree_status() else {
            return;
        };
        let should_publish = self
            .last_worktree_status
            .as_ref()
            .is_some_and(|previous| previous != &status);
        self.last_worktree_status = Some(status);
        if should_publish {
            let view = self.view();
            self.publish(&Event::WorktreeStatusChanged {
                view: Box::new(view),
            });
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
        if let Some(previous) = self.disk_digests.as_ref() {
            candidates.extend(previous.keys().cloned());
        }
        if self
            .saved
            .session
            .pr
            .as_ref()
            .is_some_and(|pr| !pr.base_sha.is_empty())
            && self.prepare_base().is_ok()
        {
            let merge_base = self.base_cache.merge_base.clone();
            if let Ok(changed) = self.ports.workspace.list_changed_files_since(&merge_base) {
                candidates.extend(changed);
            }
        }
        candidates
    }

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
                    if let Some(previous) = self
                        .disk_digests
                        .as_ref()
                        .and_then(|map| map.get(&path))
                        .copied()
                    {
                        digests.insert(path, previous);
                    }
                }
            }
        }
        digests
    }

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
mod tests {
    use review_model::{Anchor, Event, LocalAnchorUpdate, Origin};

    use super::super::test_support::Fakes;

    #[test]
    fn poll_worktree_files_emits_files_changed_and_reanchors_local_threads() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
            .unwrap();
        assert_eq!(thread.anchor.snapshot.as_deref(), Some("let x = 1;"));
        let events = session.subscribe();

        assert_eq!(session.poll_worktree_files().unwrap(), None);
        fakes
            .workspace
            .write_disk("src/a.rs", b"// h1\n// h2\nfn f() {}\nlet x = 1;\n");

        let changed = session.poll_worktree_files().unwrap();
        assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
        let saved_local = &fakes.store.saved().local.threads[0];
        assert_eq!(saved_local.anchor.start, Some(4));
        assert_eq!(saved_local.anchor.end, Some(4));
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::FilesChanged { paths, .. } if paths == vec!["src/a.rs"]
        ));
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ThreadsChanged { .. }
        ));
        assert_eq!(session.poll_worktree_files().unwrap(), None);
    }

    #[test]
    fn poll_worktree_files_marks_deleted_file_threads_outdated() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();
        session
            .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
            .unwrap();
        assert_eq!(session.poll_worktree_files().unwrap(), None);

        fakes.workspace.remove_disk("src/a.rs");
        let changed = session.poll_worktree_files().unwrap();
        assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
        assert!(session.threads().last().unwrap().outdated);
        assert!(fakes.store.saved().local.threads[0].outdated);
    }

    #[test]
    fn poll_worktree_files_continues_when_git_diff_or_single_file_read_fails() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        fakes.workspace.put_disk("src/b.rs", "let b = 1;\n");
        let mut session = fakes.open_synced();
        session
            .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
            .unwrap();
        assert_eq!(session.poll_worktree_files().unwrap(), None);

        fakes
            .workspace
            .fail_list_changed_with(Some("git status error"));
        fakes
            .workspace
            .fail_disk_read_with("src/b.rs", Some("permission denied"));
        fakes
            .workspace
            .write_disk("src/a.rs", b"// shifted\nfn f() {}\nlet x = 1;\n");

        let changed = session.poll_worktree_files().unwrap();
        assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
        let local = session.threads().last().unwrap();
        assert_eq!(local.anchor.start, Some(3));
        assert!(!local.outdated);
    }

    #[test]
    fn update_local_anchors_updates_line_bounds_and_refreshes_snapshot() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
            .unwrap();
        let events = session.subscribe();

        fakes
            .workspace
            .put_disk("src/a.rs", "// h1\nfn f() {}\nlet x = 2;\n");
        session
            .update_local_anchors(
                "src/a.rs",
                &[LocalAnchorUpdate {
                    thread_id: thread.id.clone(),
                    start: 3,
                    end: 3,
                }],
            )
            .unwrap();

        let updated = session
            .threads()
            .iter()
            .find(|item| item.id == thread.id)
            .unwrap();
        assert_eq!(updated.anchor.start, Some(3));
        assert_eq!(updated.anchor.end, Some(3));
        assert!(!updated.outdated);
        assert_eq!(updated.anchor.snapshot.as_deref(), Some("let x = 2;"));
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ThreadsChanged { .. }
        ));
    }

    #[test]
    fn update_local_anchors_handles_missing_and_binary_files() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 2), "Why?", Origin::Local)
            .unwrap();
        let update = LocalAnchorUpdate {
            thread_id: thread.id,
            start: 1,
            end: 1,
        };

        fakes.workspace.write_disk("src/a.rs", b"\x00\x01\x02");
        session
            .update_local_anchors("src/a.rs", std::slice::from_ref(&update))
            .unwrap();
        let binary_updated = session.threads().last().unwrap();
        assert_eq!(binary_updated.anchor.snapshot, None);
        assert!(!binary_updated.outdated);

        fakes.workspace.remove_disk("src/a.rs");
        session.update_local_anchors("src/a.rs", &[update]).unwrap();
        let missing_updated = session.threads().last().unwrap();
        assert_eq!(missing_updated.anchor.snapshot, None);
        assert!(missing_updated.outdated);
    }

    #[test]
    fn poll_worktree_files_emits_worktree_status_changed_when_git_status_changes_without_file_edits()
     {
        let fakes = Fakes::new(100);
        fakes.workspace.put_disk("src/a.rs", "fn f() {}\n");
        let mut session = fakes.open_synced();
        let events = session.subscribe();

        assert_eq!(session.poll_worktree_files().unwrap(), None);
        assert!(events.try_recv().is_err());

        fakes
            .workspace
            .set_worktree_status(Some(review_model::WorktreeStatus {
                is_dirty: false,
                ahead: 1,
                behind: 0,
                modified_paths: Vec::new(),
            }));
        assert_eq!(session.poll_worktree_files().unwrap(), None);
        match events.try_recv().unwrap() {
            Event::WorktreeStatusChanged { view } => {
                assert!(!view.worktree_status.is_dirty);
                assert_eq!(view.worktree_status.ahead, 1);
            }
            other => panic!("expected WorktreeStatusChanged, got {other:?}"),
        }

        assert_eq!(session.poll_worktree_files().unwrap(), None);
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn poll_worktree_files_does_not_repeat_status_after_files_changed_until_commit() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_at("abc123", "src/a.rs", "clean\n");
        fakes.workspace.put_disk("src/a.rs", "clean\n");
        let mut session = fakes.open_synced();
        assert_eq!(session.poll_worktree_files().unwrap(), None);
        let events = session.subscribe();

        fakes.workspace.put_disk("src/a.rs", "edited\n");
        assert_eq!(
            session.poll_worktree_files().unwrap(),
            Some(vec!["src/a.rs".to_owned()])
        );
        match events.try_recv().unwrap() {
            Event::FilesChanged { view, .. } => assert!(view.worktree_status.is_dirty),
            other => panic!("expected FilesChanged, got {other:?}"),
        }
        assert_eq!(session.poll_worktree_files().unwrap(), None);
        assert!(events.try_recv().is_err());

        fakes.workspace.set_head_commit("commit2");
        fakes.workspace.put_at("commit2", "src/a.rs", "edited\n");
        assert_eq!(session.poll_worktree_files().unwrap(), None);
        match events.try_recv().unwrap() {
            Event::WorktreeStatusChanged { view } => assert!(!view.worktree_status.is_dirty),
            other => panic!("expected WorktreeStatusChanged, got {other:?}"),
        }
    }
}
