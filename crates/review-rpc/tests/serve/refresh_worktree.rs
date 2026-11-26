//! Integration test for `refreshWorktree` and protocol v7 handshake.

use std::io::Cursor;
use std::sync::{Arc, Mutex};

use review_core::ReviewSession;
use review_core::fakes::{FakeWorkspace, FixedClock, MemoryStore, create_fake_ports};
use review_model::{Anchor, Origin};
use review_rpc::serve;

use super::support::{build_request_with_params, forge, messages, options, request, response};

fn create_renamed_local_session() -> Arc<Mutex<ReviewSession>> {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "fn a() {}\n");
    workspace.put_at("abc123", "src/a.rs", "fn a() { 1 }\n");
    workspace.put_disk("src/a.rs", "fn a() { 1 }\n");
    workspace.put_disk("src/old.rs", "fn old() {}\n");
    let ports = create_fake_ports(
        &forge(),
        &MemoryStore::default(),
        &workspace,
        &FixedClock::at(100),
    );
    let shared = Arc::new(Mutex::new(ReviewSession::open(7, ports).unwrap()));
    {
        let mut guard = shared.lock().unwrap();
        guard.sync().unwrap();
        guard.refresh_worktree(&[]).unwrap();
        guard
            .comment_with_origin(Anchor::line("src/old.rs", 1), "rename me", Origin::Local)
            .unwrap();
        drop(guard);
        workspace.remove_disk("src/old.rs");
        workspace.put_disk("src/renamed.rs", "fn old() {}\n");
    }
    shared
}

#[test]
fn serve_handles_refresh_worktree_and_reports_protocol_7() {
    let shared = create_renamed_local_session();
    let input = request(1, "initialize")
        + &build_request_with_params(
            2,
            "refreshWorktree",
            r#"{"renames":[{"oldPath":"src/old.rs","newPath":"src/renamed.rs"}]}"#,
        )
        + &request(3, "threads");
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(Cursor::new(input), &output, &shared, &options(None)).unwrap();
    let written = messages(&output);

    assert_eq!(response(&written, 1)["result"]["protocolVersion"], 10);
    let refreshed = &response(&written, 2)["result"];
    let renamed_row = refreshed["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["path"] == "src/renamed.rs")
        .expect("src/renamed.rs should be in SessionView");
    assert_eq!(renamed_row["isLocalOnly"], true);
    let threads = response(&written, 3)["result"]["threads"]
        .as_array()
        .unwrap();
    assert!(threads.iter().any(|thread| {
        thread["origin"] == "local" && thread["anchor"]["file"] == "src/renamed.rs"
    }));
}
