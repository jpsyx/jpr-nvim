//! Crash-safe file reads and replaces.

use std::fs;
use std::io::{ErrorKind, Write};
use std::path::Path;

use anyhow::{Context, Result};

/// The bytes of `path`, or `None` when it does not exist.
pub fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Replaces `dir/name` with `bytes`: writes and flushes a temporary file that
/// is unique to this call, renames it over the target, then flushes `dir` so
/// the rename itself survives a power loss. Concurrent writers each rename a
/// whole file, so the last rename wins and no reader sees a mix.
pub fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    let target = dir.join(name);
    let mut temporary = tempfile::Builder::new()
        .prefix(&format!(".{name}."))
        .suffix(".tmp")
        .tempfile_in(dir)
        .with_context(|| format!("creating a temporary file for {}", target.display()))?;
    temporary
        .write_all(bytes)
        .and_then(|()| temporary.as_file().sync_all())
        .with_context(|| format!("writing {}", temporary.path().display()))?;
    // On failure the error owns the temporary file, and dropping it deletes it.
    temporary
        .persist(&target)
        .map_err(|error| error.error)
        .with_context(|| format!("replacing {}", target.display()))?;
    sync_dir(dir)
}

/// Flushes `dir`'s entries (the names in it) to disk.
pub fn sync_dir(dir: &Path) -> Result<()> {
    fs::File::open(dir)
        .and_then(|handle| handle.sync_all())
        .with_context(|| format!("flushing {}", dir.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_missing_file_reads_as_none() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_bytes(&dir.path().join("absent.json")).unwrap(), None);
    }

    #[test]
    fn write_replaces_the_file_and_leaves_only_it() {
        let dir = tempfile::tempdir().unwrap();
        write_atomic(dir.path(), "state.json", b"old").unwrap();
        write_atomic(dir.path(), "state.json", b"new").unwrap();
        assert_eq!(
            read_bytes(&dir.path().join("state.json")).unwrap().unwrap(),
            b"new"
        );
        assert_eq!(file_names(dir.path()), ["state.json"]);
    }

    #[test]
    fn a_failed_replace_removes_its_temporary_file() {
        let dir = tempfile::tempdir().unwrap();
        // A non-empty directory where the file belongs makes the rename fail.
        fs::create_dir_all(dir.path().join("state.json").join("child")).unwrap();
        let error = write_atomic(dir.path(), "state.json", b"new").unwrap_err();
        assert!(format!("{error:#}").contains("state.json"), "{error:#}");
        assert_eq!(file_names(dir.path()), ["state.json"]);
    }

    #[test]
    fn a_stale_temporary_file_does_not_block_a_write() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(".state.json.crashed.tmp"), b"half").unwrap();
        write_atomic(dir.path(), "state.json", b"new").unwrap();
        assert_eq!(
            read_bytes(&dir.path().join("state.json")).unwrap().unwrap(),
            b"new"
        );
    }

    #[test]
    fn a_directory_can_be_synced() {
        let dir = tempfile::tempdir().unwrap();
        sync_dir(dir.path()).unwrap();
    }
}
