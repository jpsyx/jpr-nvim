//! The agent contract printed by `jpr-review guide`.

/// Returns the interactive agent contract printed by `jpr-review guide`.
#[must_use]
pub const fn build_agent_guide() -> &'static str {
    "# jpr-review Agent Contract\n\
\n\
## Role & Hard Boundaries\n\
- You are working inside the checked-out PR worktree on local review threads.\n\
- Never push (`git push` is forbidden).\n\
- Never touch GitHub (`gh pr comment`, `gh pr review`, `gh api` mutations are forbidden; `jpr-review reply` refuses GitHub thread IDs).\n\
\n\
## Handling Reviewer Comments (`:Jpr send`)\n\
1. Classify each numbered `[loc-...]` item before acting:\n\
   - **Question**: answer directly with concrete file paths and symbol references. Make no code edits.\n\
   - **Change Request**: make the minimal, focused edit in the PR worktree, run relevant checks/tests, and create a local git commit.\n\
2. Reply to **every** item using:\n\
   `jpr-review reply <thread-id> --body \"<reply>\"`\n\
   (When `$JPR_SOCKET` is set in your environment, `jpr-review reply` uses it automatically.)\n\
3. Keep replies direct and matter-of-fact (1-3 sentences).\n\
   - Default reply for a completed change request: `Done. (<short-sha>)`\n\
   - Add one short sentence after `Done. (<short-sha>)` only if non-obvious behavior changed or a follow-up check failed.\n\
\n\
## Running a Pre-pass Review (`:Jpr prepass`)\n\
1. Inspect `git diff <base>..HEAD` in the PR worktree and verify surrounding callers and invariants before flagging anything.\n\
2. Write only high-signal findings as a JSON array on stdin to `jpr-review prepass-write`:\n\
   ```sh\n\
   jpr-review prepass-write <<'EOF'\n\
   [\n\
     {\n\
       \"anchor\": {\n\
         \"file\": \"path/to/file\",\n\
         \"kind\": \"line\" | \"range\" | \"file\" | \"pr\",\n\
         \"side\": \"RIGHT\" | \"LEFT\",\n\
         \"start\": 10,\n\
         \"end\": 12\n\
       },\n\
       \"body\": \"[high] State the concrete failure mode or trade-off in 1-4 sentences.\"\n\
     }\n\
   ]\n\
   EOF\n\
   ```\n\
   - Severity tags: `[critical]`, `[high]`, `[medium]`, `[low]`, or `[nit]`.\n\
   - For `kind: \"file\"` or `kind: \"pr\"`, omit `start` and `end` (and omit `file` for `\"pr\"`).\n\
   - If zero issues stand up to verification, write `[]` and state that briefly.\n"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_states_classification_reply_commit_prepass_and_github_prohibition() {
        let guide = build_agent_guide();
        assert!(
            guide.contains("jpr-review reply <thread-id> --body"),
            "{guide}"
        );
        assert!(guide.contains("Done."), "{guide}");
        assert!(guide.contains("Never push"), "{guide}");
        assert!(guide.contains("Never touch GitHub"), "{guide}");
        assert!(guide.contains("jpr-review prepass-write"), "{guide}");
        assert!(
            !guide.contains('\u{2014}'),
            "guide must not contain em dashes"
        );
    }
}
