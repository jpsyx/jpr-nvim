//! The on-disk shapes. Each file is an envelope, `{"version": N, ...}`, so a
//! later build can change the shape and an older build can refuse what it
//! does not understand instead of dropping it. The persisted types mirror the
//! domain types but default every missing field, so a field added to the
//! model later does not make existing files unreadable.

use anyhow::{Context, Result, bail};
use review_core::ports::SessionRecord;
use review_model::{ChangedFile, PullRequest, ViewedState};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// The `session.json` shape this build reads and writes.
pub const SESSION_VERSION: u32 = 1;
/// The `viewed.json` shape this build reads and writes.
pub const VIEWED_VERSION: u32 = 1;

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
}

/// `viewed.json`: the changed files and their viewed state.
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct ViewedFile {
    version: u32,
    files: Vec<StoredChangedFile>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct StoredPullRequest {
    owner: String,
    repo: String,
    number: u64,
    title: String,
    url: String,
    node_id: String,
    author: String,
    head_ref: String,
    head_sha: String,
    base_ref: String,
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
    })
}

/// The session record in `session.json`'s bytes.
pub fn decode_session(bytes: &[u8]) -> Result<SessionRecord> {
    let file: SessionFile = decode(bytes, SESSION_VERSION)?;
    Ok(SessionRecord {
        pid: file.pid,
        worktree: file.worktree,
        pr: file.pr.map(PullRequest::from),
        last_synced_at: file.last_synced_at,
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
    let file: ViewedFile = decode(bytes, VIEWED_VERSION)?;
    Ok(file.files.into_iter().map(ChangedFile::from).collect())
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

fn decode<T: DeserializeOwned>(bytes: &[u8], known: u32) -> Result<T> {
    let found = stored_version(bytes)?;
    refuse_newer(found, known)?;
    if found != known {
        bail!(
            "it is format version {found}, which this build cannot read (it reads version {known})"
        );
    }
    serde_json::from_slice(bytes).context("this is not valid review state (fix or delete the file)")
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
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
        } = pr;
        Self {
            owner,
            repo,
            number,
            title,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
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
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
        } = pr;
        Self {
            owner,
            repo,
            number,
            title,
            url,
            node_id,
            author,
            head_ref,
            head_sha,
            base_ref,
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
mod tests {
    use review_core::fakes::{changed_file, sample_pr};
    use serde_json::{Value, json};

    use super::*;

    fn session() -> SessionRecord {
        SessionRecord {
            pid: Some(42),
            worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
            pr: Some(sample_pr()),
            last_synced_at: Some(100),
        }
    }

    fn as_json(bytes: &[u8]) -> Value {
        serde_json::from_slice(bytes).unwrap()
    }

    #[test]
    fn a_session_round_trips_inside_a_version_1_envelope() {
        let bytes = encode_session(&session()).unwrap();
        assert_eq!(as_json(&bytes)["version"], json!(1));
        assert_eq!(as_json(&bytes)["pr"]["headSha"], json!("abc123"));
        assert_eq!(decode_session(&bytes).unwrap(), session());
    }

    #[test]
    fn the_viewed_file_is_a_version_1_envelope_around_the_files() {
        let files = vec![changed_file("src/a.rs", ViewedState::Viewed)];
        let bytes = encode_files(&files).unwrap();
        assert_eq!(
            as_json(&bytes),
            json!({
                "version": 1,
                "files": [{ "path": "src/a.rs", "additions": 3, "deletions": 1, "viewed": "VIEWED" }],
            })
        );
        assert!(bytes.ends_with(b"}\n"));
        assert_eq!(decode_files(&bytes).unwrap(), files);
    }

    #[test]
    fn a_newer_version_is_refused_naming_both_versions() {
        let error = decode_files(br#"{"version": 2, "files": []}"#).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("version 2") && message.contains("version 1"),
            "{message}"
        );
        assert!(!message.contains("delete"), "{message}");
    }

    #[test]
    fn an_unknown_older_version_is_refused() {
        let error = decode_session(br#"{"version": 0}"#).unwrap_err();
        assert!(format!("{error:#}").contains("version 0"), "{error:#}");
    }

    #[test]
    fn a_file_without_a_version_is_refused() {
        let error = decode_files(b"[]").unwrap_err();
        assert!(format!("{error:#}").contains("fix or delete"), "{error:#}");
    }

    #[test]
    fn an_old_file_missing_newer_fields_loads_with_defaults() {
        let files = decode_files(br#"{"version": 1, "files": [{"path": "src/a.rs"}]}"#).unwrap();
        assert_eq!(files[0].path, "src/a.rs");
        assert_eq!(
            (files[0].additions, files[0].viewed),
            (0, ViewedState::Unviewed)
        );
        let record =
            decode_session(br#"{"version": 1, "pr": {"owner": "octo", "number": 7}}"#).unwrap();
        let pr = record.pr.unwrap();
        assert_eq!(
            (pr.owner.as_str(), pr.number, pr.node_id.as_str()),
            ("octo", 7, "")
        );
        assert_eq!(record.last_synced_at, None);
    }

    #[test]
    fn stored_version_reads_only_the_version() {
        assert_eq!(
            stored_version(br#"{"version": 3, "files": "anything"}"#).unwrap(),
            3
        );
    }

    #[test]
    fn only_a_newer_version_blocks_an_overwrite() {
        assert!(refuse_newer(2, 1).is_err());
        assert!(refuse_newer(1, 1).is_ok());
        assert!(refuse_newer(0, 1).is_ok());
    }
}
