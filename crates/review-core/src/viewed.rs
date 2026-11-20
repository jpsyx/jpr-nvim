//! The viewed rules: what a mark means, and how a queued mark wins over a
//! pull.

use std::collections::BTreeMap;

use review_model::{ChangedFile, ViewedState};

/// The state a file is in once marked viewed (`true`) or unviewed (`false`).
#[must_use]
pub const fn viewed_flag_to_state(viewed: bool) -> ViewedState {
    if viewed {
        ViewedState::Viewed
    } else {
        ViewedState::Unviewed
    }
}

/// Applies the marks still queued for the forge to `files`, whether just
/// pulled from the forge or read back from the store, so neither a pull
/// taken before a mark lands nor a file saved behind the queue undoes it.
pub fn apply_queued(files: &mut [ChangedFile], queued: &BTreeMap<String, bool>) {
    for file in files {
        if let Some(viewed) = queued.get(&file.path) {
            file.viewed = viewed_flag_to_state(*viewed);
        }
    }
}

/// Drops the queued marks for paths `files` no longer has. After a force-push
/// or a rename the forge refuses such a mark every time, and since sending
/// stops at the first refusal, it would hold up every mark queued after it.
pub fn drop_stale_marks(queued: &mut BTreeMap<String, bool>, files: &[ChangedFile]) {
    queued.retain(|path, _| files.iter().any(|file| file.path == *path));
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use review_model::ViewedState;

    use super::*;
    use crate::fakes::changed_file;

    #[test]
    fn a_mark_is_viewed_or_unviewed() {
        assert_eq!(viewed_flag_to_state(true), ViewedState::Viewed);
        assert_eq!(viewed_flag_to_state(false), ViewedState::Unviewed);
    }

    #[test]
    fn a_queued_mark_wins_over_the_pulled_state() {
        let mut files = vec![
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Dismissed),
            changed_file("c.rs", ViewedState::Viewed),
        ];
        let queued = BTreeMap::from([("a.rs".to_owned(), false), ("b.rs".to_owned(), true)]);
        apply_queued(&mut files, &queued);
        let states: Vec<ViewedState> = files.iter().map(|file| file.viewed).collect();
        assert_eq!(
            states,
            [
                ViewedState::Unviewed,
                ViewedState::Viewed,
                ViewedState::Viewed
            ]
        );
    }

    #[test]
    fn a_queued_mark_for_a_file_no_longer_changed_is_dropped() {
        let files = [changed_file("b.rs", ViewedState::Unviewed)];
        let mut queued = BTreeMap::from([("a.rs".to_owned(), false), ("b.rs".to_owned(), true)]);
        drop_stale_marks(&mut queued, &files);
        assert_eq!(queued, BTreeMap::from([("b.rs".to_owned(), true)]));
    }
}
