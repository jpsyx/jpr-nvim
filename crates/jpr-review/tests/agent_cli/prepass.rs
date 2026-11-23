use std::fs;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use review_core::ports::{ReviewStore, StoreSnapshot};
use review_store_fs::FsStore;
use serde_json::{Value, json};

use super::support::{
    TestEnvironment, assert_success, init_git_worktree, sample_findings_json,
    shutdown_socket_daemon, spawn_concurrent_replies, spawn_socket_daemon,
};

#[test]
fn prepass_write_reads_from_input_file_and_serializes_concurrent_fallback_writes() {
    let environment = Arc::new(TestEnvironment::create());
    let input_path = environment.root.path().join("findings.json");
    fs::write(&input_path, sample_findings_json()).expect("write findings");
    let input_text = input_path.to_str().expect("utf8");
    let created = environment.run(
        &[
            "prepass-write",
            "--input",
            input_text,
            "--pr",
            "7",
            "--repo",
            "octo/widgets",
        ],
        None,
        &[],
    );
    assert_success(&created, "prepass-write --input");
    spawn_concurrent_replies(&environment, 4);
    let store = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    let local = store.load().expect("load").local;
    let local_thread = local
        .threads
        .iter()
        .find(|thread| thread.id == "loc-1")
        .expect("loc-1");
    assert_eq!(local_thread.messages.len(), 5);
}

#[test]
fn live_socket_prepass_write_creates_threads_and_notifies() {
    let environment = TestEnvironment::create();
    let socket_path = environment.root.path().join("s.sock");
    let socket_text = socket_path.to_str().expect("utf8 path");
    let (stdin_sender, stdout_receiver, handle) = spawn_socket_daemon(&socket_path);

    let created = environment.run(
        &["prepass-write"],
        Some(&sample_findings_json()),
        &[("JPR_SOCKET", socket_text)],
    );
    assert_success(&created, "live socket prepass-write");
    let created_json: Value = serde_json::from_slice(&created.stdout).expect("prepass JSON");
    assert_eq!(
        created_json["threads"].as_array().expect("created").len(),
        2
    );
    let event = stdout_receiver
        .recv_timeout(Duration::from_secs(3))
        .expect("threadsChanged event");
    assert_eq!(event["params"]["type"], "threadsChanged");
    shutdown_socket_daemon(stdin_sender, handle);
}

#[test]
fn prepass_write_rejects_blank_unsafe_and_oversized_wire_inputs() {
    let environment = TestEnvironment::create();
    let run_prepass = |stdin_text: &str| {
        environment.run(
            &["prepass-write", "--pr", "7", "--repo", "octo/widgets"],
            Some(stdin_text),
            &[],
        )
    };
    let blank = run_prepass("   \n");
    assert!(!blank.status.success());
    assert!(String::from_utf8_lossy(&blank.stderr).contains("JSON array of findings"));

    let empty_array = run_prepass("[]");
    assert_success(&empty_array, "prepass-write empty array");
    assert_eq!(
        serde_json::from_slice::<Value>(&empty_array.stdout).unwrap(),
        json!({ "threads": [] })
    );

    for unsafe_path in [".git/config", "../secret.rs"] {
        let payload = json!([{ "anchor": { "file": unsafe_path, "kind": "file", "side": "RIGHT" }, "body": "bad" }]).to_string();
        assert!(!run_prepass(&payload).status.success(), "{unsafe_path}");
    }

    let dense_item = r#"{"anchor":{"kind":"pr","side":"RIGHT"},"body":"x"}"#;
    let dense_payload = format!("[{}]", vec![dense_item; 9_500].join(","));
    assert!(dense_payload.len() < 512 * 1024);
    let oversized = run_prepass(&dense_payload);
    assert!(!oversized.status.success());
    assert!(
        String::from_utf8_lossy(&oversized.stderr).contains("1 MiB daemon socket payload limit")
    );
}

#[test]
fn fallback_ignores_empty_env_vars_and_captures_git_worktree_snapshot() {
    let environment = TestEnvironment::create();
    let repo_directory = environment.root.path().join("worktree");
    init_git_worktree(&repo_directory);
    let mut child = Command::new(env!("CARGO_BIN_EXE_jpr-review"))
        .args(["prepass-write", "--pr", "7"])
        .current_dir(&repo_directory)
        .env("HOME", &environment.home)
        .env("XDG_STATE_HOME", &environment.state)
        .env("JPR_PR", "")
        .env("JPR_SOCKET", "")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn prepass-write");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(sample_findings_json().as_bytes())
        .expect("stdin");
    let output = child.wait_with_output().expect("wait prepass-write");
    assert_success(&output, "prepass-write empty env");
    let parsed: Value = serde_json::from_slice(&output.stdout).expect("json");
    assert_eq!(parsed["threads"][0]["anchor"]["snapshot"], "let bound = 2;");
}

#[test]
fn prepass_write_rejects_unchanged_file_when_pr_files_are_known() {
    let environment = TestEnvironment::create();
    let store = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    let mut snapshot = StoreSnapshot::default();
    snapshot.files.push(review_core::fakes::changed_file(
        "src/a.rs",
        review_model::ViewedState::Unviewed,
    ));
    store.save(&snapshot).expect("save pr files");

    let bad_payload = json!([
        { "anchor": { "file": "src/unchanged.rs", "kind": "line", "side": "RIGHT", "start": 1, "end": 1 }, "body": "[high] bad" }
    ])
    .to_string();
    let offline_rejected = environment.run(
        &["prepass-write", "--pr", "7", "--repo", "octo/widgets"],
        Some(&bad_payload),
        &[],
    );
    assert!(!offline_rejected.status.success());
    assert!(
        String::from_utf8_lossy(&offline_rejected.stderr)
            .contains("is not a file this pull request changes")
    );

    let socket_path = environment.root.path().join("s.sock");
    let socket_text = socket_path.to_str().expect("utf8 path");
    let (stdin_sender, _stdout_receiver, handle) = spawn_socket_daemon(&socket_path);
    let socket_rejected = environment.run(
        &["prepass-write"],
        Some(&bad_payload),
        &[("JPR_SOCKET", socket_text)],
    );
    assert!(!socket_rejected.status.success());
    assert!(
        String::from_utf8_lossy(&socket_rejected.stderr)
            .contains("is not a file this pull request changes")
    );
    shutdown_socket_daemon(stdin_sender, handle);
}
