//! The on-disk shapes. Each file is an envelope, `{"version": N, ...}`, so a
//! later build can change the shape and an older build can refuse what it
//! does not understand instead of dropping it. The persisted types mirror the
//! domain types but default every missing field, so a field added to the
//! model later does not make existing files unreadable.

use anyhow::{Context, Result, bail};
use review_core::ports::{LocalStoreState, SessionRecord, SyncRegistry};
use review_model::{AgentKind, ChangedFile, PullRequest, ViewedState};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// The `session.json` shape this build writes. Version 2 added the pull
/// request's `baseSha`. Version 3 added `socket`, `agentSessionId`, and
/// `agentKind`.
pub const SESSION_VERSION: u32 = 3;
/// The oldest `session.json` shape this build still reads: version 1 has no
/// `baseSha`, which reads as empty until the next sync fills it.
pub const OLDEST_SESSION_VERSION: u32 = 1;
/// The `viewed.json` shape this build reads and writes.
pub const VIEWED_VERSION: u32 = 1;
/// The `github.json` shape this build writes: `queuedViewed`, persisted
/// threads, queued comment operations, pending review metadata, and mention
/// candidates.
pub const GITHUB_VERSION: u32 = 2;
/// The oldest `github.json` shape this build reads: version 1 holds only
/// `queuedViewed`, and all other `SyncRegistry` fields default to empty.
pub const OLDEST_GITHUB_VERSION: u32 = 1;
/// The `local.json` shape this build reads and writes.
pub const LOCAL_VERSION: u32 = 1;

/// Just the version, read before anything else in a file.
#[derive(Deserialize)]
struct VersionProbe {
    version: u32,
}

/// `session.json`: the version beside the session record's own fields.
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct SessionFile {
    version: u32,
    pid: Option<u32>,
    worktree: Option<String>,
    pr: Option<StoredPullRequest>,
    last_synced_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    socket: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_kind: Option<AgentKind>,
}

/// `viewed.json`: the changed files and their viewed state.
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct ViewedFile {
    version: u32,
    files: Vec<StoredChangedFile>,
}

/// `github.json`: what the engine still owes GitHub.
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct GithubFile {
    version: u32,
    #[serde(flatten)]
    registry: SyncRegistry,
}

/// `local.json`: local-only threads and counters for the reviewer-agent loop.
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LocalFile {
    version: u32,
    #[serde(flatten)]
    local: LocalStoreState,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct StoredPullRequest {
    owner: String,
    repo: String,
    number: u64,
    title: String,
    body: String,
    url: String,
    node_id: String,
    author: String,
    head_ref: String,
    head_sha: String,
    base_ref: String,
    base_sha: String,
    is_cross_repository: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct StoredChangedFile {
    path: String,
    additions: u64,
    deletions: u64,
    viewed: ViewedState,
}

impl Default for StoredChangedFile {
    fn default() -> Self {
        Self {
            path: String::new(),
            additions: 0,
            deletions: 0,
            viewed: ViewedState::Unviewed,
        }
    }
}

/// `session.json`'s bytes for `record`.
pub fn encode_session(record: &SessionRecord) -> Result<Vec<u8>> {
    encode(&SessionFile {
        version: SESSION_VERSION,
        pid: record.pid,
        worktree: record.worktree.clone(),
        pr: record.pr.clone().map(StoredPullRequest::from),
        last_synced_at: record.last_synced_at,
        socket: record.socket.clone(),
        agent_session_id: record.agent_session_id.clone(),
        agent_kind: record.agent_kind,
    })
}

/// `session.json`'s session record.
pub fn decode_session(bytes: &[u8]) -> Result<SessionRecord> {
    let file: SessionFile = decode(bytes, OLDEST_SESSION_VERSION, SESSION_VERSION)?;
    Ok(SessionRecord {
        pid: file.pid,
        worktree: file.worktree,
        pr: file.pr.map(PullRequest::from),
        last_synced_at: file.last_synced_at,
        socket: file.socket,
        agent_session_id: file.agent_session_id,
        agent_kind: file.agent_kind,
    })
}

/// `viewed.json`'s bytes for `files`.
pub fn encode_files(files: &[ChangedFile]) -> Result<Vec<u8>> {
    encode(&ViewedFile {
        version: VIEWED_VERSION,
        files: files.iter().cloned().map(StoredChangedFile::from).collect(),
    })
}

/// The changed files in `viewed.json`'s bytes.
pub fn decode_files(bytes: &[u8]) -> Result<Vec<ChangedFile>> {
    let file: ViewedFile = decode(bytes, VIEWED_VERSION, VIEWED_VERSION)?;
    Ok(file.files.into_iter().map(ChangedFile::from).collect())
}

/// `github.json`'s bytes for `registry`.
pub fn encode_registry(registry: &SyncRegistry) -> Result<Vec<u8>> {
    encode(&GithubFile {
        version: GITHUB_VERSION,
        registry: registry.clone(),
    })
}

/// The registry in `github.json`'s bytes.
pub fn decode_registry(bytes: &[u8]) -> Result<SyncRegistry> {
    let file: GithubFile = decode(bytes, OLDEST_GITHUB_VERSION, GITHUB_VERSION)?;
    Ok(file.registry)
}

/// `local.json`'s bytes for `local`.
pub fn encode_local(local: &LocalStoreState) -> Result<Vec<u8>> {
    encode(&LocalFile {
        version: LOCAL_VERSION,
        local: local.clone(),
    })
}

/// `local.json`'s state.
pub fn decode_local(bytes: &[u8]) -> Result<LocalStoreState> {
    let file: LocalFile = decode(bytes, LOCAL_VERSION, LOCAL_VERSION)?;
    Ok(file.local)
}

/// The version a file declares, without reading the rest of it.
pub fn stored_version(bytes: &[u8]) -> Result<u32> {
    let probe: VersionProbe = serde_json::from_slice(bytes)
        .context("this is not review state with a version (fix or delete the file)")?;
    Ok(probe.version)
}

/// Fails when `found` is newer than `known`: a newer build wrote the file,
/// and this one would lose what it does not understand.
pub fn refuse_newer(found: u32, known: u32) -> Result<()> {
    if found > known {
        bail!(
            "it is format version {found}, but this build only knows version {known} \
             (upgrade this program instead of deleting the file)"
        );
    }
    Ok(())
}

fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec_pretty(value).context("encoding review state")?;
    bytes.push(b'\n');
    Ok(bytes)
}

/// Reads a file whose version is between `oldest` and `known`. Every shape in
/// that range must read into the same struct, with defaults for the fields
/// an older version lacks.
fn decode<T: DeserializeOwned>(bytes: &[u8], oldest: u32, known: u32) -> Result<T> {
    let found = stored_version(bytes)?;
    refuse_newer(found, known)?;
    if found < oldest {
        bail!(
            "it is format version {found}, which this build cannot read (it reads {})",
            build_readable_versions_label(oldest, known)
        );
    }
    serde_json::from_slice(bytes).context("this is not valid review state (fix or delete the file)")
}

/// `version 1`, or `versions 1 to 2`, for an error message.
fn build_readable_versions_label(oldest: u32, known: u32) -> String {
    if oldest == known {
        format!("version {known}")
    } else {
        format!("versions {oldest} to {known}")
    }
}

// Destructuring both ways turns a field added to the model into a compile
// error here, until the stored shape gains it (with a default).
impl From<PullRequest> for StoredPullRequest {
    fn from(pr: PullRequest) -> Self {
        let PullRequest {
            owner,
            repo,
            number,
            title,
            body,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
            base_sha,
            is_cross_repository,
        } = pr;
        Self {
            owner,
            repo,
            number,
            title,
            body,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
            base_sha,
            is_cross_repository,
        }
    }
}

impl From<StoredPullRequest> for PullRequest {
    fn from(pr: StoredPullRequest) -> Self {
        let StoredPullRequest {
            owner,
            repo,
            number,
            title,
            body,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
            base_sha,
            is_cross_repository,
        } = pr;
        Self {
            owner,
            repo,
            number,
            title,
            body,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
            base_sha,
            is_cross_repository,
        }
    }
}

impl From<ChangedFile> for StoredChangedFile {
    fn from(file: ChangedFile) -> Self {
        let ChangedFile {
            path,
            additions,
            deletions,
            viewed,
        } = file;
        Self {
            path,
            additions,
            deletions,
            viewed,
        }
    }
}

impl From<StoredChangedFile> for ChangedFile {
    fn from(file: StoredChangedFile) -> Self {
        let StoredChangedFile {
            path,
            additions,
            deletions,
            viewed,
        } = file;
        Self {
            path,
            additions,
            deletions,
            viewed,
        }
    }
}

#[cfg(test)]
mod tests;
