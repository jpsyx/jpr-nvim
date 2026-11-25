//! Crash-safe retargeting of an active `FsStore` from a local review directory
//! to a pull request's canonical state directory (`pr-<number>/`).

use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use review_core::ports::StoreSnapshot;

use crate::{
    GITHUB_FILE, GITHUB_VERSION, LOCAL_FILE, LOCAL_LOCK_FILE, LOCAL_VERSION, ROUNDS_FILE,
    SESSION_FILE, SESSION_VERSION, VIEWED_FILE, VIEWED_VERSION, atomic, lock, paths,
};

/// Base XDG/HOME configuration needed by [`crate::FsStore`] to compute the
/// canonical `pr-<number>` directory on mid-session retargeting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRootConfig {
    /// Optional `$XDG_STATE_HOME` path.
    pub xdg_state_home: Option<PathBuf>,
    /// User home directory (`$HOME`).
    pub home: PathBuf,
    /// Application directory name under state home (for example `"jpr"`).
    pub app: String,
}

/// Validates `target_dir`, refuses a live daemon or newer format version,
/// copies `rounds.jsonl` from `old_dir` into `target_dir`, and returns
/// `(target_dir, existing_snapshot)`.
pub fn prepare_retarget_to_pr(
    state_root: &StateRootConfig,
    old_dir: &Path,
    owner: &str,
    repo: &str,
    number: u64,
) -> Result<Option<(PathBuf, Option<StoreSnapshot>)>> {
    let target_dir = paths::state_dir(
        state_root.xdg_state_home.as_deref(),
        &state_root.home,
        &state_root.app,
        owner,
        repo,
        number,
    )?;
    if old_dir == target_dir {
        return Ok(None);
    }
    check_target_versions(&target_dir)?;
    ensure_no_live_daemon_in_dir(&target_dir, number)?;
    let existing = load_existing_snapshot(&target_dir)?;
    append_rounds_file(old_dir, &target_dir)?;
    Ok(Some((target_dir, existing)))
}

/// Deletes migrated state files from `old_dir` after the upgraded PR state has
/// been durably persisted in `pr-<number>/`, preserving any live `s.sock`.
pub fn retire_old_local_dir(old_dir: &Path) {
    for file_name in [
        LOCAL_FILE,
        ROUNDS_FILE,
        VIEWED_FILE,
        GITHUB_FILE,
        SESSION_FILE,
        LOCAL_LOCK_FILE,
    ] {
        let path = old_dir.join(file_name);
        if path.exists() {
            let _ = fs::remove_file(&path);
        }
    }
    let _ = fs::remove_dir(old_dir);
}

fn check_target_versions(target_dir: &Path) -> Result<()> {
    crate::refuse_newer_file(&target_dir.join(SESSION_FILE), SESSION_VERSION)?;
    crate::refuse_newer_file(&target_dir.join(VIEWED_FILE), VIEWED_VERSION)?;
    crate::refuse_newer_file(&target_dir.join(GITHUB_FILE), GITHUB_VERSION)?;
    crate::refuse_newer_file(&target_dir.join(LOCAL_FILE), LOCAL_VERSION)?;
    Ok(())
}

fn load_existing_snapshot(target_dir: &Path) -> Result<Option<StoreSnapshot>> {
    let has_any = [SESSION_FILE, VIEWED_FILE, GITHUB_FILE, LOCAL_FILE]
        .iter()
        .any(|name| target_dir.join(name).exists());
    if !has_any {
        return Ok(None);
    }
    crate::load_snapshot_from_dir(target_dir).map(Some)
}

fn append_rounds_file(old_dir: &Path, target_dir: &Path) -> Result<()> {
    let old_rounds = old_dir.join(ROUNDS_FILE);
    let Some(bytes) = atomic::read_bytes(&old_rounds)? else {
        return Ok(());
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(());
    }
    lock::with_local_lock(target_dir, || {
        let target_rounds = target_dir.join(ROUNDS_FILE);
        let mut file = crate::open_rounds_append(&target_rounds)?;
        let previous_len = file
            .metadata()
            .with_context(|| format!("reading {} metadata", target_rounds.display()))?
            .len();
        let write_result = file.write_all(&bytes).and_then(|()| {
            if bytes.last() != Some(&b'\n') {
                file.write_all(b"\n")?;
            }
            file.sync_all()
        });
        if let Err(error) = write_result {
            let _ = file.set_len(previous_len);
            return Err(error)
                .with_context(|| format!("migrating rounds into {}", target_rounds.display()));
        }
        atomic::sync_dir(target_dir)
    })
}

#[cfg(unix)]
fn ensure_no_live_daemon_in_dir(target_dir: &Path, number: u64) -> Result<()> {
    if let Ok(Some(snapshot)) = load_existing_snapshot(target_dir)
        && let Some(recorded) = snapshot
            .session
            .socket
            .as_deref()
            .filter(|text| !text.trim().is_empty())
        && UnixStream::connect(Path::new(recorded)).is_ok()
    {
        bail!("another jpr-review daemon is already serving PR #{number}");
    }
    if UnixStream::connect(target_dir.join("s.sock")).is_ok() {
        bail!("another jpr-review daemon is already serving PR #{number}");
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_no_live_daemon_in_dir(_target_dir: &Path, _number: u64) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use review_core::ports::{ReviewStore, StoreSnapshot};
    use review_model::{AgentRound, AgentRoundKind, ViewedState};

    use super::*;
    use crate::FsStore;

    fn create_root(temp: &tempfile::TempDir) -> StateRootConfig {
        StateRootConfig {
            xdg_state_home: Some(temp.path().to_path_buf()),
            home: temp.path().to_path_buf(),
            app: "jpr".to_owned(),
        }
    }

    #[test]
    fn retarget_migrates_rounds_switches_dir_and_finalize_retires_old_files_preserving_socket() {
        let temp = tempfile::tempdir().unwrap();
        let root = create_root(&temp);
        let old_dir = paths::local_state_dir(
            root.xdg_state_home.as_deref(),
            &root.home,
            &root.app,
            Some(("octo", "widgets")),
            Path::new("/work/widgets"),
            "feat/local",
        )
        .unwrap();
        let store = FsStore::new_with_root(old_dir.clone(), root.clone());
        let mut local_snapshot = StoreSnapshot::default();
        local_snapshot
            .local
            .local_viewed
            .insert("src/a.rs".into(), ViewedState::Viewed);
        store.save(&local_snapshot).unwrap();
        store
            .append_round(&AgentRound {
                round: 1,
                kind: AgentRoundKind::Send,
                thread_ids: vec!["loc-1".into()],
                prompt: "fix".into(),
                sent_at: 100,
            })
            .unwrap();
        let socket_marker = old_dir.join("s.sock");
        fs::write(&socket_marker, b"live-socket").unwrap();

        let existing = store.retarget_to_pr("octo", "widgets", 42).unwrap();
        assert!(existing.is_none());
        let pr_dir = paths::state_dir(
            root.xdg_state_home.as_deref(),
            &root.home,
            &root.app,
            "octo",
            "widgets",
            42,
        )
        .unwrap();
        assert_eq!(store.current_dir(), pr_dir);
        assert_eq!(store.rounds().unwrap().len(), 1);
        assert!(
            old_dir.join(LOCAL_FILE).exists(),
            "old files stay intact until finalize_retarget after durable save"
        );

        store.save(&local_snapshot).unwrap();
        store.finalize_retarget().unwrap();
        for migrated in [
            LOCAL_FILE,
            ROUNDS_FILE,
            SESSION_FILE,
            VIEWED_FILE,
            GITHUB_FILE,
        ] {
            assert!(
                !old_dir.join(migrated).exists(),
                "expected {migrated} to be removed from old_dir"
            );
        }
        assert!(
            socket_marker.exists(),
            "live socket path in old_dir must remain untouched"
        );
    }

    #[cfg(unix)]
    #[test]
    fn retarget_returns_existing_pr_snapshot_and_refuses_live_daemon_or_newer_version() {
        use std::os::unix::net::UnixListener;

        let temp = tempfile::tempdir().unwrap();
        let root = create_root(&temp);
        let old_dir = temp.path().join("local-work");
        let pr_dir = paths::state_dir(
            root.xdg_state_home.as_deref(),
            &root.home,
            &root.app,
            "octo",
            "widgets",
            42,
        )
        .unwrap();
        let pr_store = FsStore::new(pr_dir.clone());
        let mut prior = StoreSnapshot::default();
        prior.local.next_local_id = 5;
        let live_sock = temp.path().join("live.sock");
        let listener = UnixListener::bind(&live_sock).unwrap();
        prior.session.socket = Some(live_sock.to_string_lossy().into_owned());
        pr_store.save(&prior).unwrap();

        let local_store = FsStore::new_with_root(old_dir.clone(), root);
        local_store.save(&StoreSnapshot::default()).unwrap();
        let blocked = local_store
            .retarget_to_pr("octo", "widgets", 42)
            .unwrap_err();
        assert!(
            blocked.to_string().contains("already serving PR #42"),
            "{blocked:#}"
        );
        assert_eq!(local_store.current_dir(), old_dir);

        drop(listener);
        let returned = local_store
            .retarget_to_pr("octo", "widgets", 42)
            .unwrap()
            .expect("existing PR snapshot returned");
        assert_eq!(returned.local.next_local_id, 5);
        assert_eq!(local_store.current_dir(), pr_dir);
    }
}
