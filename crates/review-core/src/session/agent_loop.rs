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
            if !normalized_paths.iter().any(|existing| existing == path) {
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
        self.validate_anchor_file(&anchor)?;
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
mod tests {
    use review_model::{
        AgentKind, AgentRoundKind, AgentThreadState, Anchor, AnchorKind, Event, Origin,
        PrepassFinding, Side,
    };

    use super::super::test_support::Fakes;
    use crate::ports::ReviewStore;

    fn assert_rfc4122_v4_uuid(value: &str) {
        assert_eq!(value.len(), 36, "expected 36-char UUID, got {value}");
        let bytes = value.as_bytes();
        for index in [8, 13, 18, 23] {
            assert_eq!(bytes[index], b'-', "expected hyphen at {index} in {value}");
        }
        assert_eq!(bytes[14], b'4', "expected v4 nibble in {value}");
        assert!(
            matches!(bytes[19], b'8' | b'9' | b'a' | b'b'),
            "expected RFC 4122 variant nibble in {value}"
        );
        assert!(
            value
                .chars()
                .enumerate()
                .all(|(index, ch)| [8, 13, 18, 23].contains(&index) || ch.is_ascii_hexdigit()),
            "expected hex digits in {value}"
        );
    }

    #[test]
    fn prepare_agent_launch_assigns_v4_uuid_once_and_marks_later_launches_as_resume() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        session
            .record_daemon_with_socket(4242, "/tmp/wt", Some("/tmp/jpr.sock"))
            .unwrap();

        let first = session.prepare_agent_launch(AgentKind::Claude).unwrap();
        assert!(!first.is_resume);
        assert_eq!(first.kind, AgentKind::Claude);
        assert_eq!(first.socket.as_deref(), Some("/tmp/jpr.sock"));
        assert_rfc4122_v4_uuid(&first.session_id);
        assert_eq!(
            fakes.store.saved().session.agent_session_id.as_deref(),
            Some(first.session_id.as_str())
        );

        let resumed = session.prepare_agent_launch(AgentKind::Claude).unwrap();
        assert!(resumed.is_resume);
        assert_eq!(resumed.session_id, first.session_id);

        let codex = session.prepare_agent_launch(AgentKind::Codex).unwrap();
        assert!(!codex.is_resume);
        assert_eq!(codex.kind, AgentKind::Codex);
        assert_ne!(codex.session_id, first.session_id);
        assert_rfc4122_v4_uuid(&codex.session_id);
    }

    #[test]
    fn two_phase_send_keeps_threads_unsent_until_confirm_send_records_round() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "Check clone", Origin::Local)
            .unwrap();
        let events = session.subscribe();

        let dispatch = session.prepare_send(None, AgentKind::Claude).unwrap();
        assert_eq!(dispatch.round, 1);
        assert_eq!(dispatch.thread_ids, vec![thread.id.clone()]);
        assert!(dispatch.prompt.contains(&thread.id));
        assert_eq!(
            session.threads().last().unwrap().agent,
            Some(AgentThreadState::Unsent)
        );
        assert!(fakes.store.rounds().unwrap().is_empty());

        let (ids, prompt) = (&dispatch.thread_ids, &dispatch.prompt);
        let (recorded, view) = session
            .confirm_send(1, AgentRoundKind::Send, ids, prompt)
            .unwrap();
        assert_eq!((recorded.round, view.local_unsent_count), (1, 0));
        assert_eq!(
            session.threads().last().unwrap().agent,
            Some(AgentThreadState::Sent { round: 1 })
        );
        assert_eq!(fakes.store.rounds().unwrap().len(), 1);
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::ThreadsChanged { .. }
        ));
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::AgentRound { round, .. } if round.round == 1
        ));

        session.reply(&thread.id, "Follow-up").unwrap();
        let second_dispatch = session.prepare_send(None, AgentKind::Claude).unwrap();
        assert_eq!(second_dispatch.round, 2);
    }

    #[test]
    fn prepass_write_creates_answered_local_threads_with_snapshots() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();

        let prepass = session.prepare_prepass(AgentKind::Claude).unwrap();
        assert_eq!(prepass.kind, AgentRoundKind::Prepass);
        assert!(prepass.thread_ids.is_empty());
        assert!(prepass.prompt.contains("prepass-write"));

        let (created, view) = session
            .prepass_write(vec![
                PrepassFinding {
                    anchor: Anchor::line("src/a.rs", 2),
                    body: "[high] Unused binding.".into(),
                    author: None,
                },
                PrepassFinding {
                    anchor: Anchor::pr(),
                    body: "[nit] Clarify PR title.".into(),
                    author: Some(" claude ".into()),
                },
                PrepassFinding {
                    anchor: Anchor::pr(),
                    body: "   ".into(),
                    author: None,
                },
            ])
            .unwrap();
        assert_eq!(created.len(), 2);
        assert_eq!(created[0].origin, Origin::Local);
        assert_eq!(created[0].messages[0].author, "agent");
        assert!(!created[0].messages[0].viewer_did_author);
        assert_eq!(created[0].agent, Some(AgentThreadState::Answered));
        assert_eq!(created[0].anchor.snapshot.as_deref(), Some("let x = 1;"));
        assert_eq!(created[1].messages[0].author, "claude");
        assert_eq!(view.local_unsent_count, 0);

        let (_, after_reply) = session.reply(&created[0].id, "Please remove it.").unwrap();
        assert_eq!(after_reply.local_unsent_count, 1);
    }

    #[test]
    fn prepare_send_rejects_empty_and_prepass_rejects_unsafe_paths() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let err = session.prepare_send(None, AgentKind::Claude).unwrap_err();
        assert_eq!(err.to_string(), "no unsent local comments to send");

        let traversal = session.prepass_write(vec![PrepassFinding {
            anchor: Anchor::line("../../etc/passwd", 1),
            body: "[high] Bad path".into(),
            author: None,
        }]);
        assert!(traversal.is_err());
        assert!(fakes.store.saved().local.threads.is_empty());
    }

    #[test]
    fn prepare_agent_launch_and_confirm_send_roll_back_on_save_failure() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "Check", Origin::Local)
            .unwrap();

        fakes.store.fail_saves_with(Some("disk full"));
        assert!(session.prepare_agent_launch(AgentKind::Claude).is_err());
        assert!(session.saved.session.agent_session_id.is_none());

        assert!(
            session
                .confirm_send(
                    1,
                    AgentRoundKind::Send,
                    std::slice::from_ref(&thread.id),
                    "prompt"
                )
                .is_err()
        );
        assert_eq!(
            session.threads().last().unwrap().agent,
            Some(AgentThreadState::Unsent)
        );
        assert_eq!(session.saved.local.next_round, 0);

        fakes.store.fail_saves_with(None);
        let plan = session.prepare_agent_launch(AgentKind::Claude).unwrap();
        assert!(!plan.is_resume);
    }

    #[test]
    fn confirm_send_rejects_stale_rounds_and_kind_thread_id_mismatches() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let (thread, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "Check", Origin::Local)
            .unwrap();
        let ids = std::slice::from_ref(&thread.id);

        assert!(
            session
                .confirm_send(0, AgentRoundKind::Send, ids, "p")
                .is_err()
        );
        assert!(
            session
                .confirm_send(1, AgentRoundKind::Send, &[], "p")
                .is_err()
        );
        assert!(
            session
                .confirm_send(1, AgentRoundKind::Prepass, ids, "p")
                .is_err()
        );
        let conflict_error = session
            .confirm_send(1, AgentRoundKind::Conflict, ids, "p")
            .unwrap_err();
        assert_eq!(
            conflict_error.to_string(),
            "conflict round cannot include thread IDs"
        );

        session
            .confirm_send(1, AgentRoundKind::Send, ids, "p")
            .unwrap();
        let stale = session.confirm_send(1, AgentRoundKind::Send, ids, "p");
        assert!(
            stale
                .unwrap_err()
                .to_string()
                .contains("stale or duplicate")
        );
    }

    #[test]
    fn prepass_write_rejects_dot_git_and_zero_bounds() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        for bad_anchor in [
            Anchor::line(".git/config", 1),
            Anchor::line("sub/.GIT/HEAD", 1),
            Anchor::line("src/a.rs", 0),
        ] {
            let err = session.prepass_write(vec![PrepassFinding {
                anchor: bad_anchor,
                body: "[high] bad".into(),
                author: None,
            }]);
            assert!(err.is_err());
        }
        assert!(fakes.store.saved().local.threads.is_empty());
    }

    #[test]
    fn prepass_write_strips_untrusted_snapshot_and_normalizes_file_anchors() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();

        let mut left_anchor = Anchor::side_line("src/a.rs", Side::Left, 1);
        left_anchor.snapshot = Some("untrusted".into());
        let mut file_anchor = Anchor::file("src/a.rs");
        file_anchor.start = Some(5);
        file_anchor.end = Some(9);
        file_anchor.snapshot = Some("stale".into());

        let (created, _) = session
            .prepass_write(vec![
                PrepassFinding {
                    anchor: left_anchor,
                    body: "[med] left".into(),
                    author: None,
                },
                PrepassFinding {
                    anchor: file_anchor,
                    body: "[low] file".into(),
                    author: None,
                },
            ])
            .unwrap();
        assert_eq!(created[0].anchor.snapshot, None);
        assert_eq!(created[1].anchor.kind, AnchorKind::File);
        assert_eq!(
            (created[1].anchor.start, created[1].anchor.end),
            (None, None)
        );
        assert_eq!(created[1].anchor.snapshot, None);
    }

    #[test]
    fn prepass_write_rejects_non_pr_files_and_accepts_pr_files_and_pr_anchor() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/unchanged.rs", "fn untouched() {}\n");
        let mut session = fakes.open_synced();

        let error = session
            .prepass_write(vec![
                PrepassFinding {
                    anchor: Anchor::line("src/a.rs", 1),
                    body: "[low] valid file".into(),
                    author: None,
                },
                PrepassFinding {
                    anchor: Anchor::line("src/unchanged.rs", 1),
                    body: "[high] not changed by PR".into(),
                    author: None,
                },
            ])
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("is not a file this pull request changes"),
            "{error}"
        );
        assert!(fakes.store.saved().local.threads.is_empty());

        let (created, _) = session
            .prepass_write(vec![
                PrepassFinding {
                    anchor: Anchor::line("src/b.rs", 1),
                    body: "[med] changed file".into(),
                    author: None,
                },
                PrepassFinding {
                    anchor: Anchor::pr(),
                    body: "[nit] pr note".into(),
                    author: None,
                },
            ])
            .unwrap();
        assert_eq!(created.len(), 2);
    }

    #[test]
    fn prepare_conflict_resolution_rejects_unsynced_empty_and_unsafe_paths() {
        let fakes = Fakes::new(100);
        assert!(
            fakes
                .open()
                .prepare_conflict_resolution(&["src/a.rs".into()], AgentKind::Claude)
                .is_err()
        );
        let session = fakes.open_synced();
        assert!(
            session
                .prepare_conflict_resolution(&[], AgentKind::Claude)
                .is_err()
        );
        for unsafe_path in ["../etc/passwd", "/abs/file.rs", ".git/config"] {
            assert!(
                session
                    .prepare_conflict_resolution(&[unsafe_path.into()], AgentKind::Claude)
                    .is_err()
            );
        }
    }

    #[test]
    fn prepare_conflict_resolution_builds_conflict_dispatch_and_confirm_send_records_it() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();

        let paths = vec!["src/a.rs".to_owned(), "src/a.rs".to_owned()];
        let dispatch = session
            .prepare_conflict_resolution(&paths, AgentKind::Claude)
            .unwrap();
        assert_eq!(dispatch.round, 1);
        assert_eq!(dispatch.kind, AgentRoundKind::Conflict);
        assert!(dispatch.thread_ids.is_empty());
        assert_eq!(dispatch.prompt.matches("- `src/a.rs`").count(), 1);

        let (recorded, _) = session
            .confirm_send(
                dispatch.round,
                AgentRoundKind::Conflict,
                &[],
                &dispatch.prompt,
            )
            .unwrap();
        assert_eq!(recorded.kind, AgentRoundKind::Conflict);
        assert_eq!(fakes.store.rounds().unwrap(), vec![recorded]);
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::AgentRound { round, .. } if round.kind == AgentRoundKind::Conflict
        ));
    }
}
