//! Contract tests every adapter of a port must pass. Call them from the
//! adapter's own tests with a fresh, empty instance.

use std::collections::BTreeMap;

use review_model::{
    Anchor, MentionCandidate, Message, MessageSync, Origin, ReviewEvent, Thread, ThreadState,
    ViewedState,
};

use crate::fakes::{changed_file, sample_pr};
use crate::ports::{QueuedCommentOp, ReviewStore, SessionRecord, StoreSnapshot, SyncRegistry};

fn create_sample_registry() -> SyncRegistry {
    SyncRegistry {
        queued_viewed: BTreeMap::from([("src/b.rs".to_owned(), true)]),
        pending_review_id: Some("PRR_1".into()),
        viewer_login: Some("alice".into()),
        next_temp_id: 2,
        id_map: BTreeMap::from([("tmp-t-1".to_owned(), "PRRT_real".to_owned())]),
        agreed_bodies: BTreeMap::from([("IC_1".to_owned(), "original".to_owned())]),
        threads: vec![Thread {
            id: "tmp-t-1".into(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 3),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "tmp-m-1",
                "alice",
                "nit",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Queued),
            )],
        }],
        queued_ops: vec![QueuedCommentOp::SubmitReview {
            event: ReviewEvent::Comment,
            body: "looks close".into(),
        }],
        mention_candidates: vec![MentionCandidate {
            login: "bob".into(),
            is_participant: true,
        }],
    }
}

fn create_sample_snapshot() -> StoreSnapshot {
    StoreSnapshot {
        session: SessionRecord {
            pid: Some(42),
            worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
            pr: Some(sample_pr()),
            last_synced_at: Some(100),
        },
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Dismissed),
        ],
        registry: create_sample_registry(),
    }
}

/// Checks a [`ReviewStore`] that starts empty.
///
/// It must load as the default snapshot, round-trip a save, and let a later
/// save replace the earlier one. Call it from each adapter's tests, for example
/// with a file store in a fresh temporary directory.
pub fn check_review_store(store: &dyn ReviewStore) {
    assert_eq!(
        store.load().expect("an empty store loads"),
        StoreSnapshot::default(),
        "an empty store loads as the default snapshot"
    );
    let first = create_sample_snapshot();
    store.save(&first).expect("saving works");
    assert_eq!(
        store.load().expect("loads after a save"),
        first,
        "a save round-trips"
    );
    let second = StoreSnapshot {
        files: vec![changed_file("src/c.rs", ViewedState::Unviewed)],
        registry: SyncRegistry::default(),
        ..first
    };
    store.save(&second).expect("saving again works");
    assert_eq!(
        store.load().expect("loads after a second save"),
        second,
        "a later save replaces the earlier one"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::MemoryStore;

    #[test]
    fn the_memory_store_passes_the_contract() {
        check_review_store(&MemoryStore::default());
    }
}
