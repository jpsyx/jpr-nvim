//! Agent profiles, local thread delivery state, dispatch batches, rounds, and
//! pre-pass inputs. Pure data: no IO and no terminal or editor types.

use serde::{Deserialize, Serialize};

use crate::Anchor;

/// Delay in milliseconds between bracketed paste and the submit keystroke, so
/// interactive agent TUIs finish ingesting pasted text before submitting.
pub const DEFAULT_SUBMIT_DELAY_MS: u64 = 200;

/// Delivery status of a local thread in the reviewer-agent loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "state",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AgentThreadState {
    /// Waiting to be sent to the agent (`:Jpr send` or popup `s`).
    Unsent,
    /// Pasted into the agent panel in `round`, awaiting `jpr-review reply`.
    Sent {
        /// 1-based dispatch round number recorded in `rounds.jsonl`.
        round: u64,
    },
    /// Latest message in the thread is the agent's reply.
    Answered,
}

/// Supported interactive coding-agent CLI kinds.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    /// Claude Code (`claude`).
    #[default]
    Claude,
    /// OpenAI Codex (`codex`).
    Codex,
}

impl AgentKind {
    /// Parses `"claude"` or `"codex"`, returning `None` for unknown names.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }

    /// Canonical lowercase identifier (`"claude"` or `"codex"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// How a frontend wraps multi-line prompt text when writing to an agent PTY.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PasteStyle {
    /// Wrap payload in `\x1b[200~...\x1b[201~` after stripping raw ESC bytes.
    Bracketed,
}

/// Keystroke sent after `submit_delay_ms` to submit a pasted prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SubmitKey {
    /// Carriage return (`\r`), used by Claude Code.
    Enter,
    /// Horizontal tab (`\t`), used by Codex.
    Tab,
}

/// Strategy describing how a frontend delivers prompts to a chosen [`AgentKind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    /// Selected agent CLI.
    pub kind: AgentKind,
    /// Paste framing mode.
    pub paste_style: PasteStyle,
    /// Trailing submit keystroke.
    pub submit_key: SubmitKey,
    /// Milliseconds to wait between paste completion and `submit_key`.
    pub submit_delay_ms: u64,
}

impl AgentProfile {
    /// Standard delivery profile for `kind`.
    #[must_use]
    pub const fn from_kind(kind: AgentKind) -> Self {
        let submit_key = match kind {
            AgentKind::Claude => SubmitKey::Enter,
            AgentKind::Codex => SubmitKey::Tab,
        };
        Self {
            kind,
            paste_style: PasteStyle::Bracketed,
            submit_key,
            submit_delay_ms: DEFAULT_SUBMIT_DELAY_MS,
        }
    }
}

/// Session identity and profile returned before opening or resuming an agent
/// terminal split.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunchPlan {
    /// Agent CLI kind stored for this pull request.
    pub kind: AgentKind,
    /// Stable UUID-formatted session identifier persisted in `session.json`.
    pub session_id: String,
    /// Whether this PR already launched an agent session earlier (`true` when
    /// `session.json` already held `session_id` for `kind`).
    pub is_resume: bool,
    /// Unix socket path exposed to the agent as `JPR_SOCKET`, when serving.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    /// Delivery profile for pasting prompts into the terminal.
    pub profile: AgentProfile,
}

/// Whether an agent round sent reviewer comments, requested a PR pre-pass, or
/// requested conflict resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentRoundKind {
    /// Batch or single-thread dispatch of reviewer local comments.
    Send,
    /// Pre-pass review request (`:Jpr prepass`).
    Prepass,
    /// Restore-conflict resolution request after a dirty-worktree fast-forward.
    Conflict,
}

/// One persisted agent send entry in `rounds.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRound {
    /// 1-based monotonic round number for this pull request.
    pub round: u64,
    /// Dispatch kind (`send`, `prepass`, or `conflict`).
    pub kind: AgentRoundKind,
    /// Local thread IDs included in this round (`Vec::new()` for `prepass` and `conflict`).
    pub thread_ids: Vec<String>,
    /// Exact prompt text sent to the agent.
    pub prompt: String,
    /// Unix timestamp in seconds when delivery was confirmed.
    pub sent_at: u64,
}

/// Prepared prompt and delivery instructions returned before the frontend
/// pastes into the agent terminal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDispatch {
    /// Candidate 1-based round number to pass back to `confirmSend`.
    pub round: u64,
    /// Dispatch kind (`send`, `prepass`, or `conflict`).
    pub kind: AgentRoundKind,
    /// Local thread IDs covered by this dispatch.
    pub thread_ids: Vec<String>,
    /// Formatted prompt text ready for bracketed paste.
    pub prompt: String,
    /// Delivery profile for the configured agent.
    pub profile: AgentProfile,
}

/// One agent-authored finding supplied to `jpr-review prepass-write`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepassFinding {
    /// Where the finding attaches (`line`, `range`, `file`, or `pr`).
    pub anchor: Anchor,
    /// Finding body (for example `[high] Unbounded allocation on untrusted length`).
    pub body: String,
    /// Optional author label; defaults to `"agent"` when omitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
}

/// Live buffer extmark line span reported on `:write` for an open local thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalAnchorUpdate {
    /// Local thread ID (`loc-...`).
    pub thread_id: String,
    /// Updated 1-based start line in the saved buffer.
    pub start: u64,
    /// Updated 1-based end line in the saved buffer.
    pub end: u64,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::Anchor;

    #[test]
    fn agent_thread_state_serializes_with_state_tag() {
        assert_eq!(
            serde_json::to_value(AgentThreadState::Unsent).unwrap(),
            json!({ "state": "unsent" })
        );
        assert_eq!(
            serde_json::to_value(AgentThreadState::Sent { round: 3 }).unwrap(),
            json!({ "state": "sent", "round": 3 })
        );
        assert_eq!(
            serde_json::to_value(AgentThreadState::Answered).unwrap(),
            json!({ "state": "answered" })
        );
    }

    #[test]
    fn agent_profile_matches_claude_and_codex_submit_conventions() {
        let claude = AgentProfile::from_kind(AgentKind::Claude);
        assert_eq!(claude.paste_style, PasteStyle::Bracketed);
        assert_eq!(claude.submit_key, SubmitKey::Enter);
        assert_eq!(claude.submit_delay_ms, 200);

        let codex = AgentProfile::from_kind(AgentKind::Codex);
        assert_eq!(codex.submit_key, SubmitKey::Tab);
        assert_eq!(AgentKind::parse("claude"), Some(AgentKind::Claude));
        assert_eq!(AgentKind::parse("codex"), Some(AgentKind::Codex));
        assert_eq!(AgentKind::parse("other"), None);
    }

    #[test]
    fn prepass_finding_and_round_use_camel_case() {
        let finding: PrepassFinding = serde_json::from_value(json!({
            "anchor": Anchor::line("src/lib.rs", 12),
            "body": "[high] Missing bounds check.",
        }))
        .unwrap();
        assert_eq!(finding.anchor.start, Some(12));
        assert_eq!(finding.author, None);

        let round = AgentRound {
            round: 1,
            kind: AgentRoundKind::Send,
            thread_ids: vec!["loc-1".into()],
            prompt: "Run jpr-review guide".into(),
            sent_at: 42,
        };
        let encoded = serde_json::to_value(&round).unwrap();
        assert_eq!(encoded["threadIds"], json!(["loc-1"]));
        assert_eq!(encoded["sentAt"], 42);
    }

    #[test]
    fn conflict_round_kind_serializes_as_conflict() {
        assert_eq!(
            serde_json::to_value(AgentRoundKind::Conflict).unwrap(),
            json!("conflict")
        );
    }
}
