use std::env;
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use review_core::ports::{Clock, ReviewStore, SystemClock, Workspace};
use review_core::reanchor::{
    extract_snapshot_from_text, normalize_prepass_anchor, validate_anchor_file,
};
use review_model::{
    AgentThreadState, Anchor, AnchorKind, Message, Origin, PrepassFinding, Side, Thread,
    ThreadState,
};
use review_store_fs::FsStore;
use review_workspace_git::GitWorkspace;
use serde_json::{Value, json};

use super::socket_client::{TargetContext, execute_via_socket_or_store};

const MAX_PREPASS_INPUT_BYTES: u64 = 512 * 1024;
const MAX_SOCKET_WIRE_BYTES: usize = 1_048_576 - 256;
const MAX_SNAPSHOT_FILE_BYTES: usize = 4 * 1024 * 1024;

/// Runs `jpr-review prepass-write`: validates findings JSON and creates answered local threads.
pub fn run(input: Option<&Path>, target: TargetContext<'_>) -> Result<()> {
    let findings = read_findings(input)?;
    let normalized = validate_and_normalize_findings(&findings)?;
    let params = json!({ "findings": &normalized });
    ensure_wire_payload_fits(&params)?;
    let output = execute_via_socket_or_store(target, "prepassWrite", &params, Ok, |store| {
        write_findings_to_store(store, normalized)
    })?;
    println!(
        "{}",
        serde_json::to_string(&output).context("serializing prepass-write output")?
    );
    Ok(())
}

fn ensure_wire_payload_fits(params: &Value) -> Result<()> {
    let envelope = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "prepassWrite",
        "params": params,
    });
    let encoded_len = serde_json::to_vec(&envelope)
        .context("encoding pre-pass findings payload")?
        .len();
    if encoded_len > MAX_SOCKET_WIRE_BYTES {
        bail!("pre-pass findings exceed 1 MiB daemon socket payload limit");
    }
    Ok(())
}

fn read_findings(input: Option<&Path>) -> Result<Vec<PrepassFinding>> {
    let bytes = match input {
        Some(path) => {
            let file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
            read_bounded_bytes(file, &path.display().to_string())?
        }
        None => read_bounded_bytes(io::stdin().lock(), "stdin")?,
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        bail!("expected a JSON array of findings");
    }
    serde_json::from_slice(&bytes).context("parsing pre-pass findings JSON array")
}

fn read_bounded_bytes(reader: impl Read, source: &str) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let limit = MAX_PREPASS_INPUT_BYTES + 1;
    reader
        .take(limit)
        .read_to_end(&mut bytes)
        .with_context(|| format!("reading {source}"))?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_PREPASS_INPUT_BYTES {
        bail!("{source} exceeds maximum pre-pass input size");
    }
    Ok(bytes)
}

fn validate_and_normalize_findings(findings: &[PrepassFinding]) -> Result<Vec<PrepassFinding>> {
    let mut prepared = Vec::new();
    for finding in findings {
        if finding.body.trim().is_empty() {
            continue;
        }
        let anchor = normalize_prepass_anchor(finding.anchor.clone())?;
        let author = finding
            .author
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned);
        prepared.push(PrepassFinding {
            anchor,
            body: finding.body.clone(),
            author,
        });
    }
    Ok(prepared)
}

fn write_findings_to_store(store: &FsStore, mut prepared: Vec<PrepassFinding>) -> Result<Value> {
    if prepared.is_empty() {
        return Ok(json!({ "threads": [] }));
    }
    let snapshot = store.load()?;
    if !snapshot.files.is_empty() {
        for finding in &prepared {
            validate_anchor_file(&snapshot.files, &finding.anchor)?;
        }
    }
    populate_disk_snapshots(snapshot.session.worktree.as_deref(), &mut prepared);
    let timestamp = super::socket_client::format_unix_seconds_to_iso8601(SystemClock.now());
    let created = store.mutate_local_locked(|local| {
        let mut threads = Vec::with_capacity(prepared.len());
        for finding in prepared {
            local.next_local_id += 1;
            let sequence = local.next_local_id;
            let author = finding.author.as_deref().unwrap_or("agent");
            let mut message = Message::create_with_sync(
                &format!("loc-m-{sequence}"),
                author,
                &finding.body,
                &timestamp,
                None,
            );
            message.viewer_did_author = false;
            let thread = Thread {
                id: format!("loc-{sequence}"),
                origin: Origin::Local,
                anchor: finding.anchor,
                state: ThreadState::Open,
                outdated: false,
                messages: vec![message],
                agent: Some(AgentThreadState::Answered),
                promoted_to: None,
            };
            local.threads.push(thread.clone());
            threads.push(thread);
        }
        Ok(threads)
    })?;
    Ok(json!({ "threads": created }))
}

fn populate_disk_snapshots(worktree: Option<&str>, prepared: &mut [PrepassFinding]) {
    let worktree_root = worktree
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .or_else(|| env::current_dir().ok());
    let Some(workspace) = worktree_root.and_then(|root| GitWorkspace::open(&root).ok()) else {
        return;
    };
    for finding in prepared {
        if finding.anchor.side == Side::Right
            && matches!(finding.anchor.kind, AnchorKind::Line | AnchorKind::Range)
            && let Some(path) = finding.anchor.file.as_deref()
        {
            finding.anchor.snapshot = capture_disk_snapshot(&workspace, path, &finding.anchor);
        }
    }
}

fn capture_disk_snapshot(workspace: &GitWorkspace, path: &str, anchor: &Anchor) -> Option<String> {
    let bytes = workspace.file_on_disk(path).ok().flatten()?;
    if bytes.len() > MAX_SNAPSHOT_FILE_BYTES || bytes.iter().take(8000).any(|&byte| byte == 0) {
        return None;
    }
    let text = std::str::from_utf8(&bytes).ok()?;
    extract_snapshot_from_text(text, anchor)
}
