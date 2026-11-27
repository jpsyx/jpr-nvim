//! Mid-session upgrade from an unlinked local worktree review to a live
//! GitHub pull request session.

use std::collections::BTreeSet;

use anyhow::{Result, bail};
use review_model::{SessionView, Thread, ViewedState};

use super::{ReviewSession, SessionTarget};
use crate::ports::StoreSnapshot;

impl ReviewSession {
    /// Probes the forge for an open pull request on the current branch and, if
    /// found, upgrades this local session in-place into a linked PR session.
    ///
    /// When no open PR exists yet, returns an informational error without
    /// setting `SyncState::Failed` or emitting `Event::SyncFailed`.
    pub(super) fn sync_or_link_local(&mut self, now: u64) -> Result<SessionView> {
        let branch = match &self.target {
            SessionTarget::Local(context) => context.branch.clone(),
            SessionTarget::Pr { .. } => bail!("session is already linked to a pull request"),
        };
        let Some(pr) = self.ports.forge.current_branch_pr()? else {
            bail!("no open pull request found for branch {branch}; staying in local review mode");
        };
        // Fetch the full PR snapshot BEFORE retargeting the store so a network
        // failure leaves the local session and on-disk state untouched.
        let snapshot = self.ports.forge.fetch(&pr)?;
        let existing = self
            .ports
            .store
            .retarget_to_pr(&pr.owner, &pr.repo, pr.number)?;
        if let Some(prior) = existing {
            self.merge_preexisting_pr_snapshot(prior);
        }
        self.ports.forge.pin_repo(&pr.owner, &pr.repo);
        self.target = SessionTarget::Pr { number: pr.number };
        self.has_checked_reopen_head = true;
        let view = self.apply_pull(pr, snapshot, now, false)?;
        let _ = self.ports.store.finalize_retarget();
        Ok(view)
    }

    fn merge_preexisting_pr_snapshot(&mut self, prior: StoreSnapshot) {
        // Keep `self.saved.session.pr` as `None` so first-link `apply_pull`
        // does not trigger `handle_head_moved` against an older stored SHA.
        if self.saved.session.agent_session_id.is_none() {
            self.saved.session.agent_session_id = prior.session.agent_session_id;
            self.saved.session.agent_kind = prior.session.agent_kind;
        }
        self.saved.files = prior.files;
        self.saved.registry = prior.registry;
        for (path, state) in &self.saved.local.local_viewed {
            if *state == ViewedState::Viewed {
                self.saved.registry.queued_viewed.remove(path);
            }
        }
        crate::viewed::apply_queued(&mut self.saved.files, &self.saved.registry.queued_viewed);
        self.saved.local.next_round = self.saved.local.next_round.max(prior.local.next_round);
        self.saved.local.next_local_id = self
            .saved
            .local
            .next_local_id
            .max(prior.local.next_local_id);
        for (path, state) in prior.local.local_viewed {
            self.saved.local.local_viewed.entry(path).or_insert(state);
        }
        self.saved
            .local
            .collapsed_dirs
            .extend(prior.local.collapsed_dirs);
        self.threads.extend(self.saved.registry.threads.clone());
        let merged_prior_local = self.renumber_colliding_local_threads(prior.local.threads);
        self.threads.extend(merged_prior_local);
    }

    fn renumber_colliding_local_threads(&mut self, incoming: Vec<Thread>) -> Vec<Thread> {
        let mut used_thread_ids: BTreeSet<String> = self
            .threads
            .iter()
            .map(|thread| thread.id.clone())
            .collect();
        let mut used_message_ids: BTreeSet<String> = self
            .threads
            .iter()
            .flat_map(|thread| thread.messages.iter().map(|msg| msg.id.clone()))
            .collect();

        let mut result = Vec::with_capacity(incoming.len());
        for mut thread in incoming {
            if !used_thread_ids.insert(thread.id.clone()) {
                let sequence = self.allocate_local_id();
                thread.id = format!("loc-{sequence}");
                used_thread_ids.insert(thread.id.clone());
            }
            for message in &mut thread.messages {
                if !used_message_ids.insert(message.id.clone()) {
                    let sequence = self.allocate_local_id();
                    message.id = format!("loc-m-{sequence}");
                    used_message_ids.insert(message.id.clone());
                }
            }
            result.push(thread);
        }
        result
    }
}
