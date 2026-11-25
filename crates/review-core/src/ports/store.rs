//! Durable persistence port and snapshot records for one pull request's review state.

use std::collections::BTreeMap;

use anyhow::Result;
use review_model::{
    AgentKind, AgentRound, ChangedFile, MentionCandidate, PullRequest, Thread, ViewedState,
};
use serde::{Deserialize, Serialize};

use super::QueuedCommentOp;

/// The running daemon and what it last saw, persisted between runs.
///
/// A later run uses it to find the serving process and show the last synced
/// pull request before it syncs again.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionRecord {
    /// The process serving the session, once one has recorded itself.
    pub pid: Option<u32>,
    /// The worktree the serving process runs in.
    pub worktree: Option<String>,
    /// The pull request as last synced.
    pub pr: Option<PullRequest>,
    /// Unix seconds of the last successful sync.
    pub last_synced_at: Option<u64>,
    /// Unix domain socket path where the running daemon accepts CLI requests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    /// Stable session identifier for resuming Claude Code or Codex on this PR.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    /// Agent kind (`claude` or `codex`) associated with `agent_session_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_kind: Option<AgentKind>,
}

/// Local-only threads and counters persisted in `local.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LocalStoreState {
    /// Next numeric suffix for `loc-<id>` threads and `loc-m-<id>` messages.
    pub next_local_id: u64,
    /// Next 1-based dispatch round counter.
    pub next_round: u64,
    /// Every `Origin::Local` thread on this pull request.
    pub threads: Vec<Thread>,
    /// Viewed state for local-only worktree files not yet present on the forge.
    #[serde(default)]
    pub local_viewed: BTreeMap<String, ViewedState>,
}

/// What the engine still owes the forge: changes made while the forge could
/// not be reached, sent again on the next try. Saved with everything else,
/// so a restarted engine still delivers them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncRegistry {
    /// Viewed marks the forge has not accepted yet, by path: `true` for
    /// viewed, `false` for unviewed.
    pub queued_viewed: BTreeMap<String, bool>,
    /// Node id of the reviewer's active pending review on GitHub, if any.
    pub pending_review_id: Option<String>,
    /// Login of the authenticated reviewer.
    pub viewer_login: Option<String>,
    /// Counter for temporary optimistic thread and message ids (`tmp-1`, ...).
    pub next_temp_id: u64,
    /// Temporary id to real GitHub node id mappings learned during replay.
    pub id_map: BTreeMap<String, String>,
    /// Last forge-confirmed body per message id, for concurrent-edit detection.
    pub agreed_bodies: BTreeMap<String, String>,
    /// Persisted threads (published, draft, queued, and failed) so restarts keep
    /// optimistic state before the next sync.
    pub threads: Vec<Thread>,
    /// Comment operations waiting to be sent to GitHub.
    pub queued_ops: Vec<QueuedCommentOp>,
    /// Cached `@mention` candidates from the last sync.
    pub mention_candidates: Vec<MentionCandidate>,
}

/// Everything the engine persists for one pull request.
///
/// A [`ReviewStore`] saves and loads it whole, and the session reopens from
/// it, so a restarted engine shows the last synced files before its first
/// sync.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoreSnapshot {
    /// The serving process and the last synced pull request.
    pub session: SessionRecord,
    /// The changed files and their viewed state as last synced.
    pub files: Vec<ChangedFile>,
    /// What the engine still owes the forge.
    pub registry: SyncRegistry,
    /// Local-only threads and counters for the reviewer-agent loop.
    pub local: LocalStoreState,
}

/// Durable storage for one pull request's review state.
///
/// The session loads from it when it opens, and saves through it after every
/// successful sync and when the daemon records itself; for example, a store can
/// keep files on disk or keep everything in memory for a test.
pub trait ReviewStore: Send {
    /// What was saved last, or an empty snapshot when nothing was.
    fn load(&self) -> Result<StoreSnapshot>;
    /// Replaces what is saved.
    fn save(&self, snapshot: &StoreSnapshot) -> Result<()>;
    /// Appends one delivered agent round to durable storage.
    fn append_round(&self, round: &AgentRound) -> Result<()>;
    /// All persisted agent rounds, in append order.
    fn rounds(&self) -> Result<Vec<AgentRound>>;
    /// Retargets persistence from a local review directory to the pull request's
    /// canonical state directory, returning any preexisting PR snapshot to merge.
    fn retarget_to_pr(
        &self,
        _owner: &str,
        _repo: &str,
        _number: u64,
    ) -> Result<Option<StoreSnapshot>> {
        Ok(None)
    }
    /// Retires migrated files from the previous local state directory once the
    /// upgraded PR state has been durably saved.
    fn finalize_retarget(&self) -> Result<()> {
        Ok(())
    }
}
