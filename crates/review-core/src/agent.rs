//! Eligibility filtering and prompt builders for the interactive agent loop.

use std::fmt::Write;

use review_model::{
    AgentThreadState, Anchor, AnchorKind, LocalReviewContext, Origin, PullRequest, Side, Thread,
    ThreadState,
};

/// Whether `thread` should be sent on `:Jpr send`: local, open, `Unsent`, and
/// ending with a reviewer-authored message.
#[must_use]
pub fn is_thread_dispatchable(thread: &Thread) -> bool {
    thread.origin == Origin::Local
        && thread.state == ThreadState::Open
        && thread.agent == Some(AgentThreadState::Unsent)
        && thread
            .messages
            .last()
            .is_some_and(|message| message.viewer_did_author)
}

/// Selects dispatchable local threads, or only `only_thread_id` when given
/// (for popup `s`, allowing any open local thread with messages to be sent or
/// re-sent on demand).
#[must_use]
pub fn select_dispatchable_threads<'a>(
    threads: &'a [Thread],
    only_thread_id: Option<&str>,
) -> Vec<&'a Thread> {
    if let Some(target_id) = only_thread_id {
        return threads
            .iter()
            .filter(|thread| {
                thread.id == target_id
                    && thread.origin == Origin::Local
                    && thread.state == ThreadState::Open
                    && !thread.messages.is_empty()
            })
            .collect();
    }
    threads
        .iter()
        .filter(|thread| is_thread_dispatchable(thread))
        .collect()
}

/// Formats an [`Anchor`] as `file:L7`, `file:L7-9` (with ` (base)` for `LEFT`),
/// `file`, or `PR`.
#[must_use]
pub fn build_anchor_label_from_anchor(anchor: &Anchor) -> String {
    let side_suffix = if anchor.side == Side::Left {
        " (base)"
    } else {
        ""
    };
    match anchor.kind {
        AnchorKind::Pr => "PR".to_owned(),
        AnchorKind::File => anchor.file.clone().unwrap_or_else(|| "file".to_owned()),
        AnchorKind::Line => format!(
            "{}:L{}{side_suffix}",
            anchor.file.as_deref().unwrap_or("file"),
            anchor.end.or(anchor.start).unwrap_or(1)
        ),
        AnchorKind::Range => format!(
            "{}:L{}-{}{side_suffix}",
            anchor.file.as_deref().unwrap_or("file"),
            anchor.start.unwrap_or(1),
            anchor.end.or(anchor.start).unwrap_or(1)
        ),
    }
}

/// Builds the single-item or numbered-batch prompt for `threads` on `pr`.
#[must_use]
pub fn build_send_prompt_from_threads(pr: &PullRequest, threads: &[&Thread]) -> String {
    let mut output = String::new();
    let thread_count = threads.len();
    let noun = if thread_count == 1 {
        "comment"
    } else {
        "comments"
    };
    let _ = writeln!(
        output,
        "Address {thread_count} local review {noun} on PR #{} ({}/{}).",
        pr.number, pr.owner, pr.repo
    );
    output.push_str("First run `jpr-review guide` and follow every rule in that contract.\n\n");
    for (index, thread) in threads.iter().enumerate() {
        append_thread_item(&mut output, index + 1, thread);
    }
    output.push_str(
        "Reply to every item above with `jpr-review reply <thread-id> --body \"...\"`. Never push and never touch GitHub.",
    );
    output
}

/// Builds the single-item or numbered-batch prompt for `threads` in an unlinked
/// local worktree review.
#[must_use]
pub fn build_local_send_prompt_from_threads(
    context: &LocalReviewContext,
    threads: &[&Thread],
) -> String {
    let mut output = String::new();
    let thread_count = threads.len();
    let noun = if thread_count == 1 {
        "comment"
    } else {
        "comments"
    };
    let short_sha = context.base_sha.get(..7).unwrap_or(&context.base_sha);
    let _ = writeln!(
        output,
        "Address {thread_count} local review {noun} on local branch `{}` against `{}` (`{short_sha}`).",
        context.branch, context.base_ref
    );
    output.push_str("First run `jpr-review guide` and follow every rule in that contract.\n\n");
    for (index, thread) in threads.iter().enumerate() {
        append_thread_item(&mut output, index + 1, thread);
    }
    output.push_str(
        "Reply to every item above with `jpr-review reply <thread-id> --body \"...\"`. Keep edits unstaged in this worktree for the reviewer to stage and commit. Never commit, never push, and never touch GitHub.",
    );
    output
}

/// Builds the `:Jpr prepass` prompt for an unlinked local worktree review.
#[must_use]
pub fn build_local_prepass_prompt_from_context(context: &LocalReviewContext) -> String {
    let short_sha = context.base_sha.get(..7).unwrap_or(&context.base_sha);
    format!(
        "Run a local pre-pass code review of local branch `{}` against `{}` (`{short_sha}`).\n\
         1. Run `jpr-review guide` first and follow the Pre-pass section.\n\
         2. Inspect the diff against `{}` in this worktree and verify surrounding callers before flagging anything.\n\
         3. Write only high-signal findings (`[critical]`, `[high]`, `[medium]`, `[low]`, or `[nit]`) as JSON to `jpr-review prepass-write`.\n\
         4. Keep edits unstaged in this worktree for the reviewer to stage and commit. Never commit, never push, and never touch GitHub.",
        context.branch, context.base_ref, context.base_sha
    )
}

/// Derives a deterministic 64-bit seed from a local review's branch and base ref.
#[must_use]
pub(crate) fn seed_from_local_context(context: &LocalReviewContext) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in context
        .branch
        .bytes()
        .chain(std::iter::once(0))
        .chain(context.base_ref.bytes())
    {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3_u64);
    }
    hash
}

fn append_thread_item(output: &mut String, item_number: usize, thread: &Thread) {
    let label = build_anchor_label_from_anchor(&thread.anchor);
    let _ = writeln!(output, "{item_number}. [{}] {label}", thread.id);
    if let Some(snapshot) = thread.anchor.snapshot.as_deref()
        && !snapshot.is_empty()
    {
        for code_line in snapshot.lines() {
            let _ = writeln!(output, "   > {code_line}");
        }
    }
    if thread.messages.len() > 1 {
        output.push_str("   Thread so far:\n");
        for prior in &thread.messages[..thread.messages.len() - 1] {
            let _ = writeln!(output, "     @{}: {}", prior.author, prior.body.trim());
        }
    }
    if let Some(latest) = thread.messages.last() {
        let _ = writeln!(output, "   New comment: {}\n", latest.body.trim());
    }
}

/// Builds the `:Jpr prepass` prompt instructing the agent to critique `pr` and
/// record findings as local threads through `jpr-review prepass-write`.
#[must_use]
pub fn build_prepass_prompt_from_pr(pr: &PullRequest) -> String {
    format!(
        "Run a local pre-pass code review of PR #{} ({}/{}: {:?}, base `{}` -> head `{}`).\n\
         1. Run `jpr-review guide` first and follow the Pre-pass section.\n\
         2. Inspect the diff against `{}` in this worktree and verify surrounding callers before flagging anything.\n\
         3. Write only high-signal findings (`[critical]`, `[high]`, `[medium]`, `[low]`, or `[nit]`) as JSON to `jpr-review prepass-write`.\n\
         4. Never push and never touch GitHub.",
        pr.number, pr.owner, pr.repo, pr.title, pr.base_ref, pr.head_ref, pr.base_sha
    )
}

/// Builds a prompt instructing the agent to resolve stash-restore merge conflicts
/// in `conflicted_paths` without pushing or touching GitHub.
#[must_use]
pub fn build_conflict_prompt_from_paths(pr: &PullRequest, conflicted_paths: &[String]) -> String {
    let mut output = String::new();
    let _ = writeln!(
        output,
        "PR #{} ({}/{}) fast-forwarded to `{}` and restoring stashed local edits conflicted in:",
        pr.number, pr.owner, pr.repo, pr.head_sha
    );
    for path in conflicted_paths {
        let _ = writeln!(output, "- `{path}`");
    }
    output.push_str(
        "\nResolve any conflict markers in those files (or inspect `git stash` if `git stash apply` aborted on an untracked file collision before writing conflict markers) while preserving both the upstream PR update and the local edits, stage the resolved files, and leave `git stash` intact if anything remains unclear. Never push and never touch GitHub.",
    );
    output
}

const fn splitmix64(mut state: u64) -> u64 {
    state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    state = (state ^ (state >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    state = (state ^ (state >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    state ^ (state >> 31)
}

/// Formats a deterministic RFC 4122 v4 UUID from `(pr_number, timestamp, counter)`.
#[must_use]
pub(crate) fn build_uuid_v4_from_seed(pr_number: u64, timestamp: u64, counter: u64) -> String {
    let lane_a = splitmix64(
        pr_number.wrapping_mul(0x517C_C1B7_2722_0A95)
            ^ timestamp.rotate_left(17)
            ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15),
    );
    let lane_b = splitmix64(
        lane_a
            ^ counter.rotate_left(29)
            ^ timestamp.wrapping_mul(0xBF58_476D_1CE4_E5B9)
            ^ pr_number.rotate_left(41),
    );
    let mut bytes = [0_u8; 16];
    bytes[..8].copy_from_slice(&lane_a.to_be_bytes());
    bytes[8..].copy_from_slice(&lane_b.to_be_bytes());
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:04x}{:08x}",
        u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        u16::from_be_bytes([bytes[4], bytes[5]]),
        u16::from_be_bytes([bytes[6], bytes[7]]),
        u16::from_be_bytes([bytes[8], bytes[9]]),
        u16::from_be_bytes([bytes[10], bytes[11]]),
        u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
    )
}

#[cfg(test)]
mod tests;
