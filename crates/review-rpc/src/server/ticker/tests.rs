use super::*;

const MINUTE: Duration = Duration::from_secs(60);

#[test]
fn a_full_interval_since_the_last_sync_means_sync() {
    assert_eq!(
        get_poll_step_from_elapsed(MINUTE, MINUTE, true),
        PollStep::Sync
    );
    assert_eq!(
        get_poll_step_from_elapsed(MINUTE * 2, MINUTE, false),
        PollStep::Sync
    );
}

#[test]
fn between_syncs_a_waiting_queue_is_retried() {
    assert_eq!(
        get_poll_step_from_elapsed(Duration::from_secs(20), MINUTE, true),
        PollStep::Retry
    );
    assert_eq!(
        get_poll_step_from_elapsed(Duration::from_secs(20), MINUTE, false),
        PollStep::Wait
    );
}

#[test]
fn the_poller_wakes_at_the_shorter_interval() {
    let retry = Some(Duration::from_secs(20));
    assert_eq!(
        get_wake_interval_from_poll_and_retry(MINUTE, retry),
        Duration::from_secs(20)
    );
    assert_eq!(
        get_wake_interval_from_poll_and_retry(Duration::from_secs(5), retry),
        Duration::from_secs(5)
    );
    assert_eq!(get_wake_interval_from_poll_and_retry(MINUTE, None), MINUTE);
}

#[test]
fn wake_interval_ignores_zero_and_enforces_minimum_floor() {
    assert_eq!(get_wake_interval_from_intervals(None, None, None), None);
    assert_eq!(
        get_wake_interval_from_intervals(
            Some(Duration::ZERO),
            Some(Duration::ZERO),
            Some(Duration::ZERO),
        ),
        None
    );
    assert_eq!(
        get_wake_interval_from_intervals(None, None, Some(Duration::from_nanos(1))),
        Some(Duration::from_millis(1))
    );
    assert_eq!(
        get_wake_interval_from_intervals(
            Some(MINUTE),
            Some(Duration::from_secs(20)),
            Some(Duration::from_secs(2)),
        ),
        Some(Duration::from_secs(2))
    );
}

#[test]
fn watch_ticks_do_not_trigger_retry_when_retry_interval_not_elapsed_or_none() {
    let no_retry = TickerConfig {
        poll_every: Some(Duration::from_secs(10)),
        retry_every: None,
        watch_every: Some(Duration::from_millis(25)),
        wake_interval: Duration::from_millis(25),
    };
    let watch_tick = Duration::from_millis(30);
    assert_eq!(
        get_ticker_actions_from_elapsed(no_retry, watch_tick, watch_tick, watch_tick, true),
        TickerActions {
            poll: PollStep::Wait,
            should_watch: true,
        }
    );

    let slow_retry = TickerConfig {
        retry_every: Some(Duration::from_secs(10)),
        ..no_retry
    };
    assert_eq!(
        get_ticker_actions_from_elapsed(slow_retry, watch_tick, watch_tick, watch_tick, true),
        TickerActions {
            poll: PollStep::Wait,
            should_watch: true,
        }
    );
    assert_eq!(
        get_ticker_actions_from_elapsed(
            slow_retry,
            watch_tick,
            Duration::from_secs(10),
            Duration::ZERO,
            true,
        ),
        TickerActions {
            poll: PollStep::Retry,
            should_watch: false,
        }
    );
}

#[test]
fn ticker_skips_sync_and_retry_while_unlinked_but_still_watches_worktree() {
    use review_core::fakes::{
        FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports, sample_pr,
    };
    use review_model::LocalReviewContext;

    let forge = FakeForge::new(sample_pr(), review_core::ports::ForgeSnapshot::default());
    let store = MemoryStore::default();
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "old\n");
    workspace.put_disk("src/a.rs", "new\n");
    let clock = FixedClock::at(100);
    let ports = create_fake_ports(&forge, &store, &workspace, &clock);
    let context = LocalReviewContext {
        branch: "feat/local".into(),
        base_ref: "develop".into(),
        base_sha: "base000".into(),
        repo: None,
    };
    let session = Mutex::new(ReviewSession::open_local(context, ports).expect("local opens"));
    workspace.put_disk("src/b.rs", "added\n");

    let config = TickerConfig {
        poll_every: Some(Duration::from_millis(1)),
        retry_every: Some(Duration::from_millis(1)),
        watch_every: Some(Duration::from_millis(1)),
        wake_interval: Duration::from_millis(1),
    };
    let past = Instant::now()
        .checked_sub(Duration::from_secs(1))
        .expect("past instant");
    let mut last_sync = past;
    let mut last_retry = past;
    let mut last_watch = past;

    run_ticker_tick(
        &session,
        config,
        &mut last_sync,
        &mut last_retry,
        &mut last_watch,
    );

    assert_eq!(forge.fetches(), 0, "unlinked ticker must not sync forge");
    let files = session.lock().expect("lock").view().files;
    assert!(
        files.iter().any(|row| row.path == "src/b.rs"),
        "worktree watch must still refresh local files"
    );
}

#[test]
fn ticker_background_sync_auth_failure_emits_background_auth_sync_failed() {
    use review_core::fakes::{
        FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports, sample_pr,
    };
    use review_model::Event;

    let forge = FakeForge::new(sample_pr(), review_core::ports::ForgeSnapshot::default());
    let store = MemoryStore::default();
    let workspace = FakeWorkspace::default();
    let clock = FixedClock::at(100);
    let ports = create_fake_ports(&forge, &store, &workspace, &clock);
    let mut session = ReviewSession::open(7, ports).expect("opens");
    session.sync().expect("initial sync");
    let events = session.subscribe();
    forge.fail_auth_with(Some("gh auth login"));

    let session_mutex = Mutex::new(session);
    let config = TickerConfig {
        poll_every: Some(Duration::from_millis(1)),
        retry_every: None,
        watch_every: None,
        wake_interval: Duration::from_millis(1),
    };
    let past = Instant::now()
        .checked_sub(Duration::from_secs(1))
        .expect("past instant");
    let mut last_sync = past;
    let mut last_retry = past;
    let mut last_watch = past;
    run_ticker_tick(
        &session_mutex,
        config,
        &mut last_sync,
        &mut last_retry,
        &mut last_watch,
    );
    assert_eq!(
        events.try_recv().unwrap(),
        Event::SyncFailed {
            message: "gh auth login".into(),
            auth_required: true,
            is_background: true,
        }
    );
}
