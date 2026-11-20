//! Pure readers of git's output and guards for its input, so the commands
//! that run git stay thin.

use anyhow::{Context, Result, bail};

/// Whether `value` is a full commit id: exactly 40 (SHA-1) or 64 (SHA-256)
/// hex digits. Anything else is refused before it reaches git: an option like
/// `--output`, a branch name, or a short id, which git looks up as a branch
/// name first.
#[must_use]
pub fn is_commit_id(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// Whether `git cat-file --batch` reads `path` exactly as given. It ends a
/// request at a newline, drops a carriage return before that newline, and
/// stops a name at a NUL byte, so a path holding any of them would read a
/// different file.
#[must_use]
pub fn is_batch_request_safe(path: &str) -> bool {
    !path.contains(['\n', '\r', '\0'])
}

/// The file in `git cat-file --batch`'s answer to one request, or `None` when
/// the object is missing or is not a file (a directory or a submodule).
pub fn parse_batch_blob(mut output: Vec<u8>) -> Result<Option<Vec<u8>>> {
    let header_end = output
        .iter()
        .position(|byte| *byte == b'\n')
        .context("git cat-file printed no header")?;
    let header = std::str::from_utf8(&output[..header_end])
        .context("git cat-file printed a header that is not text")?;
    if header.ends_with(" missing") || header.ends_with(" ambiguous") {
        return Ok(None);
    }
    let mut fields = header.split(' ');
    let (_, kind, size) = (fields.next(), fields.next(), fields.next());
    if kind != Some("blob") {
        return Ok(None);
    }
    let size: usize = size
        .context("git cat-file printed no size")?
        .parse()
        .context("git cat-file printed a size that is not a number")?;
    let body_start = header_end + 1;
    let body_end = body_start
        .checked_add(size)
        .context("git cat-file printed a size too large to hold")?;
    if body_end > output.len() {
        bail!("git cat-file's answer was cut short");
    }
    // The file is cut out of `output` in place rather than copied.
    output.truncate(body_end);
    output.drain(..body_start);
    Ok(Some(output))
}

/// The renamed files in `git diff-index --name-status -z -M`'s output, as
/// `(old, new)` paths. Copies are not renames: the original still exists.
#[must_use]
pub fn parse_renames(output: &[u8]) -> Vec<(String, String)> {
    let mut fields = output
        .split(|byte| *byte == 0)
        .filter(|field| !field.is_empty());
    let mut renames = Vec::new();
    while let Some(status) = fields.next() {
        let path_count = if matches!(status.first(), Some(b'R' | b'C')) {
            2
        } else {
            1
        };
        let paths: Vec<String> = fields
            .by_ref()
            .take(path_count)
            .map(|path| String::from_utf8_lossy(path).into_owned())
            .collect();
        if let (Some(b'R'), [old, new]) = (status.first(), paths.as_slice()) {
            renames.push((old.clone(), new.clone()));
        }
    }
    renames
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_ids_are_full_hex_object_ids() {
        assert!(!is_commit_id("abc123"));
        assert!(is_commit_id(&"f".repeat(40)));
        assert!(!is_commit_id("--help"));
        assert!(!is_commit_id("main"));
        assert!(!is_commit_id("abc"));
    }

    #[test]
    fn commit_ids_are_exactly_40_or_64_digits_long() {
        // A shorter id is looked up as a branch name first, so a branch a
        // pull request names could stand in for it.
        for length in [3, 4, 39, 41, 63, 65] {
            assert!(!is_commit_id(&"a".repeat(length)), "{length}");
        }
        assert!(is_commit_id(&"a".repeat(40)));
        assert!(is_commit_id(&"a".repeat(64)));
    }

    #[test]
    fn an_absurd_size_is_an_error() {
        let output = format!("0123 blob {}\nab", usize::MAX).into_bytes();
        assert!(parse_batch_blob(output).is_err());
    }

    #[test]
    fn reads_renames_with_spaces_in_their_paths() {
        assert_eq!(
            parse_renames(b"R100\0old dir/a b.rs\0new dir/a b.rs\0"),
            [("old dir/a b.rs".to_owned(), "new dir/a b.rs".to_owned())]
        );
    }

    #[test]
    fn paths_git_would_cut_short_do_not_fit_a_batch_request() {
        assert!(is_batch_request_safe("src/a b.rs"));
        for path in ["a\nb", "a.txt\r", "a\rb", "a\0b"] {
            assert!(!is_batch_request_safe(path), "{path:?}");
        }
    }

    #[test]
    fn reads_a_blob_from_a_batch_answer() {
        assert_eq!(
            parse_batch_blob(b"0123 blob 3\nab\n\n".to_vec()).unwrap(),
            Some(b"ab\n".to_vec())
        );
    }

    #[test]
    fn a_missing_object_or_a_directory_is_none() {
        assert_eq!(
            parse_batch_blob(b"abc123:x.rs missing\n".to_vec()).unwrap(),
            None
        );
        assert_eq!(
            parse_batch_blob(b"0123 tree 30\nxxxx\n".to_vec()).unwrap(),
            None
        );
    }

    #[test]
    fn a_cut_short_answer_is_an_error() {
        assert!(parse_batch_blob(b"0123 blob 10\nab".to_vec()).is_err());
        assert!(parse_batch_blob(b"".to_vec()).is_err());
    }

    #[test]
    fn reads_renames_and_skips_other_changes() {
        let output = b"M\0src/a.rs\0R087\0old/name.rs\0new/name.rs\0C100\0x.rs\0y.rs\0D\0gone.rs\0";
        assert_eq!(
            parse_renames(output),
            [("old/name.rs".to_owned(), "new/name.rs".to_owned())]
        );
    }
}
