//! Agent launch plans, two-phase comment dispatch, and pre-pass writes for
//! `ReviewSession`.

use anyhow::{Result, bail};
use review_model::{
    AgentDispatch, AgentKind, AgentLaunchPlan, AgentProfile, AgentRound, AgentRoundKind,
    AgentThreadState, Anchor, AnchorKind, Event, Origin, PrepassFinding, SessionView, Side, Thread,
    ThreadState,
};

use super::ReviewSession;
use crate::agent::{
    build_conflict_prompt_from_paths, build_prepass_prompt_from_pr, build_send_prompt_from_threads,
    build_uuid_v4_from_seed, select_dispatchable_threads,
};
use crate::reanchor::{normalize_prepass_anchor, validate_safe_relative_path};

impl ReviewSession {
    /// Returns the launch/resume plan for `kind`, allocating and persisting a
    /// stable RFC 4122 v4 UUID on first launch or when switching agent kinds.
    pub fn prepare_agent_launch(&mut self, kind: AgentKind) -> Result<AgentLaunchPlan> {
        if self.saved.session.agent_kind == Some(kind)
            && let Some(existing_id) = self
                .saved
                .session
                .agent_session_id
                .as_deref()
                .filter(|id| !id.trim().is_empty())
        {
            return Ok(AgentLaunchPlan {
                kind,
                session_id: existing_id.to_owned(),
                is_resume: true,
                socket: self.saved.session.socket.clone(),
                profile: AgentProfile::from_kind(kind),
            });
        }
        let mut updated_saved = self.saved.clone();
        updated_saved.local.next_local_id += 1;
        let session_id = build_uuid_v4_from_seed(
            self.number,
            self.ports.clock.now(),
            updated_saved.local.next_local_id,
        );
        updated_saved.session.agent_session_id = Some(session_id.clone());
        updated_saved.session.agent_kind = Some(kind);
        self.ports.store.save(&updated_saved)?;
        self.saved = updated_saved;
        Ok(AgentLaunchPlan {
            kind,
            session_id,
            is_resume: false,
            socket: self.saved.session.socket.clone(),
            profile: AgentProfile::from_kind(kind),
        })
    }

    /// Prepares a prompt and dispatch metadata for unsent local threads (or
    /// `only_thread_id` when specified) without mutating delivery state.
    pub fn prepare_send(
        &self,
        only_thread_id: Option<&str>,
        kind: AgentKind,
    ) -> Result<AgentDispatch> {
        let selected = select_dispatchable_threads(&self.threads, only_thread_id);
        if selected.is_empty() {
            bail!("no unsent local comments to send");
        }
        let pr = self.synced_pr()?;
        let prompt = build_send_prompt_from_threads(pr, &selected);
        Ok(AgentDispatch {
            round: self.saved.local.next_round.max(1),
            kind: AgentRoundKind::Send,
            thread_ids: selected.iter().map(|thread| thread.id.clone()).collect(),
            prompt,
            profile: AgentProfile::from_kind(kind),
        })
    }

    /// Records a confirmed agent dispatch round, marks matching local threads as
    /// [`AgentThreadState::Sent`], and emits update events.
    pub fn confirm_send(
        &mut self,
        round: u64,
        kind: AgentRoundKind,
        thread_ids: &[String],
        prompt: &str,
    ) -> Result<(AgentRound, SessionView)> {
        self.validate_confirm_send(round, kind, thread_ids)?;
        let entry = AgentRound {
            round,
            kind,
            thread_ids: thread_ids.to_vec(),
            prompt: prompt.to_owned(),
            sent_at: self.ports.clock.now(),
        };
        self.ports.store.append_round(&entry)?;
        let previous_threads = self.threads.clone();
        let previous_local = self.saved.local.clone();
        let did_threads_change = self.mark_threads_sent(round, thread_ids);
        self.saved.local.next_round = round.saturating_add(1);
        if let Err(error) = self.split_and_save_threads() {
            self.threads = previous_threads;
            self.saved.local = previous_local;
            return Err(error);
        }
        let view = self.view();
        if !thread_ids.is_empty() && did_threads_change {
            self.publish(&Event::ThreadsChanged {
                view: Box::new(view.clone()),
            });
        }
        self.publish(&Event::AgentRound {
            round: entry.clone(),
            view: Box::new(view.clone()),
        });
        Ok((entry, view))
    }

    /// Prepares a pre-pass review prompt for the currently synced pull request.
    pub fn prepare_prepass(&self, kind: AgentKind) -> Result<AgentDispatch> {
        let pr = self.synced_pr()?;
        Ok(AgentDispatch {
            round: self.saved.local.next_round.max(1),
            kind: AgentRoundKind::Prepass,
            thread_ids: Vec::new(),
            prompt: build_prepass_prompt_from_pr(pr),
            profile: AgentProfile::from_kind(kind),
        })
    }

    /// Prepares a conflict-resolution prompt for `conflicted_paths` after a
    /// dirty-worktree fast-forward hit stash-restore conflicts.
    pub fn prepare_conflict_resolution(
        &self,
        conflicted_paths: &[String],
        kind: AgentKind,
    ) -> Result<AgentDispatch> {
        let pr = self.synced_pr()?;
        let mut normalized_paths = Vec::with_capacity(conflicted_paths.len());
        for path in conflicted_paths {
            validate_safe_relative_path(path)?;
            if path.contains('`') {
                bail!("invalid conflicted path {path:?}");
            }
            if !normalized_paths
                .iter()
                .any(|existing_path| existing_path == path)
            {
                normalized_paths.push(path.clone());
            }
        }
        if normalized_paths.is_empty() {
            bail!("at least one conflicted path is required");
        }
        Ok(AgentDispatch {
            round: self.saved.local.next_round.max(1),
            kind: AgentRoundKind::Conflict,
            thread_ids: Vec::new(),
            prompt: build_conflict_prompt_from_paths(pr, &normalized_paths),
            profile: AgentProfile::from_kind(kind),
        })
    }

    /// Creates answered local threads from non-blank pre-pass `findings`,
    /// capturing disk snapshots on `Side::Right` line/range anchors.
    pub fn prepass_write(
        &mut self,
        findings: Vec<PrepassFinding>,
    ) -> Result<(Vec<Thread>, SessionView)> {
        let mut prepared = Vec::new();
        for finding in findings {
            if let Some(normalized) = self.normalize_prepass_finding(finding)? {
                prepared.push(normalized);
            }
        }
        if prepared.is_empty() {
            return Ok((Vec::new(), self.view()));
        }
        let previous_threads = self.threads.clone();
        let previous_local = self.saved.local.clone();
        let mut created = Vec::with_capacity(prepared.len());
        for (anchor, author, body) in prepared {
            created.push(self.append_prepass_thread(anchor, &author, &body));
        }
        if let Err(error) = self.split_and_save_threads() {
            self.threads = previous_threads;
            self.saved.local = previous_local;
            return Err(error);
        }
        let view = self.view();
        self.publish(&Event::ThreadsChanged {
            view: Box::new(view.clone()),
        });
        Ok((created, view))
    }

    fn validate_confirm_send(
        &self,
        round: u64,
        kind: AgentRoundKind,
        thread_ids: &[String],
    ) -> Result<()> {
        if round == 0 {
            bail!("agent round must be at least 1");
        }
        if round < self.saved.local.next_round {
            bail!(
                "stale or duplicate agent round {round} (expected >= {})",
                self.saved.local.next_round
            );
        }
        match kind {
            AgentRoundKind::Prepass | AgentRoundKind::Conflict if !thread_ids.is_empty() => {
                bail!(
                    "{} round cannot include thread IDs",
                    round_kind_to_label(kind)
                );
            }
            AgentRoundKind::Send if thread_ids.is_empty() => {
                bail!("send round requires at least one thread ID");
            }
            AgentRoundKind::Prepass | AgentRoundKind::Conflict | AgentRoundKind::Send => Ok(()),
        }
    }

    fn mark_threads_sent(&mut self, round: u64, thread_ids: &[String]) -> bool {
        let mut did_threads_change = false;
        for thread in &mut self.threads {
            if thread.origin == Origin::Local
                && thread_ids.iter().any(|target_id| target_id == &thread.id)
            {
                let updated_state = Some(AgentThreadState::Sent { round });
                if thread.agent != updated_state {
                    thread.agent = updated_state;
                    did_threads_change = true;
                }
            }
        }
        did_threads_change
    }

    fn normalize_prepass_finding(
        &self,
        finding: PrepassFinding,
    ) -> Result<Option<(Anchor, String, String)>> {
        if finding.body.trim().is_empty() {
            return Ok(None);
        }
        let mut anchor = normalize_prepass_anchor(finding.anchor)?;
        self.validate_local_anchor_file(&anchor)?;
        if anchor.side == Side::Right
            && matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range)
            && let Some(path) = anchor.file.as_deref()
        {
            anchor.snapshot = self.capture_disk_snapshot(path, &anchor);
        }
        let author = finding
            .author
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or("agent")
            .to_owned();
        Ok(Some((anchor, author, finding.body)))
    }

    fn append_prepass_thread(&mut self, anchor: Anchor, author: &str, body: &str) -> Thread {
        let sequence = self.allocate_local_id();
        let thread_id = format!("loc-{sequence}");
        let message_id = format!("loc-m-{sequence}");
        let message = self.create_local_message(&message_id, Some(author), body, false);
        let thread = Thread {
            id: thread_id,
            origin: Origin::Local,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
            agent: Some(AgentThreadState::Answered),
            promoted_to: None,
        };
        self.threads.push(thread.clone());
        thread
    }
}

const fn round_kind_to_label(kind: AgentRoundKind) -> &'static str {
    match kind {
        AgentRoundKind::Send => "send",
        AgentRoundKind::Prepass => "prepass",
        AgentRoundKind::Conflict => "conflict",
    }
}

#[cfg(test)]
mod prepass_tests;
#[cfg(test)]
mod tests;
