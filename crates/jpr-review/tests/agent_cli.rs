//! End-to-end process tests for `jpr-review` agent CLI subcommands.

#[path = "agent_cli/prepass.rs"]
mod prepass;
#[path = "agent_cli/support.rs"]
mod support;

use std::process::{Command, Stdio};
use std::time::Duration;

use review_core::fakes::github_thread;
use review_core::ports::{ReviewStore, StoreSnapshot};
use review_store_fs::FsStore;
use serde_json::{Value, json};

use support::{
    TestEnvironment, assert_success, init_git_worktree, sample_findings_json,
    shutdown_socket_daemon, spawn_socket_daemon,
};

#[test]
fn guide_prints_the_agent_contract_to_stdout() {
    let environment = TestEnvironment::create();
    let output = environment.run(&["guide"], None, &[]);
    assert_success(&output, "guide");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("jpr-review reply <thread-id> --body"),
        "{stdout}"
    );
    assert!(stdout.contains("Never push"), "{stdout}");
    assert_eq!(output.stderr, b"");
}

#[test]
fn offline_fallback_prepass_write_threads_and_reply_round_trip() {
    let environment = TestEnvironment::create();
    let prepass = environment.run(
        &["prepass-write", "--pr", "7", "--repo", "octo/widgets"],
        Some(&sample_findings_json()),
        &[],
    );
    assert_success(&prepass, "prepass-write");
    let store = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    let saved_local = store.load().expect("load").local;
    assert_eq!(saved_local.threads.len(), 2);
    assert_eq!(saved_local.threads[0].id, "loc-1");
    assert_eq!(saved_local.threads[1].id, "loc-2");

    let reply_args = [
        "reply",
        "loc-1",
        "--body",
        "Addressed in 1234567.",
        "--pr",
        "7",
        "--repo",
        "octo/widgets",
    ];
    assert_success(&environment.run(&reply_args, None, &[]), "reply");

    let list_args = ["threads", "--pr", "7", "--repo", "octo/widgets", "--local"];
    let listed = environment.run(&list_args, None, &[]);
    assert_success(&listed, "threads");
    let parsed: Value = serde_json::from_slice(&listed.stdout).expect("threads JSON");
    let threads = parsed["threads"].as_array().expect("threads array");
    assert_eq!(threads.len(), 2);
    assert_eq!(threads[0]["id"], "loc-1");
    assert_eq!(
        threads[0]["messages"].as_array().expect("messages").len(),
        2
    );
    assert_eq!(threads[0]["agent"], json!({ "state": "answered" }));
}

#[test]
fn offline_reply_refuses_github_and_aliased_thread_ids() {
    let environment = TestEnvironment::create();
    let store = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    let mut snapshot = StoreSnapshot::default();
    snapshot
        .registry
        .threads
        .push(github_thread("THREAD_FROM_GH", "src/a.rs"));
    snapshot
        .registry
        .id_map
        .insert("alias-gh".into(), "THREAD_FROM_GH".into());
    store.save(&snapshot).expect("save seeded github thread");

    for bad_id in [
        "PRRT_abc",
        "IC_123",
        "PRRC_456",
        "tmp-7",
        "THREAD_FROM_GH",
        "alias-gh",
    ] {
        let args = [
            "reply",
            bad_id,
            "--body",
            "no",
            "--pr",
            "7",
            "--repo",
            "octo/widgets",
        ];
        let refused = environment.run(&args, None, &[]);
        assert!(!refused.status.success(), "{bad_id} should fail");
        let stderr = String::from_utf8_lossy(&refused.stderr);
        assert!(stderr.contains("GitHub thread"), "{bad_id}: {stderr}");
    }
}

#[test]
fn live_socket_threads_and_reply_route_through_daemon_via_jpr_socket_env() {
    let environment = TestEnvironment::create();
    let socket_path = environment.root.path().join("s.sock");
    let socket_text = socket_path.to_str().expect("utf8 path");
    let (stdin_sender, stdout_receiver, handle) = spawn_socket_daemon(&socket_path);
    let socket_environment = &[("JPR_SOCKET", socket_text)];

    let all_output = environment.run(&["threads"], None, socket_environment);
    assert_success(&all_output, "socket threads all");
    let all_json: Value = serde_json::from_slice(&all_output.stdout).expect("all threads JSON");
    assert_eq!(all_json["threads"].as_array().expect("threads").len(), 2);

    let local_output = environment.run(&["threads", "--local"], None, socket_environment);
    assert_success(&local_output, "socket threads --local");
    let listed: Value = serde_json::from_slice(&local_output.stdout).expect("local threads JSON");
    assert_eq!(listed["threads"].as_array().expect("threads").len(), 1);
    assert_eq!(listed["threads"][0]["id"], "loc-1");

    let refused = environment.run(&["reply", "T1", "--body", "nope"], None, socket_environment);
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("GitHub thread"));

    let reply_output = environment.run(
        &["reply", "loc-1", "--body", "Via socket"],
        None,
        socket_environment,
    );
    assert_success(&reply_output, "socket reply");
    let reply_json: Value = serde_json::from_slice(&reply_output.stdout).expect("reply JSON");
    assert_eq!(
        reply_json["thread"]["messages"]
            .as_array()
            .expect("messages")
            .len(),
        2
    );

    let event = stdout_receiver
        .recv_timeout(Duration::from_secs(3))
        .expect("threadsChanged");
    assert_eq!(event["method"], "event");
    assert_eq!(event["params"]["type"], "threadsChanged");
    shutdown_socket_daemon(stdin_sender, handle);
}

#[test]
fn session_socket_discovery_and_explicit_pr_ignores_ambient_env() {
    let environment = TestEnvironment::create();
    let socket_path = environment.root.path().join("s.sock");
    let socket_text = socket_path.to_str().expect("utf8 path");
    let (stdin_sender, _stdout_receiver, handle) = spawn_socket_daemon(&socket_path);

    let store7 = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    let mut snapshot7 = StoreSnapshot::default();
    snapshot7.session.socket = Some(socket_text.to_owned());
    store7.save(&snapshot7).expect("save session socket");

    let via_session = environment.run(
        &["threads", "--pr", "7", "--repo", "octo/widgets", "--local"],
        None,
        &[],
    );
    assert_success(&via_session, "session.json socket discovery");
    let listed7: Value = serde_json::from_slice(&via_session.stdout).expect("threads7 JSON");
    assert_eq!(listed7["threads"][0]["id"], "loc-1");

    let ignored_output = environment.run(
        &["threads", "--pr", "8", "--repo", "octo/widgets", "--local"],
        None,
        &[("JPR_SOCKET", socket_text)],
    );
    assert_success(&ignored_output, "explicit --pr ignores ambient JPR_SOCKET");
    assert_eq!(
        serde_json::from_slice::<Value>(&ignored_output.stdout).unwrap(),
        json!({ "threads": [] })
    );
    shutdown_socket_daemon(stdin_sender, handle);
}

#[test]
fn explicit_socket_flag_rejects_empty_or_unreachable_socket_without_fallback() {
    let environment = TestEnvironment::create();
    let missing_socket = environment.root.path().join("nonexistent.sock");
    let run_threads = |socket: &str| {
        let args = [
            "threads",
            "--socket",
            socket,
            "--pr",
            "7",
            "--repo",
            "octo/widgets",
        ];
        environment.run(&args, None, &[])
    };

    let dead = run_threads(missing_socket.to_str().expect("utf8"));
    assert!(!dead.status.success());
    assert!(String::from_utf8_lossy(&dead.stderr).contains("cannot connect"));

    let empty = run_threads("");
    assert!(!empty.status.success());
    assert_eq!(empty.stdout, b"");

    let blank = run_threads("   ");
    assert!(!blank.status.success());
    assert!(String::from_utf8_lossy(&blank.stderr).contains("cannot be empty"));
}

#[test]
fn explicit_repo_ignores_ambient_jpr_pr_while_inferred_repo_uses_it() {
    let environment = TestEnvironment::create();
    let worktree = environment.root.path().join("worktree");
    init_git_worktree(&worktree);
    let widgets_store = FsStore::new(environment.pr_state_directory("octo", "widgets", 7));
    widgets_store
        .save(&StoreSnapshot::default())
        .expect("init widgets");
    let other_store = FsStore::new(environment.pr_state_directory("octo", "other", 7));
    other_store
        .save(&StoreSnapshot::default())
        .expect("init other");

    let inferred = Command::new(env!("CARGO_BIN_EXE_jpr-review"))
        .args(["threads"])
        .current_dir(&worktree)
        .env("HOME", &environment.home)
        .env("XDG_STATE_HOME", &environment.state)
        .env("JPR_PR", "7")
        .env_remove("JPR_SOCKET")
        .stdin(Stdio::null())
        .output()
        .expect("run threads");
    assert_success(&inferred, "inferred repo uses JPR_PR");

    let explicit_repo = Command::new(env!("CARGO_BIN_EXE_jpr-review"))
        .args(["threads", "--repo", "octo/other"])
        .current_dir(&worktree)
        .env("HOME", &environment.home)
        .env("XDG_STATE_HOME", &environment.state)
        .env("JPR_PR", "7")
        .env_remove("JPR_SOCKET")
        .stdin(Stdio::null())
        .output()
        .expect("run threads --repo");
    assert!(
        !explicit_repo.status.success(),
        "explicit --repo without --pr must not read JPR_PR"
    );
}
