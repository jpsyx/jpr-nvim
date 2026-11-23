use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use review_core::ports::PullRequest;
use review_core::ports::Workspace;

use super::*;
use crate::GitWorkspace;
use crate::process::run;
use crate::test_support::{git, repo};

fn create_pr_from_head(head_ref: &str, is_cross_repository: bool) -> PullRequest {
    PullRequest {
        owner: "octo".into(),
        repo: "widgets".into(),
        number: 7,
        title: "Fix the widget".into(),
        url: "https://github.com/octo/widgets/pull/7".into(),
        node_id: "PR_7".into(),
        author: "alice".into(),
        head_ref: head_ref.into(),
        head_sha: "abc123".into(),
        base_ref: "main".into(),
        base_sha: "base000".into(),
        is_cross_repository,
    }
}

fn create_origin_and_worktree() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let dir = repo();
    let worktree = dir.path().join("widgets");
    let origin = dir.path().join("origin.git");
    git(
        dir.path(),
        &["init", "--bare", "-q", "-b", "main", "origin.git"],
    );
    git(
        &worktree,
        &["remote", "add", "origin", origin.to_str().unwrap()],
    );
    git(&worktree, &["push", "-q", "origin", "main:refs/heads/main"]);
    git(
        &worktree,
        &["push", "-q", "origin", "main:refs/heads/fix/widget"],
    );
    (dir, worktree, origin)
}

fn commit_change(worktree: &Path, name: &str, body: &str) -> String {
    fs::write(worktree.join(name), body).unwrap();
    git(worktree, &["add", name]);
    git(worktree, &["commit", "-q", "-m", name]);
    run("git", &["rev-parse", "HEAD"], worktree)
        .unwrap()
        .trim()
        .to_owned()
}

fn read_ref_sha(repo_dir: &Path, reference: &str) -> String {
    run("git", &["rev-parse", reference], repo_dir)
        .unwrap()
        .trim()
        .to_owned()
}

#[test]
fn pushes_mismatched_local_branch_when_merge_config_points_to_pr_branch() {
    let (_dir, worktree, origin) = create_origin_and_worktree();
    let main_sha = read_ref_sha(&origin, "refs/heads/main");
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    git(
        &worktree,
        &["config", "branch.pr-7.merge", "refs/heads/fix/widget"],
    );
    let expected_sha = commit_change(&worktree, "fix.txt", "patched\n");

    let pr = create_pr_from_head("fix/widget", false);
    let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

    assert_eq!(pushed_sha, expected_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), main_sha);
}

#[test]
fn pushes_mismatched_local_branch_when_branch_merge_config_is_unset() {
    let (_dir, worktree, origin) = create_origin_and_worktree();
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    let expected_sha = commit_change(&worktree, "untracked_cfg.txt", "v2\n");

    let pr = create_pr_from_head("fix/widget", false);
    let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

    assert_eq!(pushed_sha, expected_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
}

#[test]
fn pushes_detached_head_to_pr_branch_on_origin() {
    let (_dir, worktree, origin) = create_origin_and_worktree();
    git(&worktree, &["checkout", "-q", "--detach"]);
    let expected_sha = commit_change(&worktree, "detached.txt", "detached\n");

    let pr = create_pr_from_head("fix/widget", false);
    let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

    assert_eq!(pushed_sha, expected_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
}

#[test]
fn rejects_invalid_head_refs_before_spawning_git_push() {
    let non_repo = tempfile::tempdir().unwrap();
    let invalid_refs = [
        "",
        "@",
        "-f",
        "--mirror",
        "/fix",
        "fix/",
        "fix.",
        "fix.lock",
        "fix/sub.lock",
        "fix/.hidden",
        "fix//widget",
        "fix..widget",
        "fix@{0}",
        "fix\\widget",
        "fix~1",
        "fix^1",
        "fix:widget",
        "fix?widget",
        "fix*widget",
        "fix[0]",
        "fix widget",
        "fix\twidget",
        "fix\nwidget",
        "fix\0widget",
    ];
    for bad_ref in invalid_refs {
        let pr = create_pr_from_head(bad_ref, false);
        let error =
            push_head_to_pr_branch(non_repo.path(), &pr, Duration::from_secs(5)).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("invalid pull request head branch"),
            "unexpected error for {bad_ref:?}: {message}"
        );
    }
}

#[test]
fn prefers_push_remote_over_branch_remote_and_rejects_unsafe_config_targets() {
    let (dir, worktree, _origin) = create_origin_and_worktree();
    let fork = dir.path().join("fork.git");
    git(
        dir.path(),
        &["init", "--bare", "-q", "-b", "main", "fork.git"],
    );
    git(
        &worktree,
        &["remote", "add", "fork", fork.to_str().unwrap()],
    );
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    git(&worktree, &["config", "branch.pr-7.pushRemote", "fork"]);
    let expected_sha = commit_change(&worktree, "fork.txt", "forked\n");

    let pr = create_pr_from_head("fix/widget", false);
    let pushed_sha = GitWorkspace::new(worktree.clone()).push_head(&pr).unwrap();
    assert_eq!(pushed_sha, expected_sha);
    assert_eq!(read_ref_sha(&fork, "refs/heads/fix/widget"), expected_sha);

    git(
        &worktree,
        &["config", "branch.pr-7.pushRemote", "--upload-pack=bad"],
    );
    assert!(GitWorkspace::new(worktree.clone()).push_head(&pr).is_err());

    git(&worktree, &["config", "--unset", "branch.pr-7.pushRemote"]);
    git(&worktree, &["config", "branch.pr-7.merge", "refs/tags/v1"]);
    assert!(GitWorkspace::new(worktree).push_head(&pr).is_err());
}

#[test]
fn refuses_to_push_when_branch_tracks_different_upstream_branch() {
    let (_dir, worktree, origin) = create_origin_and_worktree();
    let main_sha = read_ref_sha(&origin, "refs/heads/main");
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    git(
        &worktree,
        &["config", "branch.pr-7.merge", "refs/heads/main"],
    );
    let _local_sha = commit_change(&worktree, "accidental.txt", "do not land on main\n");

    let pr = create_pr_from_head("fix/widget", false);
    let error = GitWorkspace::new(worktree).push_head(&pr).unwrap_err();
    let message = format!("{error:#}");

    assert!(
        message.contains("does not match pull request head branch"),
        "{message}"
    );
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), main_sha);
}

#[test]
fn refuses_cross_repository_push_from_detached_head_or_untracked_branch() {
    let (_dir, worktree, origin) = create_origin_and_worktree();
    let origin_main_sha = read_ref_sha(&origin, "refs/heads/main");
    let fork_pr = create_pr_from_head("main", true);

    git(&worktree, &["checkout", "-q", "--detach"]);
    let _detached_sha = commit_change(&worktree, "fork_detached.txt", "fork commit\n");
    let detached_error = GitWorkspace::new(worktree.clone())
        .push_head(&fork_pr)
        .unwrap_err();
    assert!(
        format!("{detached_error:#}").contains("cross-repository"),
        "{detached_error:#}"
    );
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    let untracked_error = GitWorkspace::new(worktree.clone())
        .push_head(&fork_pr)
        .unwrap_err();
    assert!(
        format!("{untracked_error:#}").contains("cross-repository"),
        "{untracked_error:#}"
    );
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    let missing_merge_error = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap_err();
    assert!(
        format!("{missing_merge_error:#}").contains("cross-repository"),
        "{missing_merge_error:#}"
    );
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);
}

#[test]
fn refuses_cross_repository_push_when_remote_points_to_base_repository() {
    let (_dir, worktree, _origin) = create_origin_and_worktree();
    let fork_pr = create_pr_from_head("main", true);
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    git(
        &worktree,
        &["config", "branch.pr-7.merge", "refs/heads/main"],
    );
    let _fork_sha = commit_change(&worktree, "fork_main.txt", "fork commit\n");

    for base_url in [
        "https://github.com/Octo/Widgets.git",
        "https://token@ghe.example.com/octo/widgets.git",
        "git@github.com:octo/WIDGETS.GIT",
        "ssh://git@github.com:22/octo/widgets",
    ] {
        git(&worktree, &["remote", "set-url", "origin", base_url]);
        let error = GitWorkspace::new(worktree.clone())
            .push_head(&fork_pr)
            .unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("octo/widgets"),
            "expected base repo refusal for {base_url}: {message}"
        );
    }

    git(
        &worktree,
        &[
            "config",
            "branch.pr-7.remote",
            "https://github.com/octo/widgets.git",
        ],
    );
    let direct_url_error = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap_err();
    assert!(
        format!("{direct_url_error:#}").contains("octo/widgets"),
        "{direct_url_error:#}"
    );
}

fn create_bare_fork_remote(dir: &Path, worktree: &Path) -> PathBuf {
    let fork = dir.join("contributor-widgets.git");
    git(
        dir,
        &[
            "init",
            "--bare",
            "-q",
            "-b",
            "main",
            "contributor-widgets.git",
        ],
    );
    git(worktree, &["remote", "add", "fork", fork.to_str().unwrap()]);
    git(worktree, &["push", "-q", "fork", "main:refs/heads/main"]);
    fork
}

#[test]
fn pushes_cross_repository_pr_when_explicit_fork_remote_is_configured() {
    let (dir, worktree, origin) = create_origin_and_worktree();
    let origin_main_sha = read_ref_sha(&origin, "refs/heads/main");
    let fork = create_bare_fork_remote(dir.path(), &worktree);

    let fork_pr = create_pr_from_head("main", true);
    git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
    git(&worktree, &["config", "branch.pr-7.remote", "fork"]);
    git(
        &worktree,
        &["config", "branch.pr-7.merge", "refs/heads/main"],
    );
    let first_fork_sha = commit_change(&worktree, "fork_ok.txt", "fork 1\n");

    let pushed_sha = GitWorkspace::new(worktree.clone())
        .push_head(&fork_pr)
        .unwrap();
    assert_eq!(pushed_sha, first_fork_sha);
    assert_eq!(read_ref_sha(&fork, "refs/heads/main"), first_fork_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

    git(&worktree, &["config", "--unset", "branch.pr-7.merge"]);
    git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
    git(&worktree, &["config", "branch.pr-7.pushRemote", "fork"]);
    let second_fork_sha = commit_change(&worktree, "fork_ok2.txt", "fork 2\n");
    let pushed_via_push_remote = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap();
    assert_eq!(pushed_via_push_remote, second_fork_sha);
    assert_eq!(read_ref_sha(&fork, "refs/heads/main"), second_fork_sha);
    assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);
}
