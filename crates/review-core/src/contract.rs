//! Contract tests every adapter of a port must pass. Call them from the
//! adapter's own tests with a fresh, empty instance.

use review_model::ViewedState;

use crate::fakes::{changed_file, sample_pr};
use crate::ports::{ReviewStore, SessionRecord, StoreSnapshot};

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
    let first = StoreSnapshot {
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
    };
    store.save(&first).expect("saving works");
    assert_eq!(
        store.load().expect("loads after a save"),
        first,
        "a save round-trips"
    );
    let second = StoreSnapshot {
        files: vec![changed_file("src/c.rs", ViewedState::Unviewed)],
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
