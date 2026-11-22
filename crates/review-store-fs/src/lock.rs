//! Advisory lock file (`local.lock`) for fallback CLI writes to `local.json`
//! when no `jpr-review serve` daemon is running.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// Lock file name inside the pull request's state directory.
pub const LOCAL_LOCK_FILE: &str = "local.lock";

const LOCK_TIMEOUT: Duration = Duration::from_secs(5);
const LOCK_POLL: Duration = Duration::from_millis(15);
const STALE_LOCK_AGE: Duration = Duration::from_secs(30);

#[derive(Debug)]
struct LockGuard {
    path: PathBuf,
    #[cfg(unix)]
    _file: fs::File,
    #[cfg(unix)]
    file_id: (u64, u64),
    #[cfg(not(unix))]
    token: String,
}

impl LockGuard {
    fn is_still_owner(&self) -> bool {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            fs::symlink_metadata(&self.path)
                .is_ok_and(|metadata| (metadata.dev(), metadata.ino()) == self.file_id)
        }
        #[cfg(not(unix))]
        {
            fs::read_to_string(&self.path).is_ok_and(|contents| {
                contents
                    .lines()
                    .next()
                    .is_some_and(|first| first == self.token)
            })
        }
    }
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        if self.is_still_owner() {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Acquires `<directory>/local.lock` exclusively, runs `operation`, and removes
/// the lock file on return.
pub fn with_local_lock<T>(directory: &Path, operation: impl FnOnce() -> Result<T>) -> Result<T> {
    fs::create_dir_all(directory).with_context(|| format!("creating {}", directory.display()))?;
    let guard = acquire_lock_with_timeout(&directory.join(LOCAL_LOCK_FILE), LOCK_TIMEOUT)?;
    let result = operation();
    drop(guard);
    result
}

fn acquire_lock_with_timeout(lock_path: &Path, timeout: Duration) -> Result<LockGuard> {
    let deadline = Instant::now() + timeout;
    loop {
        match try_create_lock(lock_path) {
            Ok(guard) => return Ok(guard),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                if evict_stale_lock(lock_path) {
                    continue;
                }
                if Instant::now() >= deadline {
                    bail!(
                        "timed out waiting for {} (another jpr-review process is writing local state)",
                        lock_path.display()
                    );
                }
                thread::sleep(LOCK_POLL);
            }
            Err(error) => {
                return Err(error).with_context(|| format!("creating {}", lock_path.display()));
            }
        }
    }
}

fn open_exclusive_file(path: &Path) -> std::io::Result<fs::File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[cfg(unix)]
fn try_create_lock(lock_path: &Path) -> std::io::Result<LockGuard> {
    use std::os::unix::fs::MetadataExt;
    let mut file = open_exclusive_file(lock_path)?;
    let _ = writeln!(file, "{}", std::process::id());
    match file.metadata() {
        Ok(metadata) => Ok(LockGuard {
            path: lock_path.to_path_buf(),
            file_id: (metadata.dev(), metadata.ino()),
            // Keep the fd open until after Drop unlinks, so the kernel cannot
            // reuse this (dev, ino) while this guard still exists.
            _file: file,
        }),
        Err(error) => {
            let _ = fs::remove_file(lock_path);
            Err(error)
        }
    }
}

#[cfg(not(unix))]
fn try_create_lock(lock_path: &Path) -> std::io::Result<LockGuard> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static TOKEN_COUNTER: AtomicU64 = AtomicU64::new(0);
    let token = format!(
        "{}-{}",
        std::process::id(),
        TOKEN_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let mut file = open_exclusive_file(lock_path)?;
    if let Err(error) = writeln!(file, "{token}") {
        let _ = fs::remove_file(lock_path);
        return Err(error);
    }
    Ok(LockGuard {
        path: lock_path.to_path_buf(),
        token,
    })
}

fn eviction_lock_path(lock_path: &Path) -> PathBuf {
    let mut path_os = lock_path.as_os_str().to_os_string();
    path_os.push(".evict");
    PathBuf::from(path_os)
}

fn is_file_stale(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > STALE_LOCK_AGE)
}

fn acquire_evict_guard(eviction_path: &Path) -> Option<LockGuard> {
    match try_create_lock(eviction_path) {
        Ok(guard) => Some(guard),
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if is_file_stale(eviction_path) {
                let _ = fs::remove_file(eviction_path);
                return try_create_lock(eviction_path).ok();
            }
            None
        }
        Err(_) => None,
    }
}

// Without `unsafe` OS `flock`/`fcntl` calls, `O_CREAT | O_EXCL` lock files
// cannot prevent a >30s-paused holder from being evicted; `local.lock.evict`
// serializes contenders during eviction and `LockGuard` verifies `(dev, ino)`
// so a stale holder never unlinks a successor's replacement lock.
fn evict_stale_lock(lock_path: &Path) -> bool {
    if !is_file_stale(lock_path) {
        return false;
    }
    let eviction_path = eviction_lock_path(lock_path);
    let Some(eviction_guard) = acquire_evict_guard(&eviction_path) else {
        return false;
    };
    let did_evict = if is_file_stale(lock_path) {
        fs::remove_file(lock_path).is_ok()
    } else {
        false
    };
    drop(eviction_guard);
    did_evict
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;

    #[test]
    fn stale_lock_file_is_evicted_before_acquisition() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        let stale_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .unwrap();
        let past = SystemTime::now() - Duration::from_secs(60);
        stale_file.set_modified(past).unwrap();
        drop(stale_file);

        let did_run = with_local_lock(temp_directory.path(), || {
            assert!(lock_path.exists());
            Ok(true)
        })
        .unwrap();
        assert!(did_run);
        assert!(!lock_path.exists());
    }

    #[test]
    fn lock_file_is_removed_even_when_operation_fails() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        let error = with_local_lock::<()>(temp_directory.path(), || bail!("simulated failure"))
            .unwrap_err();
        assert!(format!("{error:#}").contains("simulated failure"));
        assert!(!lock_path.exists());
    }

    #[test]
    fn drop_does_not_unlink_replacement_lock_after_eviction() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        let old_guard = try_create_lock(&lock_path).unwrap();

        fs::remove_file(&lock_path).unwrap();
        let new_guard = try_create_lock(&lock_path).unwrap();

        drop(old_guard);
        assert!(
            lock_path.exists(),
            "old lock guard must not unlink replacement lock"
        );

        drop(new_guard);
        assert!(!lock_path.exists());
    }

    #[test]
    fn acquire_lock_times_out_when_fresh_lock_is_held() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        let held_guard = try_create_lock(&lock_path).unwrap();

        let error = acquire_lock_with_timeout(&lock_path, Duration::from_millis(20)).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("timed out") && message.contains(LOCAL_LOCK_FILE),
            "{message}"
        );

        drop(held_guard);
        assert!(!lock_path.exists());
    }

    #[test]
    fn stale_evict_guard_does_not_block_stale_lock_eviction() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        let eviction_path = eviction_lock_path(&lock_path);
        let past = SystemTime::now() - Duration::from_secs(60);

        for path in [&lock_path, &eviction_path] {
            let file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
                .unwrap();
            file.set_modified(past).unwrap();
        }

        let did_run = with_local_lock(temp_directory.path(), || Ok(true)).unwrap();
        assert!(did_run);
        assert!(!lock_path.exists());
        assert!(!eviction_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn stale_dangling_symlink_lock_is_evicted() {
        let temp_directory = tempfile::tempdir().unwrap();
        let lock_path = temp_directory.path().join(LOCAL_LOCK_FILE);
        std::os::unix::fs::symlink("/nonexistent/stale-target", &lock_path).unwrap();
        let status = std::process::Command::new("touch")
            .args(["-h", "-t", "202001010000"])
            .arg(&lock_path)
            .status()
            .unwrap();
        assert!(status.success());

        let guard = acquire_lock_with_timeout(&lock_path, Duration::from_millis(100)).unwrap();
        assert!(lock_path.exists());
        drop(guard);
        assert!(!lock_path.exists());
    }
}
