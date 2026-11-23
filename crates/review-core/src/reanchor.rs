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
mod tests;
