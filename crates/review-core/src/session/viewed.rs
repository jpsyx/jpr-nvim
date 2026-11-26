//! Marking files viewed, and the queue of marks the forge has not accepted.

use std::collections::HashSet;

use anyhow::{Result, bail};
use review_model::{Event, SessionView};

use super::ReviewSession;
use crate::viewed::viewed_flag_to_state;

impl ReviewSession {
    /// Marks `path` viewed (`true`) or unviewed (`false`), here and on the
    /// forge. Local-only worktree files update `local_viewed` in `local.json`
    /// without calling or queueing on the forge.
    pub fn set_viewed(&mut self, path: &str, viewed: bool) -> Result<SessionView> {
        self.set_viewed_paths(&[path.to_owned()], viewed)
    }

    /// Marks every path in `paths` viewed (`true`) or unviewed (`false`)
    /// atomically: validates every path before mutating state, batches linked
    /// PR files needing remote sync into one [`Forge::set_viewed_many`] call,
    /// updates local-only files in `local.json`, saves once, and emits a single
    /// [`Event::ViewedChanged`].
    pub fn set_viewed_paths(&mut self, paths: &[String], viewed: bool) -> Result<SessionView> {
        let unique_paths = deduplicate_paths(paths)?;
        let (linked_paths, local_paths) = self.classify_viewed_paths(&unique_paths)?;
        let auth_message = self.apply_linked_viewed_paths(&linked_paths, viewed)?;
        self.apply_local_viewed_paths(&local_paths, viewed);
        let view = self.save_and_announce_viewed()?;
        if let Some(message) = auth_message {
            self.publish(&Event::SyncFailed {
                message,
                auth_required: true,
                is_background: false,
            });
        }
        Ok(view)
    }

    fn classify_viewed_paths(&self, paths: &[String]) -> Result<(Vec<String>, Vec<String>)> {
        let is_linked = self.is_linked();
        if is_linked {
            self.synced_pr()?;
        }
        let mut linked_paths = Vec::new();
        let mut local_paths = Vec::new();
        for path in paths {
            if is_linked && self.saved.files.iter().any(|file| file.path == *path) {
                linked_paths.push(path.clone());
            } else if self.local_files.iter().any(|file| file.path == *path) {
                local_paths.push(path.clone());
            } else {
                bail!("{path} is not a file changed in this review");
            }
        }
        Ok((linked_paths, local_paths))
    }

    fn apply_linked_viewed_paths(
        &mut self,
        linked_paths: &[String],
        viewed: bool,
    ) -> Result<Option<String>> {
        if linked_paths.is_empty() {
            return Ok(None);
        }
        let pr = self.synced_pr()?.clone();
        let target_state = viewed_flag_to_state(viewed);
        let mut forge_paths = Vec::new();
        for path in linked_paths {
            if let Some(file) = self.saved.files.iter_mut().find(|file| file.path == *path) {
                let needs_remote = file.viewed != target_state
                    || self.saved.registry.queued_viewed.contains_key(path);
                file.viewed = target_state;
                if needs_remote {
                    forge_paths.push(path.clone());
                }
            }
        }
        if forge_paths.is_empty() {
            return Ok(None);
        }
        let queue = &mut self.saved.registry.queued_viewed;
        match self.ports.forge.set_viewed_many(&pr, &forge_paths, viewed) {
            Ok(()) => {
                for path in &forge_paths {
                    queue.remove(path);
                }
                Ok(None)
            }
            Err(error) => {
                for path in &forge_paths {
                    queue.insert(path.clone(), viewed);
                }
                Ok(crate::is_auth_error(&error).then(|| format!("{error:#}")))
            }
        }
    }

    fn apply_local_viewed_paths(&mut self, local_paths: &[String], viewed: bool) {
        let target_state = viewed_flag_to_state(viewed);
        for path in local_paths {
            if let Some(local_file) = self.local_files.iter_mut().find(|file| file.path == *path) {
                local_file.viewed = target_state;
                self.saved
                    .local
                    .local_viewed
                    .insert(path.clone(), target_state);
            }
        }
    }

    /// Whether any viewed mark or comment operation is waiting for the forge,
    /// so a server knows to retry before the next sync.
    #[must_use]
    pub fn has_queued(&self) -> bool {
        !self.saved.registry.queued_viewed.is_empty() || !self.saved.registry.queued_ops.is_empty()
    }

    /// Sends the queued viewed marks and comment operations again, saving and
    /// announcing whichever progressed. Returns whether anything changed.
    pub fn flush_queued(&mut self) -> Result<bool> {
        self.flush_queued_with_background(false)
    }

    /// Background poller variant of [`Self::flush_queued`], marking any
    /// resulting auth [`Event::SyncFailed`] with `is_background = true`.
    pub fn flush_queued_background(&mut self) -> Result<bool> {
        self.flush_queued_with_background(true)
    }

    fn flush_queued_with_background(&mut self, is_background: bool) -> Result<bool> {
        let (has_viewed_landed, viewed_auth_error) = self.send_queued();
        let (has_comments_progressed, comments_auth_error) = if viewed_auth_error.is_some() {
            (false, None)
        } else {
            self.send_queued_comments()
        };
        if has_comments_progressed {
            self.save_and_announce_threads()?;
        }
        if has_viewed_landed {
            self.save_and_announce_viewed()?;
        }
        if let Some(message) = viewed_auth_error.or(comments_auth_error) {
            self.publish(&Event::SyncFailed {
                message,
                auth_required: true,
                is_background,
            });
        }
        Ok(has_viewed_landed || has_comments_progressed)
    }

    /// Sends the queued marks in path order until one fails, dropping each
    /// one that lands, and returns `(has_landed, auth_error_message)`. It
    /// stops at the first failure because the rest would fail the same way.
    pub(super) fn send_queued(&mut self) -> (bool, Option<String>) {
        let Some(pr) = self.saved.session.pr.clone() else {
            return (false, None);
        };
        let mut has_landed = false;
        let mut auth_error = None;
        for (path, viewed) in self.saved.registry.queued_viewed.clone() {
            if let Err(error) = self.ports.forge.set_viewed(&pr, &path, viewed) {
                if crate::is_auth_error(&error) {
                    auth_error = Some(format!("{error:#}"));
                }
                break;
            }
            self.saved.registry.queued_viewed.remove(&path);
            has_landed = true;
        }
        (has_landed, auth_error)
    }

    /// Saves the session and announces the viewed state as it now stands.
    pub(super) fn save_and_announce_viewed(&mut self) -> Result<SessionView> {
        self.ports.store.save(&self.saved)?;
        let view = self.view();
        self.publish(&Event::ViewedChanged {
            view: Box::new(view.clone()),
        });
        Ok(view)
    }
}

fn deduplicate_paths(paths: &[String]) -> Result<Vec<String>> {
    if paths.is_empty() {
        bail!("expected at least one file path");
    }
    let mut seen = HashSet::with_capacity(paths.len());
    let mut unique = Vec::with_capacity(paths.len());
    for path in paths {
        if seen.insert(path.as_str()) {
            unique.push(path.clone());
        }
    }
    Ok(unique)
}

#[cfg(test)]
mod tests {
    use review_model::{Event, ViewedState};

    use super::super::test_support::{Fakes, create_snapshot};
    use crate::ports::ReviewStore;

    #[test]
    fn marking_a_file_viewed_reaches_the_forge_and_is_announced() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();
        let view = session.set_viewed("src/b.rs", true).unwrap();
        assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), true)]);
        assert_eq!(view.files[1].viewed, ViewedState::Viewed);
        assert_eq!(view.viewed_count, 2);
        assert_eq!(fakes.store.saved().files[1].viewed, ViewedState::Viewed);
        assert_eq!(
            events.try_recv().unwrap(),
            Event::ViewedChanged {
                view: Box::new(view)
            }
        );
    }

    #[test]
    fn a_dismissed_file_marked_viewed_counts_as_viewed() {
        let fakes = Fakes::new(100);
        let mut changed = create_snapshot();
        changed.files[1].viewed = ViewedState::Dismissed;
        fakes.forge.set_snapshot(changed);
        let mut session = fakes.open_synced();
        assert_eq!(
            session.set_viewed("src/b.rs", true).unwrap().viewed_count,
            2
        );
    }

    #[test]
    fn a_mark_the_forge_refuses_stands_here_and_is_queued() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        let view = session.set_viewed("src/a.rs", false).unwrap();
        assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
        assert_eq!(view.queued_count, 1);
        assert!(session.has_queued());
        assert_eq!(
            fakes.store.saved().registry.queued_viewed.get("src/a.rs"),
            Some(&false)
        );
    }

    #[test]
    fn a_queued_mark_survives_a_pull_until_it_lands() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        let view = session.sync().unwrap();
        assert_eq!(
            view.files[0].viewed,
            ViewedState::Unviewed,
            "the forge still says viewed, but the queued mark wins"
        );
        fakes.forge.fail_writes_with(None);
        let view = session.sync().unwrap();
        assert_eq!(fakes.forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
        assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
        assert_eq!(view.queued_count, 0);
    }

    #[test]
    fn a_direct_mark_that_lands_replaces_the_queued_one() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/b.rs", true).unwrap();
        fakes.forge.fail_writes_with(None);
        let view = session.set_viewed("src/b.rs", false).unwrap();
        assert_eq!(view.queued_count, 0);
        assert_eq!(view.files[1].viewed, ViewedState::Unviewed);
        assert!(!session.has_queued());
        assert!(fakes.store.saved().registry.queued_viewed.is_empty());
        assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), false)]);
    }

    #[test]
    fn a_flush_announces_only_when_a_mark_landed() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        let events = session.subscribe();
        assert!(!session.flush_queued().unwrap(), "still offline");
        assert!(events.try_recv().is_err());
        fakes.forge.fail_writes_with(None);
        assert!(session.flush_queued().unwrap());
        assert!(!session.has_queued());
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ViewedChanged { .. }
        ));
    }

    #[test]
    fn only_changed_files_can_be_marked() {
        let mut session = Fakes::new(100).open_synced();
        assert!(session.set_viewed("nope.rs", true).is_err());
    }

    #[test]
    fn marking_waits_for_the_first_sync() {
        assert!(Fakes::new(1).open().set_viewed("src/a.rs", true).is_err());
    }

    #[test]
    fn a_pull_drops_queued_marks_for_files_the_pull_request_no_longer_changes() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        session.set_viewed("src/b.rs", true).unwrap();
        // A force-push takes src/a.rs out of the pull request, so a mark for
        // it can never land and must not hold up the marks queued after it.
        let mut pushed = create_snapshot();
        pushed.files.remove(0);
        fakes.forge.set_snapshot(pushed);
        let view = session.sync().unwrap();
        assert_eq!(view.queued_count, 1);
        assert_eq!(
            fakes
                .store
                .saved()
                .registry
                .queued_viewed
                .keys()
                .collect::<Vec<_>>(),
            ["src/b.rs"]
        );
        fakes.forge.fail_writes_with(None);
        assert!(session.flush_queued().unwrap());
        assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), true)]);
    }

    #[test]
    fn a_reopened_session_applies_the_marks_still_queued() {
        let fakes = Fakes::new(100);
        fakes.open_synced();
        // `github.json` is written before `viewed.json`, so a crash between
        // them leaves a queued mark the saved files do not show yet.
        let mut saved = fakes.store.saved();
        saved
            .registry
            .queued_viewed
            .insert("src/a.rs".to_owned(), false);
        fakes.store.save(&saved).unwrap();
        let view = fakes.open().view();
        assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
        assert_eq!(view.queued_count, 1);
    }

    #[test]
    fn batched_viewed_skips_unchanged_remote_files_and_emits_one_event() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();
        let view = session
            .set_viewed_paths(&["src/a.rs".to_owned(), "src/b.rs".to_owned()], true)
            .unwrap();
        assert_eq!(
            fakes.forge.viewed_batch_calls(),
            [(vec!["src/b.rs".to_owned()], true)]
        );
        assert_eq!(view.viewed_count, 2);
        assert_eq!(
            events.try_recv().unwrap(),
            Event::ViewedChanged {
                view: Box::new(view)
            }
        );
        assert!(events.try_recv().is_err(), "only one ViewedChanged event");
    }

    #[test]
    fn batched_viewed_handles_mixed_linked_and_local_only_files_in_one_save() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/local_new.rs", "fn local() {}\n");
        let mut session = fakes.open_synced();
        session.refresh_worktree(&[]).unwrap();
        let events = session.subscribe();
        let view = session
            .set_viewed_paths(&["src/b.rs".to_owned(), "src/local_new.rs".to_owned()], true)
            .unwrap();
        assert_eq!(
            fakes.forge.viewed_batch_calls(),
            [(vec!["src/b.rs".to_owned()], true)]
        );
        assert_eq!(view.viewed_count, 3);
        assert_eq!(
            fakes
                .store
                .saved()
                .local
                .local_viewed
                .get("src/local_new.rs"),
            Some(&ViewedState::Viewed)
        );
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ViewedChanged { .. }
        ));
        assert!(events.try_recv().is_err(), "only one ViewedChanged event");
    }

    #[test]
    fn batched_viewed_validates_atomically_and_rejects_empty_or_unknown_paths() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        assert!(session.set_viewed_paths(&[], true).is_err());
        assert!(
            session
                .set_viewed_paths(&["src/b.rs".to_owned(), "nope.rs".to_owned()], true)
                .is_err()
        );
        assert_eq!(fakes.forge.viewed_batch_calls(), Vec::new());
        assert_eq!(session.view().files[1].viewed, ViewedState::Unviewed);
    }

    #[test]
    fn batched_viewed_deduplicates_queues_failures_and_emits_one_auth_event() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_auth_with(Some("gh auth login required"));
        let events = session.subscribe();
        let view = session
            .set_viewed_paths(
                &[
                    "src/a.rs".to_owned(),
                    "src/a.rs".to_owned(),
                    "src/b.rs".to_owned(),
                ],
                false,
            )
            .unwrap();
        assert_eq!(view.viewed_count, 0);
        assert_eq!(view.queued_count, 1);
        assert_eq!(
            fakes.store.saved().registry.queued_viewed.get("src/a.rs"),
            Some(&false)
        );
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ViewedChanged { .. }
        ));
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::SyncFailed {
                auth_required: true,
                is_background: false,
                ..
            }
        ));
        assert!(events.try_recv().is_err());
    }
}
