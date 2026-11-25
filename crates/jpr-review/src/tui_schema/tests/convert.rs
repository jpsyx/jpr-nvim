//! Unit tests converting `cli-tui` [`Answers`] maps into typed [`Command`] values.

use std::path::PathBuf;

use cli_tui::Answers;

use super::super::answers_to_command;
use super::super::convert::apply_answers_to_command_with_env;
use super::answers_from;
use crate::cli::Command;

fn assert_converts(command_id: &str, pairs: &[(&str, &str)], expected: &Command) {
    let actual = answers_to_command(command_id, &answers_from(pairs))
        .unwrap_or_else(|error| panic!("conversion failed for `{command_id}`: {error:#}"));
    assert_eq!(&actual, expected);
}

fn sample_reply(socket: Option<&str>, body: Option<&str>) -> Command {
    Command::Reply {
        thread_id: Some("loc-1".into()),
        body: body.map(str::to_owned),
        pr: None,
        repo: None,
        socket: socket.map(PathBuf::from),
    }
}

#[test]
fn answers_to_command_builds_typed_commands_for_every_subcommand() {
    assert_converts(
        "prs",
        &[
            ("custom_repo", "true"),
            ("repo", "octo/widgets"),
            ("limit", "25"),
        ],
        &Command::Prs {
            repo: Some("octo/widgets".into()),
            limit: 25,
        },
    );
    assert_converts(
        "checkout",
        &[
            ("source", "manual"),
            ("pr_manual", "#19"),
            ("custom_repo", "true"),
            ("repo", "octo/widgets"),
            ("custom_worktree", "true"),
            ("worktree_cmd", "wt pr {n}"),
        ],
        &Command::Checkout {
            pr: Some(19),
            repo: Some("octo/widgets".into()),
            worktree_cmd: Some("wt pr {n}".into()),
        },
    );
    assert_converts(
        "threads",
        &[
            ("target_mode", "socket"),
            ("socket", "/tmp/jpr.sock"),
            ("is_local_only", "true"),
        ],
        &Command::Threads {
            pr: None,
            repo: None,
            socket: Some(PathBuf::from("/tmp/jpr.sock")),
            is_local_only: true,
        },
    );
    assert_converts_remaining_subcommands();
}

fn assert_converts_remaining_subcommands() {
    assert_converts(
        "reply",
        &[
            ("target_mode", "pr"),
            ("pr", "7"),
            ("repo", ""),
            ("thread_id", "loc-1"),
            ("body", "Fixed in abc1234."),
        ],
        &Command::Reply {
            thread_id: Some("loc-1".into()),
            body: Some("Fixed in abc1234.".into()),
            pr: Some(7),
            repo: None,
            socket: None,
        },
    );
    assert_converts(
        "prepass-write",
        &[
            ("target_mode", "pr"),
            ("pr", "7"),
            ("repo", "octo/widgets"),
            ("input_mode", "file"),
            ("input", "findings.json"),
        ],
        &Command::PrepassWrite {
            input: Some(PathBuf::from("findings.json")),
            pr: Some(7),
            repo: Some("octo/widgets".into()),
            socket: None,
        },
    );
    assert_converts_state_and_daemon_subcommands();
}

fn assert_converts_state_and_daemon_subcommands() {
    assert_converts(
        "local",
        &[("base_mode", "custom"), ("base", "HEAD")],
        &Command::Local {
            base: Some("HEAD".into()),
            repo: None,
            no_pr: false,
        },
    );
    assert_converts(
        "local",
        &[("base_mode", "auto"), ("detect_pr", "false")],
        &Command::Local {
            base: None,
            repo: None,
            no_pr: true,
        },
    );
    assert_converts(
        "state-path",
        &[
            ("session_mode", "pr"),
            ("pr", "7"),
            ("repo", "octo/widgets"),
        ],
        &Command::StatePath {
            pr: Some(7),
            is_local: false,
            repo: Some("octo/widgets".into()),
        },
    );
    assert_converts(
        "state-path",
        &[("session_mode", "local")],
        &Command::StatePath {
            pr: None,
            is_local: true,
            repo: None,
        },
    );
    assert_converts(
        "serve",
        &[
            ("session_mode", "pr"),
            ("pr", "7"),
            ("repo", "octo/widgets"),
            ("poll", "30"),
        ],
        &Command::Serve {
            pr: Some(7),
            is_local: false,
            base: None,
            repo: Some("octo/widgets".into()),
            poll: 30,
        },
    );
    assert_converts(
        "serve",
        &[
            ("session_mode", "local"),
            ("base", "develop"),
            ("poll", "0"),
        ],
        &Command::Serve {
            pr: None,
            is_local: true,
            base: Some("develop".into()),
            repo: None,
            poll: 0,
        },
    );
    assert_converts("guide", &[], &Command::Guide);
}

#[test]
fn answers_to_command_rejects_invalid_and_incomplete_inputs() {
    assert!(answers_to_command("unknown", &Answers::new()).is_err());
    assert!(answers_to_command("prs", &answers_from(&[("limit", "0")])).is_err());
    assert!(answers_to_command("prs", &answers_from(&[("limit", "abc")])).is_err());
    assert!(
        answers_to_command(
            "checkout",
            &answers_from(&[("source", "bogus"), ("pr", "7")]),
        )
        .is_err()
    );
    assert!(answers_to_command("state-path", &answers_from(&[("pr", "abc")])).is_err());
    assert!(
        answers_to_command("state-path", &answers_from(&[("pr", "7"), ("repo", "bad")])).is_err()
    );
    assert!(
        answers_to_command(
            "serve",
            &answers_from(&[("pr", "7"), ("repo", "octo/widgets"), ("poll", "-1")]),
        )
        .is_err()
    );
    assert!(answers_to_command("threads", &Answers::new()).is_err());
    assert!(
        answers_to_command(
            "prepass-write",
            &answers_from(&[("target_mode", "socket"), ("socket", "/tmp/a.sock")]),
        )
        .is_err()
    );
}

#[test]
fn apply_answers_preserves_ambient_jpr_socket_and_keeps_explicit_or_edited_sockets() {
    let partial_reply = sample_reply(None, None);
    let ambient = Some("/tmp/ambient.sock");
    let ambient_answers = answers_from(&[
        ("target_mode", "socket"),
        ("socket", "/tmp/ambient.sock"),
        ("thread_id", "loc-1"),
        ("body", "Fixed."),
    ]);
    assert_eq!(
        apply_answers_to_command_with_env(&partial_reply, &ambient_answers, ambient).unwrap(),
        sample_reply(None, Some("Fixed."))
    );

    let edited_answers = answers_from(&[
        ("target_mode", "socket"),
        ("socket", "/tmp/other.sock"),
        ("thread_id", "loc-1"),
        ("body", "Fixed."),
    ]);
    assert_eq!(
        apply_answers_to_command_with_env(&partial_reply, &edited_answers, ambient).unwrap(),
        sample_reply(Some("/tmp/other.sock"), Some("Fixed."))
    );

    let explicit_reply = sample_reply(Some("/tmp/ambient.sock"), None);
    assert_eq!(
        apply_answers_to_command_with_env(&explicit_reply, &ambient_answers, ambient).unwrap(),
        sample_reply(Some("/tmp/ambient.sock"), Some("Fixed."))
    );
}
