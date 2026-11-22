use anyhow::{Context, Result, bail};
use review_core::ports::{Clock, ReviewStore, StoreSnapshot, SystemClock};
use review_model::{AgentThreadState, Message, Origin, Thread};
use review_store_fs::FsStore;
use serde_json::json;

use super::socket_client::{
    TargetContext, execute_via_socket_or_store, format_unix_seconds_to_iso8601,
};
use crate::prompt::{self, Question};
use crate::theme::Theme;

/// Runs `jpr-review reply`: appends an agent reply to a local thread.
pub fn run(thread_id: Option<&str>, body: Option<&str>, target: TargetContext<'_>) -> Result<()> {
    let target_thread_id = get_thread_id_from_flag_or_prompt(thread_id, target.theme)?;
    let reply_body = get_body_from_flag_or_prompt(body, target.theme)?;
    if reply_body.trim().is_empty() {
        bail!("reply body cannot be empty");
    }
    let output = execute_via_socket_or_store(
        target,
        "agentReply",
        &json!({ "threadId": target_thread_id, "body": reply_body }),
        Ok,
        |store| reply_via_store(store, &target_thread_id, &reply_body),
    )?;
    println!(
        "{}",
        serde_json::to_string(&output).context("serializing reply output")?
    );
    Ok(())
}

fn get_thread_id_from_flag_or_prompt(flag: Option<&str>, theme: Theme) -> Result<String> {
    if let Some(thread_id) = flag {
        return Ok(thread_id.to_owned());
    }
    let question = Question::new(
        "thread id",
        "Which local thread id (e.g. loc-1)?",
        "<THREAD_ID>",
    );
    prompt::ask(&question, theme)
}

fn get_body_from_flag_or_prompt(flag: Option<&str>, theme: Theme) -> Result<String> {
    if let Some(body) = flag {
        return Ok(body.to_owned());
    }
    let question = Question::new("reply body", "Reply message?", "--body <BODY>");
    prompt::ask(&question, theme)
}

fn reply_via_store(store: &FsStore, thread_id: &str, body: &str) -> Result<serde_json::Value> {
    let snapshot = store.load()?;
    if is_forbidden_github_target(thread_id, &snapshot) {
        bail!(
            "refusing to reply to GitHub thread {thread_id}: agent replies are allowed only on local threads"
        );
    }
    let timestamp = format_unix_seconds_to_iso8601(SystemClock.now());
    let updated: Thread = store.mutate_local_locked(|local| {
        let Some(thread) = local
            .threads
            .iter_mut()
            .find(|item| item.id == thread_id)
        else {
            bail!("unknown local thread {thread_id}");
        };
        if thread.origin != Origin::Local {
            bail!(
                "refusing to reply to GitHub thread {thread_id}: agent replies are allowed only on local threads"
            );
        }
        local.next_local_id += 1;
        let message_id = format!("loc-m-{}", local.next_local_id);
        let mut message = Message::create_with_sync(&message_id, "agent", body, &timestamp, None);
        message.viewer_did_author = false;
        thread.messages.push(message);
        thread.agent = Some(AgentThreadState::Answered);
        Ok(thread.clone())
    })?;
    Ok(json!({ "thread": updated }))
}

fn is_forbidden_github_target(thread_id: &str, snapshot: &StoreSnapshot) -> bool {
    let canonical = snapshot
        .registry
        .id_map
        .get(thread_id)
        .map_or(thread_id, String::as_str);
    thread_id.starts_with("PRRT_")
        || thread_id.starts_with("IC_")
        || thread_id.starts_with("PRRC_")
        || thread_id.starts_with("tmp-")
        || snapshot
            .registry
            .threads
            .iter()
            .any(|thread| thread.id == thread_id || thread.id == canonical)
}
