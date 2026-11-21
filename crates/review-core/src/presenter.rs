//! Builds the read models frontends draw. Pure functions only.

use review_model::{
    AnchorKind, ChangedFile, FileRow, MessageSync, PullRequest, SessionView, SyncState, Thread,
    ViewedState,
};

use crate::comments::count_code_threads;
use crate::tree::create_file_tree_from_paths;

/// The session's status view: the pull request, its files with viewed state
/// and thread counts, how many viewed marks wait for the forge, and how the
/// last sync went.
#[must_use]
pub fn session_view(
    pr: Option<&PullRequest>,
    files: &[ChangedFile],
    threads: &[Thread],
    sync: &SyncState,
    queued_count: usize,
) -> SessionView {
    let rows = files
        .iter()
        .map(|file| FileRow {
            path: file.path.clone(),
            additions: file.additions,
            deletions: file.deletions,
            viewed: file.viewed,
            threads: threads
                .iter()
                .filter(|thread| thread.anchor.file.as_deref() == Some(file.path.as_str()))
                .count(),
        })
        .collect();
    SessionView {
        pr: pr.cloned(),
        files: rows,
        tree: create_file_tree_from_paths(files.iter().map(|file| file.path.as_str())),
        viewed_count: files
            .iter()
            .filter(|file| file.viewed == ViewedState::Viewed)
            .count(),
        thread_count: count_code_threads(threads),
        draft_count: threads
            .iter()
            .flat_map(|thread| &thread.messages)
            .filter(|message| message.sync == Some(MessageSync::Draft))
            .count(),
        conversation_count: threads
            .iter()
            .filter(|thread| thread.anchor.kind == AnchorKind::Pr)
            .count(),
        queued_count,
        sync: sync.clone(),
    }
}

#[cfg(test)]
mod tests {
    use review_model::{Anchor, Message, MessageSync, Origin, ThreadState};

    use super::*;
    use crate::fakes::{changed_file, github_thread, sample_pr};

    fn create_conversation_thread(id: &str) -> Thread {
        Thread {
            id: id.into(),
            origin: Origin::Github,
            anchor: Anchor::pr(),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                &format!("{id}-c1"),
                "alice",
                "overall lgtm",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Published),
            )],
        }
    }

    #[test]
    fn counts_threads_per_file_and_viewed_files() {
        let files = [
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Dismissed),
            changed_file("c.rs", ViewedState::Unviewed),
        ];
        let mut draft_thread = github_thread("T3", "c.rs");
        draft_thread.messages[0].sync = Some(MessageSync::Draft);
        let threads = [
            github_thread("T1", "a.rs"),
            github_thread("T2", "a.rs"),
            draft_thread,
            create_conversation_thread("IC_1"),
        ];
        let view = session_view(
            Some(&sample_pr()),
            &files,
            &threads,
            &SyncState::Synced { at: 5 },
            0,
        );
        let counts: Vec<(&str, usize)> = view
            .files
            .iter()
            .map(|row| (row.path.as_str(), row.threads))
            .collect();
        assert_eq!(counts, [("a.rs", 2), ("b.rs", 0), ("c.rs", 1)]);
        assert_eq!(view.viewed_count, 1, "a dismissed file is not viewed");
        assert_eq!(view.thread_count, 3);
        assert_eq!(view.conversation_count, 1);
        assert_eq!(view.draft_count, 1);
        assert_eq!(view.pr.map(|pr| pr.number), Some(7));
        assert_eq!(view.sync, SyncState::Synced { at: 5 });
    }

    #[test]
    fn keeps_the_forge_file_order() {
        let files = [
            changed_file("z.rs", ViewedState::Unviewed),
            changed_file("a.rs", ViewedState::Unviewed),
        ];
        let view = session_view(None, &files, &[], &SyncState::Never, 0);
        let paths: Vec<&str> = view.files.iter().map(|row| row.path.as_str()).collect();
        assert_eq!(paths, ["z.rs", "a.rs"]);
        assert!(view.pr.is_none());
    }
}
