//! Pure remote-change delta computation for GitHub syncs, filtering out
//! actions originated locally by the reviewer.

use std::collections::BTreeMap;

use review_model::{ChangedFile, Origin, SyncDelta, Thread, ThreadState, ViewedState};

/// Minimal pre- or post-sync state required to compute an external [`SyncDelta`].
#[derive(Debug, Clone)]
pub(crate) struct SyncComparisonSnapshot {
    pub(crate) had_pr: bool,
    pub(crate) head_sha: Option<String>,
    pub(crate) files: Vec<ChangedFile>,
    pub(crate) threads: Vec<Thread>,
}

/// Computes external remote changes between `before` and `after`, excluding
/// locally originated actions (own comments mapped via `id_map`, own viewed
/// marks, and own pushes).
pub(crate) fn compute_sync_delta(
    before: &SyncComparisonSnapshot,
    after: &SyncComparisonSnapshot,
    id_map: &BTreeMap<String, String>,
    was_own_push: bool,
) -> Option<SyncDelta> {
    if !before.had_pr {
        return None;
    }
    let head_moved = !was_own_push && before.head_sha != after.head_sha;
    let files_changed = if was_own_push {
        0
    } else {
        count_remote_file_changes(&before.files, &after.files)
    };
    let (new_comments, updated_comments, resolved_threads, reopened_threads) =
        count_thread_and_comment_deltas(&before.threads, &after.threads, id_map);
    let delta = SyncDelta {
        files_changed,
        new_comments,
        updated_comments,
        resolved_threads,
        reopened_threads,
        head_moved,
    };
    (!delta.is_empty()).then_some(delta)
}

fn count_remote_file_changes(before_files: &[ChangedFile], after_files: &[ChangedFile]) -> usize {
    let before_by_path: BTreeMap<&str, &ChangedFile> = before_files
        .iter()
        .map(|file| (file.path.as_str(), file))
        .collect();
    let after_by_path: BTreeMap<&str, &ChangedFile> = after_files
        .iter()
        .map(|file| (file.path.as_str(), file))
        .collect();

    let mut changed_count = 0;
    for (path, after_file) in &after_by_path {
        match before_by_path.get(path) {
            None => changed_count += 1,
            Some(before_file) => {
                let stats_changed = before_file.additions != after_file.additions
                    || before_file.deletions != after_file.deletions;
                let was_dismissed = before_file.viewed == ViewedState::Viewed
                    && after_file.viewed == ViewedState::Dismissed;
                if stats_changed || was_dismissed {
                    changed_count += 1;
                }
            }
        }
    }
    for path in before_by_path.keys() {
        if !after_by_path.contains_key(path) {
            changed_count += 1;
        }
    }
    changed_count
}

fn canonicalize_id<'a>(id: &'a str, id_map: &'a BTreeMap<String, String>) -> &'a str {
    let mut current = id;
    for _ in 0..8 {
        let Some(next_id) = id_map.get(current) else {
            break;
        };
        if next_id == current {
            break;
        }
        current = next_id.as_str();
    }
    current
}

fn build_before_github_maps<'a>(
    before_threads: &'a [Thread],
    id_map: &'a BTreeMap<String, String>,
) -> (BTreeMap<&'a str, ThreadState>, BTreeMap<&'a str, &'a str>) {
    let mut thread_states = BTreeMap::new();
    let mut message_bodies = BTreeMap::new();
    for thread in before_threads {
        if thread.origin != Origin::Github {
            continue;
        }
        let canonical_thread_id = canonicalize_id(&thread.id, id_map);
        thread_states.insert(thread.id.as_str(), thread.state);
        thread_states.insert(canonical_thread_id, thread.state);
        for message in &thread.messages {
            let canonical_message_id = canonicalize_id(&message.id, id_map);
            message_bodies.insert(message.id.as_str(), message.body.as_str());
            message_bodies.insert(canonical_message_id, message.body.as_str());
        }
    }
    (thread_states, message_bodies)
}

fn count_thread_and_comment_deltas(
    before_threads: &[Thread],
    after_threads: &[Thread],
    id_map: &BTreeMap<String, String>,
) -> (usize, usize, usize, usize) {
    let (before_thread_states, before_message_bodies) =
        build_before_github_maps(before_threads, id_map);
    let mut new_comments = 0;
    let mut updated_comments = 0;
    let mut resolved_threads = 0;
    let mut reopened_threads = 0;

    for thread in after_threads {
        if thread.origin != Origin::Github {
            continue;
        }
        let canonical_thread_id = canonicalize_id(&thread.id, id_map);
        if let Some(previous_state) = before_thread_states
            .get(canonical_thread_id)
            .or_else(|| before_thread_states.get(thread.id.as_str()))
        {
            match (*previous_state, thread.state) {
                (ThreadState::Open, ThreadState::Resolved) => resolved_threads += 1,
                (ThreadState::Resolved, ThreadState::Open) => reopened_threads += 1,
                _ => {}
            }
        }
        for message in &thread.messages {
            let canonical_message_id = canonicalize_id(&message.id, id_map);
            let previous_body = before_message_bodies
                .get(canonical_message_id)
                .or_else(|| before_message_bodies.get(message.id.as_str()));
            match previous_body {
                None => new_comments += 1,
                Some(old_body) if *old_body != message.body.as_str() => updated_comments += 1,
                Some(_) => {}
            }
        }
    }
    (
        new_comments,
        updated_comments,
        resolved_threads,
        reopened_threads,
    )
}

#[cfg(test)]
mod tests {
    use review_model::{Anchor, Message, MessageSync};

    use super::*;

    fn file(path: &str, additions: u64, deletions: u64, viewed: ViewedState) -> ChangedFile {
        ChangedFile {
            path: path.to_owned(),
            additions,
            deletions,
            viewed,
        }
    }

    fn message(id: &str, body: &str, viewer_did_author: bool) -> Message {
        Message {
            id: id.to_owned(),
            author: if viewer_did_author { "me" } else { "alice" }.to_owned(),
            body: body.to_owned(),
            created: "2026-11-27T00:00:00Z".to_owned(),
            updated: "2026-11-27T00:00:00Z".to_owned(),
            sync: Some(MessageSync::Published),
            viewer_did_author,
            database_id: None,
            sync_error: None,
            recoverable_body: None,
            reactions: Vec::new(),
        }
    }

    fn github_thread(id: &str, state: ThreadState, messages: Vec<Message>) -> Thread {
        Thread {
            id: id.to_owned(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 1),
            state,
            outdated: false,
            messages,
            agent: None,
            promoted_to: None,
        }
    }

    fn local_thread(id: &str, messages: Vec<Message>) -> Thread {
        Thread {
            id: id.to_owned(),
            origin: Origin::Local,
            anchor: Anchor::line("src/a.rs", 1),
            state: ThreadState::Open,
            outdated: false,
            messages,
            agent: None,
            promoted_to: None,
        }
    }

    #[test]
    fn returns_none_on_initial_sync() {
        let before = SyncComparisonSnapshot {
            had_pr: false,
            head_sha: None,
            files: Vec::new(),
            threads: Vec::new(),
        };
        let after = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("abc123".into()),
            files: vec![file("src/a.rs", 5, 1, ViewedState::Unviewed)],
            threads: vec![github_thread(
                "PRRT_1",
                ThreadState::Open,
                vec![message("PRRC_1", "hello", false)],
            )],
        };
        assert_eq!(
            compute_sync_delta(&before, &after, &BTreeMap::new(), false),
            None
        );
    }

    #[test]
    fn returns_none_when_nothing_changed() {
        let snapshot = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("abc123".into()),
            files: vec![file("src/a.rs", 5, 1, ViewedState::Viewed)],
            threads: vec![github_thread(
                "PRRT_1",
                ThreadState::Open,
                vec![message("PRRC_1", "hello", false)],
            )],
        };
        assert_eq!(
            compute_sync_delta(&snapshot, &snapshot, &BTreeMap::new(), false),
            None
        );
    }

    #[test]
    fn counts_added_removed_edited_and_dismissed_files_but_not_own_viewed() {
        let before = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: vec![
                file("src/removed.rs", 1, 0, ViewedState::Unviewed),
                file("src/edited.rs", 2, 1, ViewedState::Unviewed),
                file("src/dismissed.rs", 4, 0, ViewedState::Viewed),
                file("src/marked_viewed.rs", 1, 1, ViewedState::Unviewed),
            ],
            threads: Vec::new(),
        };
        let after = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha2".into()),
            files: vec![
                file("src/added.rs", 3, 0, ViewedState::Unviewed),
                file("src/edited.rs", 5, 1, ViewedState::Unviewed),
                file("src/dismissed.rs", 4, 0, ViewedState::Dismissed),
                file("src/marked_viewed.rs", 1, 1, ViewedState::Viewed),
            ],
            threads: Vec::new(),
        };
        let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), false)
            .expect("delta should be present");
        assert_eq!(delta.files_changed, 4);
        assert!(delta.head_moved);
    }

    #[test]
    fn ignores_file_and_head_changes_for_own_push_while_keeping_external_comments() {
        let before = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: vec![file("src/a.rs", 1, 0, ViewedState::Viewed)],
            threads: Vec::new(),
        };
        let after = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha2".into()),
            files: vec![
                file("src/a.rs", 10, 0, ViewedState::Dismissed),
                file("src/b.rs", 2, 0, ViewedState::Unviewed),
            ],
            threads: vec![github_thread(
                "PRRT_1",
                ThreadState::Open,
                vec![message("PRRC_1", "nice push", false)],
            )],
        };
        let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), true)
            .expect("external comment should still be reported");
        assert_eq!(delta.files_changed, 0);
        assert!(!delta.head_moved);
        assert_eq!(delta.new_comments, 1);
    }

    #[test]
    fn filters_out_own_optimistic_and_mapped_comments_via_id_map() {
        let before = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: Vec::new(),
            threads: vec![github_thread(
                "tmp-t-1",
                ThreadState::Open,
                vec![message("tmp-m-1", "my queued comment", true)],
            )],
        };
        let after = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: Vec::new(),
            threads: vec![github_thread(
                "PRRT_99",
                ThreadState::Open,
                vec![
                    message("PRRC_99", "my queued comment", true),
                    message("PRRC_100", "external reply", false),
                ],
            )],
        };
        let id_map = BTreeMap::from([
            ("tmp-t-1".to_owned(), "PRRT_99".to_owned()),
            ("tmp-m-1".to_owned(), "PRRC_99".to_owned()),
        ]);
        let delta =
            compute_sync_delta(&before, &after, &id_map, false).expect("external reply exists");
        assert_eq!(delta.new_comments, 1);
        assert_eq!(delta.updated_comments, 0);
    }

    #[test]
    fn counts_updated_comments_and_thread_state_transitions_for_github_threads_only() {
        let before = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: Vec::new(),
            threads: vec![
                github_thread(
                    "PRRT_1",
                    ThreadState::Open,
                    vec![message("PRRC_1", "old body", false)],
                ),
                github_thread(
                    "PRRT_2",
                    ThreadState::Resolved,
                    vec![message("PRRC_2", "resolved body", false)],
                ),
                local_thread("loc-1", vec![message("loc-m-1", "local", true)]),
            ],
        };
        let after = SyncComparisonSnapshot {
            had_pr: true,
            head_sha: Some("sha1".into()),
            files: Vec::new(),
            threads: vec![
                github_thread(
                    "PRRT_1",
                    ThreadState::Resolved,
                    vec![message("PRRC_1", "edited body", false)],
                ),
                github_thread(
                    "PRRT_2",
                    ThreadState::Open,
                    vec![message("PRRC_2", "resolved body", false)],
                ),
                local_thread(
                    "loc-1",
                    vec![
                        message("loc-m-1", "local", true),
                        message("loc-m-2", "agent reply", false),
                    ],
                ),
            ],
        };
        let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), false)
            .expect("delta should be present");
        assert_eq!(delta.new_comments, 0);
        assert_eq!(delta.updated_comments, 1);
        assert_eq!(delta.resolved_threads, 1);
        assert_eq!(delta.reopened_threads, 1);
    }
}
