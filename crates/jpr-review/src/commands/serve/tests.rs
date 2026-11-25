use super::*;

#[test]
fn zero_turns_polling_off() {
    assert_eq!(poll_interval(0), None);
    assert_eq!(poll_interval(60), Some(Duration::from_secs(60)));
}

#[test]
fn socket_path_uses_state_dir_when_short_and_falls_back_to_temp_subdir_when_long() {
    let short_directory = Path::new("/tmp/jpr-s");
    assert_eq!(
        build_socket_path_from_state_dir(short_directory, 42),
        PathBuf::from("/tmp/jpr-s/s.sock")
    );

    let long_segment = "a".repeat(100);
    let long_directory = PathBuf::from(format!("/tmp/{long_segment}"));
    let fallback = build_socket_path_from_state_dir(&long_directory, 42);
    assert_ne!(fallback, long_directory.join("s.sock"));
    assert!(fallback.ends_with("s.sock"));
    assert!(fallback.as_os_str().len() <= MAX_UNIX_SOCKET_BYTES);
    let parent_name = fallback
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
        .unwrap();
    assert!(parent_name.starts_with("jpr-42-"), "{parent_name}");
}

#[cfg(unix)]
#[test]
fn ensure_no_live_daemon_refuses_active_recorded_or_candidate_socket() {
    use std::os::unix::net::UnixListener;

    let temp_directory = tempfile::tempdir().expect("tempdir");
    let store = FsStore::new(temp_directory.path().to_path_buf());
    let candidate = temp_directory.path().join("candidate.sock");
    ensure_no_live_daemon(&store, &candidate).expect("no daemon yet");

    let recorded = temp_directory.path().join("recorded.sock");
    let listener = UnixListener::bind(&recorded).expect("bind recorded");
    let mut snapshot = review_core::ports::StoreSnapshot::default();
    snapshot.session.socket = Some(recorded.to_string_lossy().into_owned());
    store.save(&snapshot).expect("save");
    let error = ensure_no_live_daemon(&store, &candidate).unwrap_err();
    assert!(error.to_string().contains("already serving"), "{error}");

    drop(listener);
    let _candidate_listener = UnixListener::bind(&candidate).expect("bind candidate");
    let candidate_error = ensure_no_live_daemon(&store, &candidate).unwrap_err();
    assert!(
        candidate_error.to_string().contains("already serving"),
        "{candidate_error}"
    );
}

#[cfg(unix)]
#[test]
fn create_temp_socket_directory_uses_0o700_and_refuses_preexisting_directory() {
    use std::os::unix::fs::PermissionsExt;

    let root = tempfile::tempdir().expect("tempdir");
    let state_dir = root.path().join("state");
    let private_directory = root.path().join("private");
    let socket_path = private_directory.join("s.sock");

    let guard = create_temp_socket_directory(&state_dir, &socket_path).expect("create dir");
    let mode = fs::metadata(&private_directory)
        .expect("meta")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o700);
    assert!(create_temp_socket_directory(&state_dir, &socket_path).is_err());

    drop(guard);
    assert!(!private_directory.exists());
}

#[test]
fn clear_owned_socket_record_clears_only_matching_pid_and_socket() {
    use review_core::fakes::{FakeForge, FakeWorkspace, FixedClock, sample_pr};
    use review_core::ports::{ForgeSnapshot, Ports};

    let root = tempfile::tempdir().expect("tempdir");
    let ports = Ports {
        forge: Box::new(FakeForge::new(sample_pr(), ForgeSnapshot::default())),
        store: Box::new(FsStore::new(root.path().to_path_buf())),
        workspace: Box::new(FakeWorkspace::default()),
        clock: Box::new(FixedClock::at(100)),
    };
    let mut session = ReviewSession::open(7, ports).expect("open");
    session
        .record_daemon_with_socket(42, "/worktree", Some("/tmp/a.sock"))
        .expect("record");
    let shared = Arc::new(Mutex::new(session));
    let worktree = Path::new("/worktree");
    let read_socket = || {
        FsStore::new(root.path().to_path_buf())
            .load()
            .unwrap()
            .session
            .socket
    };

    clear_owned_socket_record(root.path(), &shared, 99, worktree, Some("/tmp/a.sock"));
    assert_eq!(read_socket().as_deref(), Some("/tmp/a.sock"));

    clear_owned_socket_record(root.path(), &shared, 42, worktree, Some("/tmp/b.sock"));
    assert_eq!(read_socket().as_deref(), Some("/tmp/a.sock"));

    clear_owned_socket_record(root.path(), &shared, 42, worktree, Some("/tmp/a.sock"));
    assert_eq!(read_socket(), None);
}

#[test]
fn clear_owned_socket_record_uses_active_dir_after_mid_session_retarget() {
    use review_core::fakes::{FakeForge, FakeWorkspace, FixedClock, sample_pr};
    use review_core::ports::{ForgeSnapshot, Ports};
    use review_store_fs::StateRootConfig;

    let root = tempfile::tempdir().expect("tempdir");
    let local_dir = root.path().join("local-dir");
    let state_root = StateRootConfig {
        xdg_state_home: Some(root.path().to_path_buf()),
        home: root.path().to_path_buf(),
        app: "jpr".into(),
    };
    let store = FsStore::new_with_root(local_dir, state_root);
    let store_handle = store.clone();
    let ports = Ports {
        forge: Box::new(FakeForge::new(sample_pr(), ForgeSnapshot::default())),
        store: Box::new(store),
        workspace: Box::new(FakeWorkspace::default()),
        clock: Box::new(FixedClock::at(100)),
    };
    let mut session = ReviewSession::open_local(
        LocalReviewContext {
            branch: "fix/widget".into(),
            base_ref: "main".into(),
            base_sha: "base000".into(),
            repo: Some("octo/widgets".into()),
        },
        ports,
    )
    .expect("open local");
    session
        .record_daemon_with_socket(42, "/worktree", Some("/tmp/live.sock"))
        .expect("record");
    session.sync().expect("upgrade to PR #7");

    let active_dir = store_handle.current_dir();
    assert!(active_dir.ends_with("pr-7"), "{active_dir:?}");
    let shared = Arc::new(Mutex::new(session));
    clear_owned_socket_record(
        &active_dir,
        &shared,
        42,
        Path::new("/worktree"),
        Some("/tmp/live.sock"),
    );
    assert_eq!(
        FsStore::new(active_dir).load().unwrap().session.socket,
        None
    );
}
