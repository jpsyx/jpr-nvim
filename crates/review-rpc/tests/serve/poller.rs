//! Background poller integration tests for the JSON-RPC server.

use std::io::BufReader;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use review_rpc::{ServeOptions, serve};

use super::support::{EndsWhen, changed_snapshot, forge, messages, options, session, synced_views};

#[test]
fn the_poller_syncs_in_the_background() {
    let forge = forge();
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let watched = forge.clone();
    let reader = BufReader::new(EndsWhen {
        done: move || watched.fetches() >= 2,
        deadline: Instant::now() + Duration::from_secs(10),
    });
    serve(
        reader,
        &output,
        &session(&forge),
        &options(Some(Duration::from_millis(20))),
    )
    .unwrap();
    assert!(forge.fetches() >= 2, "fetched {} times", forge.fetches());
}

#[test]
fn the_poller_retries_a_refused_viewed_mark_between_syncs() {
    let forge = forge();
    let shared = session(&forge);
    {
        let mut session = shared.lock().unwrap();
        session.sync().unwrap();
        forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
    }
    forge.fail_writes_with(None);
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let watched = forge.clone();
    let reader = BufReader::new(EndsWhen {
        done: move || !watched.viewed_calls().is_empty(),
        deadline: Instant::now() + Duration::from_secs(10),
    });
    let options = ServeOptions {
        retry_every: Some(Duration::from_millis(20)),
        ..options(Some(Duration::from_secs(3600)))
    };
    serve(reader, &output, &shared, &options).unwrap();
    assert_eq!(forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
    assert_eq!(forge.fetches(), 1, "it retried without syncing again");
    assert!(
        messages(&output)
            .iter()
            .any(|message| message["params"]["type"] == "viewedChanged"),
        "the landed mark is announced"
    );
}

#[test]
fn the_poller_announces_each_sync_while_the_client_is_connected() {
    let forge = forge();
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let announced_while_open = Arc::new(AtomicBool::new(false));
    let (watched, written, announced) = (
        forge.clone(),
        Arc::clone(&output),
        Arc::clone(&announced_while_open),
    );
    // Once the first poll is announced the forge changes, and the reader
    // stays open until a later poll announces the change.
    let reader = BufReader::new(EndsWhen {
        done: move || {
            let views = synced_views(&written);
            if views.is_empty() {
                return false;
            }
            watched.set_snapshot(changed_snapshot());
            let has_changed = views.iter().any(|view| {
                view["files"]
                    .as_array()
                    .is_some_and(|files| files.len() == 2)
            });
            announced.store(has_changed, Ordering::SeqCst);
            has_changed
        },
        deadline: Instant::now() + Duration::from_secs(10),
    });
    serve(
        reader,
        &output,
        &session(&forge),
        &options(Some(Duration::from_millis(20))),
    )
    .unwrap();
    assert!(
        announced_while_open.load(Ordering::SeqCst),
        "{:?}",
        messages(&output)
    );
}
