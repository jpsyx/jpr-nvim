//! The two sides of every diff: the base from git, the current file from disk.

use std::collections::{HashMap, HashSet};

use anyhow::{Error, Result, anyhow, bail};
use review_diff::{
    FileText, StreamInput, create_file_diff_view_from_texts, create_stream_view_from_inputs,
};
use review_model::{FileDiffView, StreamView, ViewMode};

use super::ReviewSession;

/// The most bytes one side of a diff may hold. A bigger file, such as a
/// generated bundle or a file stored with Git LFS, is reported as too large
/// to show instead of diffed, so it is never kept in memory or line diffed.
const MAX_DIFF_BYTES: usize = 4 * 1024 * 1024;

/// The base side of the diffs, kept while the pull request's base commit
/// stays the same: its merge base, the renames since it, and the base texts
/// read so far.
#[derive(Debug, Default)]
pub(super) struct BaseCache {
    base_sha: String,
    merge_base: String,
    /// New path to old path, for files renamed since the merge base.
    renamed_from: HashMap<String, String>,
    texts: HashMap<String, FileText>,
    /// Paths whose base is over [`MAX_DIFF_BYTES`], remembered so the blob
    /// is not read again.
    too_large: HashSet<String>,
}

impl ReviewSession {
    /// One changed file's diff, for a frontend that draws it on the file
    /// itself or beside its base.
    pub fn file_diff(&mut self, path: &str) -> Result<FileDiffView> {
        let (base, current) = self.file_texts(path)?;
        Ok(create_file_diff_view_from_texts(path, &base, &current))
    }

    /// Every changed file's hunks, in the forge's order, laid out for
    /// `mode`. A file that cannot be read gets a note rather than failing
    /// the whole stream.
    pub fn stream(&mut self, mode: ViewMode) -> Result<StreamView> {
        self.prepare_base()?;
        let files = self.saved.files.clone();
        let mut inputs = Vec::with_capacity(files.len());
        for file in files {
            let content = self
                .file_texts(&file.path)
                .map_err(|error| format!("{error:#}"));
            inputs.push(StreamInput { file, content });
        }
        Ok(create_stream_view_from_inputs(&inputs, mode))
    }

    /// The base and current text of `path`, which must be a file the pull
    /// request changes: the forge's list is the only way in, so a path
    /// from anywhere else is refused before the disk is touched.
    fn file_texts(&mut self, path: &str) -> Result<(FileText, FileText)> {
        if !self.saved.files.iter().any(|file| file.path == path) {
            bail!("{path} is not a file this pull request changes");
        }
        let base = self.base_text(path)?;
        let bytes = self.ports.workspace.file_on_disk(path)?;
        if is_too_large(bytes.as_deref()) {
            return Err(create_too_large_error(path));
        }
        Ok((base, FileText::from_bytes(bytes)))
    }

    /// `path` at the merge base, under its old name when it was renamed.
    fn base_text(&mut self, path: &str) -> Result<FileText> {
        self.prepare_base()?;
        if let Some(text) = self.base_cache.texts.get(path) {
            return Ok(text.clone());
        }
        if self.base_cache.too_large.contains(path) {
            return Err(create_too_large_error(path));
        }
        let old_path = self
            .base_cache
            .renamed_from
            .get(path)
            .map_or(path, String::as_str);
        let bytes = self
            .ports
            .workspace
            .file_at(&self.base_cache.merge_base, old_path)?;
        if is_too_large(bytes.as_deref()) {
            self.base_cache.too_large.insert(path.to_owned());
            return Err(create_too_large_error(path));
        }
        let text = FileText::from_bytes(bytes);
        self.base_cache.texts.insert(path.to_owned(), text.clone());
        Ok(text)
    }

    /// Finds the merge base for the pull request's base commit, unless it is
    /// already known, and starts a fresh cache for it.
    fn prepare_base(&mut self) -> Result<()> {
        let base_sha = self.synced_pr()?.base_sha.clone();
        if base_sha.is_empty() {
            bail!("the base commit is not known yet; sync with GitHub first");
        }
        if !self.base_cache.merge_base.is_empty() && self.base_cache.base_sha == base_sha {
            return Ok(());
        }
        let merge_base = self.ports.workspace.merge_base(&base_sha)?;
        let renamed_from = self
            .ports
            .workspace
            .renames(&merge_base)?
            .into_iter()
            .map(|(old, new)| (new, old))
            .collect();
        self.base_cache = BaseCache {
            base_sha,
            merge_base,
            renamed_from,
            texts: HashMap::new(),
            too_large: HashSet::new(),
        };
        Ok(())
    }
}

/// Whether one side's bytes are over [`MAX_DIFF_BYTES`].
fn is_too_large(bytes: Option<&[u8]>) -> bool {
    bytes.is_some_and(|bytes| bytes.len() > MAX_DIFF_BYTES)
}

/// The error for a file with a side over [`MAX_DIFF_BYTES`], which the
/// stream shows as the file's note.
fn create_too_large_error(path: &str) -> Error {
    anyhow!(
        "{path} is too large to show (over {} MiB)",
        MAX_DIFF_BYTES / (1024 * 1024)
    )
}

#[cfg(test)]
mod tests {
    use review_model::{StreamRow, ViewMode};

    use super::super::test_support::Fakes;
    use super::MAX_DIFF_BYTES;

    /// Fakes where `src/a.rs` changed its second line and `src/b.rs` did not.
    fn create_fakes() -> Fakes {
        let fakes = Fakes::new(100);
        fakes.workspace.put_base("src/a.rs", "one\ntwo\n");
        fakes.workspace.put_disk("src/a.rs", "one\n2\n");
        fakes.workspace.put_base("src/b.rs", "b\n");
        fakes.workspace.put_disk("src/b.rs", "b\n");
        fakes
    }

    #[test]
    fn a_file_diff_compares_the_merge_base_with_the_disk() {
        let mut session = create_fakes().open_synced();
        let diff = session.file_diff("src/a.rs").unwrap();
        let added: Vec<u64> = diff.added.iter().map(|line| line.line).collect();
        assert_eq!(added, [2]);
        assert_eq!(diff.removed[0].lines[0].text, "two");
        assert_eq!(diff.base_text.as_deref(), Some("one\ntwo\n"));
    }

    #[test]
    fn only_changed_files_have_diffs() {
        let mut session = create_fakes().open_synced();
        let error = session.file_diff("../../etc/passwd").unwrap_err();
        assert!(
            error
                .to_string()
                .contains("not a file this pull request changes"),
            "{error}"
        );
    }

    #[test]
    fn a_renamed_file_is_compared_with_its_old_name() {
        let fakes = Fakes::new(100);
        fakes.workspace.rename("src/old.rs", "src/a.rs");
        fakes.workspace.put_base("src/old.rs", "same\n");
        fakes.workspace.put_disk("src/a.rs", "same\n");
        let diff = fakes.open_synced().file_diff("src/a.rs").unwrap();
        assert!(diff.added.is_empty() && diff.removed.is_empty(), "{diff:?}");
    }

    #[test]
    fn the_merge_base_is_looked_up_once_per_base_commit() {
        let fakes = create_fakes();
        let mut session = fakes.open_synced();
        session.file_diff("src/a.rs").unwrap();
        session.stream(ViewMode::Unified).unwrap();
        assert_eq!(fakes.workspace.merge_base_calls(), 1);
    }

    #[test]
    fn the_stream_has_every_file_in_order_with_viewed_files_folded() {
        let stream = create_fakes()
            .open_synced()
            .stream(ViewMode::Split)
            .unwrap();
        let headers: Vec<(&str, bool)> = stream
            .rows
            .iter()
            .filter_map(|row| match row {
                StreamRow::File { path, folded, .. } => Some((path.as_str(), *folded)),
                _ => None,
            })
            .collect();
        assert_eq!(headers, [("src/a.rs", true), ("src/b.rs", false)]);
        assert_eq!(stream.mode, ViewMode::Split);
    }

    #[test]
    fn diffs_wait_for_the_first_sync() {
        let error = create_fakes().open().stream(ViewMode::Unified).unwrap_err();
        assert!(error.to_string().contains("not synced"), "{error}");
    }

    #[test]
    fn a_merge_base_failure_fails_the_stream() {
        let fakes = create_fakes();
        let mut session = fakes.open_synced();
        fakes
            .workspace
            .fail_with(Some("fetching the base commit failed"));
        let error = session.stream(ViewMode::Unified).unwrap_err();
        assert!(error.to_string().contains("fetching"), "{error}");
    }

    #[test]
    fn a_file_too_large_on_disk_is_refused() {
        let fakes = create_fakes();
        fakes
            .workspace
            .put_disk("src/a.rs", &"x".repeat(MAX_DIFF_BYTES + 1));
        let error = fakes.open_synced().file_diff("src/a.rs").unwrap_err();
        assert!(error.to_string().contains("too large to show"), "{error}");
    }

    #[test]
    fn a_file_at_the_size_limit_is_still_shown() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", &"x".repeat(MAX_DIFF_BYTES));
        let diff = fakes.open_synced().file_diff("src/a.rs").unwrap();
        assert_eq!(diff.added.len(), 1);
    }

    #[test]
    fn a_base_too_large_to_show_is_not_kept() {
        let fakes = create_fakes();
        fakes
            .workspace
            .put_base("src/a.rs", &"x".repeat(MAX_DIFF_BYTES + 1));
        let mut session = fakes.open_synced();
        let error = session.file_diff("src/a.rs").unwrap_err();
        assert!(error.to_string().contains("too large to show"), "{error}");
        assert!(!session.base_cache.texts.contains_key("src/a.rs"));
        assert!(session.base_cache.too_large.contains("src/a.rs"));
    }

    #[test]
    fn the_stream_notes_a_file_too_large_to_show_and_goes_on() {
        let fakes = create_fakes();
        fakes
            .workspace
            .put_disk("src/a.rs", &"x".repeat(MAX_DIFF_BYTES + 1));
        let stream = fakes.open_synced().stream(ViewMode::Unified).unwrap();
        let notes: Vec<(&str, &str)> = stream
            .rows
            .iter()
            .filter_map(|row| match row {
                StreamRow::Note { path, text } => Some((path.as_str(), text.as_str())),
                _ => None,
            })
            .collect();
        assert_eq!(notes.len(), 2, "{notes:?}");
        assert_eq!(notes[0].0, "src/a.rs");
        assert!(notes[0].1.contains("too large to show"), "{notes:?}");
        assert_eq!(notes[1], ("src/b.rs", "no changes against the base"));
    }
}
