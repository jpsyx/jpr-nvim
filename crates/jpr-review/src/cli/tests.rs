use super::*;
use clap::CommandFactory;

#[test]
fn the_surface_is_well_formed() {
    Cli::command().debug_assert();
}

#[test]
fn a_bare_invocation_has_no_subcommand() {
    let cli = Cli::try_parse_from(["jpr-review"]).unwrap();
    assert!(cli.command.is_none());
}

#[test]
fn local_subcommand_accepts_optional_base_repo_and_no_pr() {
    let bare = Cli::try_parse_from(["jpr-review", "local"]).unwrap();
    assert_eq!(
        bare.command,
        Some(Command::Local {
            base: None,
            repo: None,
            no_pr: false,
        })
    );
    let full = Cli::try_parse_from([
        "jpr-review",
        "local",
        "--base",
        "HEAD",
        "--repo",
        "octo/widgets",
        "--no-pr",
    ])
    .unwrap();
    assert_eq!(
        full.command,
        Some(Command::Local {
            base: Some("HEAD".into()),
            repo: Some("octo/widgets".into()),
            no_pr: true,
        })
    );
}

#[test]
fn checkout_takes_a_number_and_a_worktree_command() {
    let cli = Cli::try_parse_from([
        "jpr-review",
        "checkout",
        "--pr",
        "7",
        "--worktree-cmd",
        "wt pr {n}",
    ])
    .unwrap();
    assert_eq!(
        cli.command,
        Some(Command::Checkout {
            pr: Some(7),
            repo: None,
            worktree_cmd: Some("wt pr {n}".into())
        })
    );
}

#[test]
fn checkout_takes_the_repository_it_expects() {
    let cli = Cli::try_parse_from([
        "jpr-review",
        "checkout",
        "--pr",
        "12",
        "--repo",
        "octo/gadgets",
    ])
    .unwrap();
    assert_eq!(
        cli.command,
        Some(Command::Checkout {
            pr: Some(12),
            repo: Some("octo/gadgets".into()),
            worktree_cmd: None
        })
    );
}

#[test]
fn serve_accepts_pr_or_local_mode_and_rejects_conflicting_flags() {
    let pr_cli =
        Cli::try_parse_from(["jpr-review", "serve", "--pr", "7", "--repo", "octo/widgets"])
            .unwrap();
    assert_eq!(
        pr_cli.command,
        Some(Command::Serve {
            pr: Some(7),
            is_local: false,
            base: None,
            repo: Some("octo/widgets".into()),
            poll: 60
        })
    );
    let local_cli =
        Cli::try_parse_from(["jpr-review", "serve", "--local", "--base", "develop"]).unwrap();
    assert_eq!(
        local_cli.command,
        Some(Command::Serve {
            pr: None,
            is_local: true,
            base: Some("develop".into()),
            repo: None,
            poll: 60
        })
    );
    assert!(Cli::try_parse_from(["jpr-review", "serve", "--pr", "7"]).is_err());
    assert!(
        Cli::try_parse_from([
            "jpr-review",
            "serve",
            "--pr",
            "7",
            "--local",
            "--repo",
            "o/r"
        ])
        .is_err()
    );
    assert!(
        Cli::try_parse_from([
            "jpr-review",
            "serve",
            "--pr",
            "7",
            "--repo",
            "o/r",
            "--base",
            "main"
        ])
        .is_err()
    );
}

#[test]
fn state_path_accepts_local_flag_and_rejects_conflict_with_pr() {
    let local = Cli::try_parse_from(["jpr-review", "state-path", "--local"]).unwrap();
    assert_eq!(
        local.command,
        Some(Command::StatePath {
            pr: None,
            is_local: true,
            repo: None,
        })
    );
    assert!(Cli::try_parse_from(["jpr-review", "state-path", "--pr", "7", "--local"]).is_err());
}

#[test]
fn guide_subcommand_needs_no_arguments() {
    let cli = Cli::try_parse_from(["jpr-review", "guide"]).unwrap();
    assert_eq!(cli.command, Some(Command::Guide));
}

#[test]
fn threads_subcommand_captures_pr_repo_and_local_flag() {
    let cli = Cli::try_parse_from([
        "jpr-review",
        "threads",
        "--pr",
        "7",
        "--repo",
        "octo/widgets",
        "--local",
    ])
    .unwrap();
    assert_eq!(
        cli.command,
        Some(Command::Threads {
            pr: Some(7),
            repo: Some("octo/widgets".into()),
            socket: None,
            is_local_only: true,
        })
    );
}

#[test]
fn reply_subcommand_captures_positional_thread_id_and_body() {
    let cli =
        Cli::try_parse_from(["jpr-review", "reply", "loc-1", "--body", "Done. (abc1234)"]).unwrap();
    assert_eq!(
        cli.command,
        Some(Command::Reply {
            thread_id: Some("loc-1".into()),
            body: Some("Done. (abc1234)".into()),
            pr: None,
            repo: None,
            socket: None,
        })
    );
}

#[test]
fn prepass_write_subcommand_captures_input_file_flag() {
    let cli =
        Cli::try_parse_from(["jpr-review", "prepass-write", "--input", "findings.json"]).unwrap();
    assert_eq!(
        cli.command,
        Some(Command::PrepassWrite {
            input: Some(std::path::PathBuf::from("findings.json")),
            pr: None,
            repo: None,
            socket: None,
        })
    );
}

#[test]
fn prs_uses_default_limit_and_optional_repo() {
    let bare = Cli::try_parse_from(["jpr-review", "prs"]).unwrap();
    assert_eq!(
        bare.command,
        Some(Command::Prs {
            repo: None,
            limit: 50,
        })
    );
    let filtered = Cli::try_parse_from([
        "jpr-review",
        "prs",
        "--repo",
        "octo/widgets",
        "--limit",
        "15",
    ])
    .unwrap();
    assert_eq!(
        filtered.command,
        Some(Command::Prs {
            repo: Some("octo/widgets".into()),
            limit: 15,
        })
    );
    assert!(Cli::try_parse_from(["jpr-review", "prs", "--limit", "0"]).is_err());
}

#[test]
fn owners_and_repos_apply_default_limits_and_reject_zero() {
    let owners = Cli::try_parse_from(["jpr-review", "owners"]).unwrap();
    assert_eq!(owners.command, Some(Command::Owners));
    let default_repos = Cli::try_parse_from(["jpr-review", "repos"]).unwrap();
    assert_eq!(
        default_repos.command,
        Some(Command::Repos {
            owner: None,
            limit: 100,
        })
    );
    let org_repos =
        Cli::try_parse_from(["jpr-review", "repos", "--owner", "acme", "--limit", "25"]).unwrap();
    assert_eq!(
        org_repos.command,
        Some(Command::Repos {
            owner: Some("acme".into()),
            limit: 25,
        })
    );
    assert!(Cli::try_parse_from(["jpr-review", "repos", "--limit", "0"]).is_err());
}
