//! Pure remote-change delta computation for GitHub syncs, filtering out
//! actions originated locally by the reviewer.

use std::collections::BTreeMap;

use review_model::{ChangedFile, Origin, SyncDelta, Thread, ThreadState, ViewedState};

/// Minimal pre- or post-sync state required to compute an external [`SyncDelta`].
#[derive(Debug, Clone)]
pub struct SyncComparisonSnapshot {
    pub had_pr: bool,
    pub head_sha: Option<String>,
    pub files: Vec<ChangedFile>,
    pub threads: Vec<Thread>,
}

/// Computes external remote changes between `before` and `after`, excluding
/// locally originated actions (own comments mapped via `id_map`, own viewed
/// marks, and own pushes).
pub fn compute_sync_delta(
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
mod tests;
