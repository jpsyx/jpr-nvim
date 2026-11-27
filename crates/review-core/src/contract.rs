//! Contract tests every adapter of a port must pass. Call them from the
//! adapter's own tests with a fresh, empty instance.

use std::collections::{BTreeMap, BTreeSet};

use review_model::{
    AgentKind, AgentRound, AgentRoundKind, AgentThreadState, Anchor, MentionCandidate, Message,
    MessageSync, Origin, ReviewEvent, Thread, ThreadState, ViewedState,
};

use crate::fakes::{changed_file, sample_pr};
use crate::ports::{
    LocalStoreState, QueuedCommentOp, ReviewStore, SessionRecord, StoreSnapshot, SyncRegistry,
};

fn create_sample_local_thread() -> Thread {
    Thread {
        id: "loc-1".into(),
        origin: Origin::Local,
        anchor: Anchor::line("src/a.rs", 5),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "loc-m-1",
            "reviewer",
            "Check error handling",
            "2026-11-21T00:00:00Z",
            None,
        )],
        agent: Some(AgentThreadState::Unsent),
        promoted_to: None,
    }
}

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
            agent: None,
            promoted_to: None,
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
            socket: Some("/tmp/jpr.sock".into()),
            agent_session_id: Some("11111111-2222-3333-4444-555555555555".into()),
            agent_kind: Some(AgentKind::Codex),
        },
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Dismissed),
        ],
        registry: create_sample_registry(),
        local: LocalStoreState {
            next_local_id: 3,
            next_round: 2,
            threads: vec![create_sample_local_thread()],
            local_viewed: BTreeMap::from([("src/local.rs".to_owned(), ViewedState::Viewed)]),
            collapsed_dirs: BTreeSet::new(),
        },
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
        local: LocalStoreState::default(),
        ..first
    };
    store.save(&second).expect("saving again works");
    assert_eq!(
        store.load().expect("loads after a second save"),
        second,
        "a later save replaces the earlier one"
    );
    check_review_store_rounds(store);
}

/// Checks that a store with empty rounds persists and lists rounds cleanly across saves.
pub fn check_review_store_rounds(store: &dyn ReviewStore) {
    assert!(
        store.rounds().expect("empty store rounds load").is_empty(),
        "an empty store starts with no rounds"
    );
    let round_1 = AgentRound {
        round: 1,
        kind: AgentRoundKind::Send,
        thread_ids: vec!["loc-1".into()],
        prompt: "Address comment loc-1".into(),
        sent_at: 101,
    };
    let round_2 = AgentRound {
        round: 2,
        kind: AgentRoundKind::Prepass,
        thread_ids: Vec::new(),
        prompt: "Run prepass review".into(),
        sent_at: 102,
    };
    store.append_round(&round_1).expect("first round appends");
    store.append_round(&round_2).expect("second round appends");
    assert_eq!(
        store.rounds().expect("appended rounds load"),
        vec![round_1.clone(), round_2.clone()],
        "rounds stay in append order"
    );
    let second = StoreSnapshot {
        files: vec![changed_file("src/c.rs", ViewedState::Unviewed)],
        ..StoreSnapshot::default()
    };
    store.save(&second).expect("saving snapshot works");
    assert_eq!(
        store
            .rounds()
            .expect("rounds remain intact after saving snapshot"),
        vec![round_1, round_2],
        "snapshot saves do not drop appended rounds"
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

    #[test]
    fn memory_store_round_trips_agent_session_and_local_state() {
        let store = MemoryStore::default();
        let snapshot = StoreSnapshot {
            session: SessionRecord {
                socket: Some("/tmp/jpr.sock".into()),
                agent_session_id: Some("11111111-2222-3333-4444-555555555555".into()),
                agent_kind: Some(AgentKind::Codex),
                ..SessionRecord::default()
            },
            local: LocalStoreState {
                next_local_id: 3,
                next_round: 2,
                threads: vec![create_sample_local_thread()],
                local_viewed: BTreeMap::from([("src/local.rs".to_owned(), ViewedState::Viewed)]),
                collapsed_dirs: BTreeSet::new(),
            },
            ..StoreSnapshot::default()
        };
        store.save(&snapshot).expect("saving local state works");
        assert_eq!(store.load().expect("loading local state works"), snapshot);
    }
}
