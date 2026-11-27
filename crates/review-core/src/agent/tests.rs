use review_model::{
    AgentThreadState, Anchor, Message, Origin, PullRequest, Side, Thread, ThreadState,
};

use super::*;
use crate::fakes::sample_pr;

fn create_local_thread(
    id: &str,
    anchor: Anchor,
    state: ThreadState,
    agent: AgentThreadState,
    messages: Vec<Message>,
) -> Thread {
    Thread {
        id: id.into(),
        origin: Origin::Local,
        anchor,
        state,
        outdated: false,
        messages,
        agent: Some(agent),
        promoted_to: None,
    }
}

fn create_message(author: &str, body: &str, viewer_did_author: bool) -> Message {
    let mut message = Message::create_with_sync("m", author, body, "2026-11-21T00:00:00Z", None);
    message.viewer_did_author = viewer_did_author;
    message
}

#[test]
fn selects_only_open_unsent_local_threads_ending_with_reviewer_message() {
    let eligible = create_local_thread(
        "loc-1",
        Anchor::line("src/a.rs", 7),
        ThreadState::Open,
        AgentThreadState::Unsent,
        vec![create_message("pablo", "Why clone here?", true)],
    );
    let answered = create_local_thread(
        "loc-2",
        Anchor::line("src/a.rs", 9),
        ThreadState::Open,
        AgentThreadState::Answered,
        vec![
            create_message("pablo", "Why?", true),
            create_message("agent", "Needed for Send.", false),
        ],
    );
    let resolved = create_local_thread(
        "loc-3",
        Anchor::line("src/a.rs", 12),
        ThreadState::Resolved,
        AgentThreadState::Unsent,
        vec![create_message("pablo", "Skip", true)],
    );
    let threads = vec![eligible, answered, resolved];
    let selected = select_dispatchable_threads(&threads, None);
    assert_eq!(selected.len(), 1);
    assert_eq!(selected[0].id, "loc-1");

    let targeted = select_dispatchable_threads(&threads, Some("loc-2"));
    assert_eq!(targeted.len(), 1);
    assert_eq!(targeted[0].id, "loc-2");
}

#[test]
fn formats_anchor_labels_for_all_kinds_and_sides() {
    assert_eq!(
        build_anchor_label_from_anchor(&Anchor::line("src/a.rs", 7)),
        "src/a.rs:L7"
    );
    assert_eq!(
        build_anchor_label_from_anchor(&Anchor::side_line("src/a.rs", Side::Left, 4)),
        "src/a.rs:L4 (base)"
    );
    assert_eq!(
        build_anchor_label_from_anchor(&Anchor::range("src/a.rs", Side::Right, 7, 9)),
        "src/a.rs:L7-9"
    );
    assert_eq!(
        build_anchor_label_from_anchor(&Anchor::file("src/a.rs")),
        "src/a.rs"
    );
    assert_eq!(build_anchor_label_from_anchor(&Anchor::pr()), "PR");
}

#[test]
fn builds_numbered_batch_prompt_with_history_anchors_and_guide_command() {
    let mut first = create_local_thread(
        "loc-1",
        Anchor::range("src/a.rs", Side::Right, 7, 9),
        ThreadState::Open,
        AgentThreadState::Unsent,
        vec![
            create_message("pablo", "Extract this?", true),
            create_message("agent", "Done in abc1234.", false),
            create_message("pablo", "Also rename the parameter.", true),
        ],
    );
    first.anchor.snapshot = Some("let x = 1;\nlet y = 2;".to_owned());
    let second = create_local_thread(
        "loc-2",
        Anchor::pr(),
        ThreadState::Open,
        AgentThreadState::Unsent,
        vec![create_message("pablo", "Summarize migration risk.", true)],
    );
    let prompt = build_send_prompt_from_threads(&sample_pr(), &[&first, &second]);
    for needle in [
        "Address 2 local review comments",
        "jpr-review guide",
        "1. [loc-1] src/a.rs:L7-9",
        "   > let x = 1;\n   > let y = 2;",
        "Thread so far:",
        "New comment: Also rename the parameter.",
        "2. [loc-2] PR",
        "jpr-review reply <thread-id> --body",
    ] {
        assert!(prompt.contains(needle), "missing {needle:?} in {prompt}");
    }
    let single = build_send_prompt_from_threads(&sample_pr(), &[&second]);
    assert!(
        single.contains("Address 1 local review comment on PR #"),
        "{single}"
    );
}

#[test]
fn prepass_prompt_references_guide_and_prepass_write() {
    let PullRequest { number, .. } = sample_pr();
    let prompt = build_prepass_prompt_from_pr(&sample_pr());
    assert!(prompt.contains(&format!("PR #{number}")), "{prompt}");
    assert!(prompt.contains("jpr-review guide"), "{prompt}");
    assert!(prompt.contains("jpr-review prepass-write"), "{prompt}");
}

#[test]
fn conflict_prompt_lists_conflicted_paths_and_forbids_pushing() {
    let paths = vec!["src/a.rs".to_owned(), "src/b.rs".to_owned()];
    let prompt = build_conflict_prompt_from_paths(&sample_pr(), &paths);
    assert!(prompt.contains("PR #7"), "{prompt}");
    assert!(prompt.contains("src/a.rs"), "{prompt}");
    assert!(prompt.contains("src/b.rs"), "{prompt}");
    assert!(
        prompt.contains("Never push and never touch GitHub"),
        "{prompt}"
    );
}
