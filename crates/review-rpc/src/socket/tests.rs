use std::os::unix::fs::symlink;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;

use review_core::ReviewSession;
use review_core::fakes::sample_pr;
use review_core::fakes::{FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports};
use review_core::ports::ForgeSnapshot;

use super::*;

static NEXT_UNIT_SOCK: AtomicU64 = AtomicU64::new(1);

struct TempDirGuard(PathBuf);

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn create_unit_temp_directory(label: &str) -> TempDirGuard {
    let sequence = NEXT_UNIT_SOCK.fetch_add(1, Ordering::Relaxed);
    TempDirGuard(PathBuf::from(format!(
        "/tmp/jpr-sock-{label}-{}-{sequence}",
        std::process::id()
    )))
}

fn create_test_shared() -> Shared<Vec<u8>> {
    let forge = FakeForge::new(sample_pr(), ForgeSnapshot::default());
    let ports = create_fake_ports(
        &forge,
        &MemoryStore::default(),
        &FakeWorkspace::default(),
        &FixedClock::at(100),
    );
    let mut session = ReviewSession::open(7, ports).unwrap();
    let events = Arc::new(Mutex::new(session.subscribe()));
    (
        Arc::new(Mutex::new(session)),
        events,
        Arc::new(Mutex::new(Vec::<u8>::new())),
    )
}

#[test]
fn allowlist_permits_only_expected_socket_methods() {
    for allowed in ["snapshot", "threads", "agentReply", "prepassWrite"] {
        assert!(is_socket_method_allowed(allowed), "{allowed}");
    }
    for refused in [
        "initialize",
        "shutdown",
        "submitReview",
        "comment",
        "promoteThread",
        "sync",
        "push",
        "prepareConflictResolution",
        "confirmSend",
        "prepareSend",
        "preparePrepass",
        "prepareAgentLaunch",
        "setViewed",
        "setCollapsed",
        "reply",
        "editMessage",
        "deleteMessage",
        "setResolved",
        "toggleReaction",
    ] {
        assert!(!is_socket_method_allowed(refused), "{refused}");
    }
}

#[test]
fn prepare_socket_path_refuses_regular_file_symlink_and_active_socket() {
    let temp_directory = create_unit_temp_directory("prep");
    fs::create_dir_all(&temp_directory.0).unwrap();
    let file_path = temp_directory.0.join("regular");
    fs::write(&file_path, b"keep").unwrap();
    assert!(prepare_socket_path(&file_path).is_err());
    assert_eq!(fs::read(&file_path).unwrap(), b"keep");

    let link_path = temp_directory.0.join("link");
    symlink(&file_path, &link_path).unwrap();
    assert!(prepare_socket_path(&link_path).is_err());
    assert!(fs::symlink_metadata(&link_path).is_ok());

    let live_path = temp_directory.0.join("live.sock");
    let _listener = UnixListener::bind(&live_path).unwrap();
    assert!(prepare_socket_path(&live_path).is_err());

    let stale_path = temp_directory.0.join("stale.sock");
    drop(UnixListener::bind(&stale_path).unwrap());
    prepare_socket_path(&stale_path).unwrap();
    assert!(!stale_path.exists());
}

#[test]
fn socket_server_sets_0700_dir_and_0600_socket_permissions() {
    let temp_directory = create_unit_temp_directory("perms");
    let socket_path = temp_directory.0.join("sub").join("jpr.sock");
    let server = SocketServer::start(&socket_path, create_test_shared(), "1.0.0".into()).unwrap();
    let directory_mode = fs::metadata(socket_path.parent().unwrap())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    let socket_mode = fs::metadata(&socket_path).unwrap().permissions().mode() & 0o777;
    assert_eq!(directory_mode, 0o700);
    assert_eq!(socket_mode, 0o600);
    server.stop_and_join();
    assert!(!socket_path.exists());
}

#[test]
fn socket_server_tightens_existing_parent_dir_without_touching_symlinks() {
    let temp_directory = create_unit_temp_directory("existing");
    let existing_sub = temp_directory.0.join("existing");
    fs::create_dir_all(&existing_sub).unwrap();
    fs::set_permissions(&existing_sub, Permissions::from_mode(0o755)).unwrap();

    let socket_path = existing_sub.join("jpr.sock");
    let server = SocketServer::start(&socket_path, create_test_shared(), "1.0.0".into()).unwrap();
    let mode = fs::metadata(&existing_sub).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);
    server.stop_and_join();

    let link_target = temp_directory.0.join("target");
    fs::create_dir_all(&link_target).unwrap();
    fs::set_permissions(&link_target, Permissions::from_mode(0o755)).unwrap();
    let link_parent = temp_directory.0.join("link_parent");
    symlink(&link_target, &link_parent).unwrap();
    let linked_sock = link_parent.join("jpr.sock");
    prepare_socket_path(&linked_sock).unwrap();
    let target_mode = fs::metadata(&link_target).unwrap().permissions().mode() & 0o777;
    assert_eq!(target_mode, 0o755);
}

#[test]
fn blank_line_spam_disconnects_client_without_eof() {
    let stopped = AtomicBool::new(false);
    let (mut client, server_stream) = UnixStream::pair().unwrap();
    let blanks = "\n".repeat(MAX_CONSECUTIVE_BLANK_LINES);
    client.write_all(blanks.as_bytes()).unwrap();
    client.flush().unwrap();

    let started = Instant::now();
    handle_socket_client(server_stream, &stopped, &create_test_shared(), "1.0.0");
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(client);
}
