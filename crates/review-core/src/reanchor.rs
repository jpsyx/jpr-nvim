//! Snapshot capture and line-shift re-anchoring for local threads.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, bail};
use review_model::{Anchor, AnchorKind, ChangedFile, LocalAnchorUpdate, Origin, Side, Thread};

/// Extracts the exact lines covered by `anchor` (`start..=end`, 1-based) from
/// `text`, returning `None` for non-line anchors or out-of-bounds spans.
#[must_use]
pub fn extract_snapshot_from_text(text: &str, anchor: &Anchor) -> Option<String> {
    if !matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range) {
        return None;
    }
    let start_line = anchor.start.or(anchor.end)?;
    let end_line = anchor.end.unwrap_or(start_line);
    let start = usize::try_from(start_line).ok()?;
    let end = usize::try_from(end_line).ok()?;
    if start == 0 || end < start {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    let slice = lines.get((start - 1)..end)?;
    Some(slice.join("\n"))
}

/// Re-anchors a local `Side::Right` line or range thread against `updated_text`
/// using its saved `snapshot`. Returns `true` when `anchor` or `outdated` changed.
pub fn reanchor_thread_in_text(thread: &mut Thread, updated_text: &str) -> bool {
    if thread.origin != Origin::Local
        || thread.anchor.side != Side::Right
        || !matches!(thread.anchor.kind, AnchorKind::Line | AnchorKind::Range)
    {
        return false;
    }
    let Some(snapshot) = thread.anchor.snapshot.as_deref() else {
        return false;
    };
    if snapshot.is_empty() {
        return false;
    }
    let current_start =
        usize::try_from(thread.anchor.start.or(thread.anchor.end).unwrap_or(1)).unwrap_or(1);
    let file_lines: Vec<&str> = updated_text.lines().collect();
    let target_lines: Vec<&str> = snapshot
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .collect();
    let matched_start = find_closest_window(&file_lines, &target_lines, current_start, false)
        .or_else(|| {
            if snapshot.trim().is_empty() {
                None
            } else {
                find_closest_window(&file_lines, &target_lines, current_start, true)
            }
        });
    let Some(new_start_index) = matched_start else {
        let was_outdated = thread.outdated;
        thread.outdated = true;
        return !was_outdated;
    };
    let new_start = u64::try_from(new_start_index + 1).unwrap_or(u64::MAX);
    let new_end = u64::try_from(new_start_index + target_lines.len()).unwrap_or(u64::MAX);
    let did_change = thread.anchor.start != Some(new_start)
        || thread.anchor.end != Some(new_end)
        || thread.outdated;
    thread.anchor.start = Some(new_start);
    thread.anchor.end = Some(new_end);
    thread.outdated = false;
    did_change
}

fn find_closest_window(
    haystack: &[&str],
    needle: &[&str],
    preferred_one_based: usize,
    use_trimmed: bool,
) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    let preferred_index = preferred_one_based.saturating_sub(1);
    (0..=(haystack.len() - needle.len()))
        .filter(|&start| {
            windows_equal(
                &haystack[start..(start + needle.len())],
                needle,
                use_trimmed,
            )
        })
        .min_by_key(|&start| start.abs_diff(preferred_index))
}

fn windows_equal(left: &[&str], right: &[&str], use_trimmed: bool) -> bool {
    left.iter().zip(right).all(|(left_line, right_line)| {
        if use_trimmed {
            left_line.trim() == right_line.trim()
        } else {
            left_line == right_line
        }
    })
}

/// Orders reversed `start`/`end` line bounds on `Line` and `Range` anchors.
#[must_use]
pub const fn normalize_line_bounds(mut anchor: Anchor) -> Anchor {
    if matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range)
        && let (Some(start), Some(end)) = (anchor.start, anchor.end)
    {
        let (first, last) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        anchor.start = Some(first);
        anchor.end = Some(last);
    }
    anchor
}

pub(crate) enum AnchorDiskState {
    Missing,
    UnreadableText,
    Utf8(String),
}

pub(crate) fn apply_anchor_update(
    thread: &mut Thread,
    update: &LocalAnchorUpdate,
    disk_state: &AnchorDiskState,
) -> bool {
    if update.start == 0 || update.end == 0 {
        return false;
    }
    let previous_anchor = thread.anchor.clone();
    let was_outdated = thread.outdated;
    let first = update.start.min(update.end);
    let last = update.start.max(update.end);
    thread.anchor.start = Some(first);
    thread.anchor.end = Some(last);
    thread.anchor.kind = if first == last {
        AnchorKind::Line
    } else {
        AnchorKind::Range
    };
    match disk_state {
        AnchorDiskState::Missing => {
            thread.anchor.snapshot = None;
            thread.outdated = true;
        }
        AnchorDiskState::UnreadableText => {
            thread.anchor.snapshot = None;
            thread.outdated = false;
        }
        AnchorDiskState::Utf8(content) => {
            thread.anchor.snapshot = extract_snapshot_from_text(content, &thread.anchor);
            thread.outdated = thread.anchor.snapshot.is_none();
        }
    }
    thread.anchor != previous_anchor || thread.outdated != was_outdated
}

/// Validates that a non-PR `anchor` targets a file present in `files`.
pub fn validate_anchor_file(files: &[ChangedFile], anchor: &Anchor) -> Result<()> {
    if anchor.kind == AnchorKind::Pr {
        return Ok(());
    }
    let Some(path) = anchor.file.as_deref() else {
        bail!("code comment anchor requires a file path");
    };
    if !files.iter().any(|file| file.path == path) {
        bail!("{path} is not a file this pull request changes");
    }
    Ok(())
}

pub(crate) fn collect_changed_digest_paths(
    previous_digests: &BTreeMap<String, u64>,
    current_digests: &BTreeMap<String, u64>,
) -> Vec<String> {
    let mut changed_paths = BTreeSet::new();
    for (path, digest) in current_digests {
        if previous_digests.get(path) != Some(digest) {
            changed_paths.insert(path.clone());
        }
    }
    for path in previous_digests.keys() {
        if !current_digests.contains_key(path) {
            changed_paths.insert(path.clone());
        }
    }
    changed_paths.into_iter().collect()
}

#[must_use]
pub(crate) fn hash_bounded_file_bytes(bytes: &[u8], max_bytes: usize) -> u64 {
    let prefix = &bytes[..bytes.len().min(max_bytes)];
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for &byte in prefix {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3_u64);
    }
    let total_len = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
    for byte in total_len.to_le_bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3_u64);
    }
    hash
}

fn has_forbidden_path_char(ch: char) -> bool {
    ch.is_control()
        || matches!(
            ch,
            '\u{2028}' | '\u{2029}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'
        )
}

/// Validates that `path` is a safe repository-relative path with no traversal,
/// backslashes, control or bidi-override characters, or `.git` segments.
pub fn validate_safe_relative_path(path: &str) -> Result<()> {
    if path.is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || path.chars().any(has_forbidden_path_char)
        || path.split('/').any(|segment| {
            segment.is_empty()
                || segment == "."
                || segment == ".."
                || segment.eq_ignore_ascii_case(".git")
        })
    {
        bail!("invalid repository-relative path {path:?}");
    }
    Ok(())
}

/// Strips untrusted snapshots and validates paths and line bounds on a pre-pass
/// [`Anchor`].
pub fn normalize_prepass_anchor(mut anchor: Anchor) -> Result<Anchor> {
    anchor.snapshot = None;
    if anchor.kind == AnchorKind::Pr {
        return Ok(Anchor::pr());
    }
    let Some(path) = anchor.file.as_deref() else {
        bail!("code comment anchor requires a file path");
    };
    validate_safe_relative_path(path)?;
    if anchor.kind == AnchorKind::File {
        anchor.start = None;
        anchor.end = None;
        return Ok(anchor);
    }
    let (Some(start), Some(end)) = (anchor.start, anchor.end) else {
        bail!("line and range anchors require start and end line numbers");
    };
    if start == 0 || end == 0 {
        bail!("anchor line numbers must be at least 1");
    }
    Ok(normalize_line_bounds(anchor))
}

#[cfg(test)]
mod tests {
    use review_model::{Anchor, Origin, Side, Thread, ThreadState};

    use super::*;

    fn create_local_line_thread(start: u64, end: u64, snapshot: &str) -> Thread {
        let mut anchor = Anchor::range("src/lib.rs", Side::Right, start, end);
        anchor.snapshot = Some(snapshot.to_owned());
        Thread {
            id: "loc-1".into(),
            origin: Origin::Local,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: Vec::new(),
            agent: None,
            promoted_to: None,
        }
    }

    #[test]
    fn captures_inclusive_line_slice_snapshot() {
        let text = "fn a() {}\nlet count = 1;\nlet total = count + 2;\n";
        let anchor = Anchor::range("src/lib.rs", Side::Right, 2, 3);
        assert_eq!(
            extract_snapshot_from_text(text, &anchor).as_deref(),
            Some("let count = 1;\nlet total = count + 2;")
        );
        assert_eq!(extract_snapshot_from_text(text, &Anchor::pr()), None);
        assert_eq!(
            extract_snapshot_from_text(text, &Anchor::line("src/lib.rs", 99)),
            None
        );
    }

    #[test]
    fn shifts_anchor_down_when_lines_are_inserted_above() {
        let updated_text =
            "// header\n// second\nfn a() {}\nlet count = 1;\nlet total = count + 2;\n";
        let mut thread = create_local_line_thread(2, 3, "let count = 1;\nlet total = count + 2;");
        let did_change = reanchor_thread_in_text(&mut thread, updated_text);
        assert!(did_change);
        assert_eq!(thread.anchor.start, Some(4));
        assert_eq!(thread.anchor.end, Some(5));
        assert!(!thread.outdated);
    }

    #[test]
    fn falls_back_to_trimmed_match_when_indentation_changes() {
        let reindented_text = "fn wrap() {\n    let count = 1;\n    let total = count + 2;\n}\n";
        let mut thread = create_local_line_thread(1, 2, "let count = 1;\nlet total = count + 2;");
        thread.outdated = true;
        let did_change = reanchor_thread_in_text(&mut thread, reindented_text);
        assert!(did_change);
        assert_eq!(thread.anchor.start, Some(2));
        assert_eq!(thread.anchor.end, Some(3));
        assert!(!thread.outdated);
    }

    #[test]
    fn picks_closest_duplicate_match_and_marks_deleted_snapshot_outdated() {
        let duplicate_text = "return Ok(());\nfn mid() {}\nreturn Ok(());\n";
        let mut thread = create_local_line_thread(3, 3, "return Ok(());");
        assert!(!reanchor_thread_in_text(&mut thread, duplicate_text));
        assert_eq!(thread.anchor.start, Some(3));

        let removed_text = "fn mid() {}\n";
        assert!(reanchor_thread_in_text(&mut thread, removed_text));
        assert!(thread.outdated);
        assert!(!reanchor_thread_in_text(&mut thread, removed_text));
    }

    #[test]
    fn preserves_trailing_blank_line_when_reanchoring_multiline_snapshot() {
        let original = "fn a() {}\nlet count = 1;\n\nfn b() {}\n";
        let anchor = Anchor::range("src/lib.rs", Side::Right, 2, 3);
        let snapshot = extract_snapshot_from_text(original, &anchor).unwrap();
        assert_eq!(snapshot, "let count = 1;\n");

        let shifted = "// added\nfn a() {}\nlet count = 1;\n\nfn b() {}\n";
        let mut thread = create_local_line_thread(2, 3, &snapshot);
        assert!(reanchor_thread_in_text(&mut thread, shifted));
        assert_eq!(thread.anchor.start, Some(3));
        assert_eq!(thread.anchor.end, Some(4));
    }

    #[test]
    fn uses_end_line_when_line_anchor_has_no_start() {
        let text = "return Ok(());\nfn mid() {}\nreturn Ok(());\n";
        let mut thread = create_local_line_thread(3, 3, "return Ok(());");
        thread.anchor.kind = AnchorKind::Line;
        thread.anchor.start = None;
        thread.anchor.end = Some(3);
        assert!(reanchor_thread_in_text(&mut thread, text));
        assert_eq!(thread.anchor.start, Some(3));
        assert_eq!(thread.anchor.end, Some(3));
    }

    #[test]
    fn whitespace_only_snapshot_does_not_match_arbitrary_blank_lines_via_trimmed_fallback() {
        let text = "\nfn a() {}\n    \n";
        let mut thread = create_local_line_thread(3, 3, "  ");
        assert!(reanchor_thread_in_text(&mut thread, text));
        assert!(thread.outdated);
    }

    #[test]
    fn apply_anchor_update_keeps_outdated_when_lines_are_out_of_bounds() {
        let mut thread = create_local_line_thread(2, 2, "old line");
        thread.outdated = true;
        let short_disk = AnchorDiskState::Utf8("only one line\n".to_owned());

        let changed = apply_anchor_update(
            &mut thread,
            &LocalAnchorUpdate {
                thread_id: "loc-1".into(),
                start: 5,
                end: 5,
            },
            &short_disk,
        );
        assert!(changed);
        assert!(thread.outdated);
        assert_eq!(thread.anchor.snapshot, None);

        let cleared = apply_anchor_update(
            &mut thread,
            &LocalAnchorUpdate {
                thread_id: "loc-1".into(),
                start: 1,
                end: 1,
            },
            &short_disk,
        );
        assert!(cleared);
        assert!(!thread.outdated);
        assert_eq!(thread.anchor.snapshot.as_deref(), Some("only one line"));
    }

    #[test]
    fn validate_safe_relative_path_rejects_control_and_bidi_characters() {
        for bad_path in [
            "src/a\nb.rs",
            "src/a\rb.rs",
            "src/a\tb.rs",
            "src/a\x1bb.rs",
            "src/a\u{009b}b.rs",
            "src/a\u{2028}b.rs",
            "src/a\u{202e}b.rs",
            "src/a\u{2066}b.rs",
        ] {
            assert!(
                validate_safe_relative_path(bad_path).is_err(),
                "expected {bad_path:?} to fail validation"
            );
        }
        assert!(validate_safe_relative_path("src/valid_file.rs").is_ok());
    }
}
