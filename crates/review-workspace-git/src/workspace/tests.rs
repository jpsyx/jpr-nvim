//! The git workspace's tests, against real repositories in temporary
//! directories.

use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use review_core::ports::Workspace;

use super::*;
use crate::process::run;
use crate::test_support::{git, repo, stop_helper, wait_for_pid};

fn read_head_commit(dir: &Path) -> String {
    run("git", &["rev-parse", "HEAD"], dir)
        .unwrap()
        .trim()
        .to_owned()
}

/// Commits `content` as `name` in the repository at `root` and returns
/// the new commit.
fn commit_file(root: &Path, name: &str, content: &[u8]) -> String {
    fs::write(root.join(name), content).unwrap();
    git(root, &["add", "."]);
    git(root, &["commit", "-q", "-m", name]);
    read_head_commit(root)
}

#[test]
fn reads_a_file_larger_than_a_pipe_holds() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let content: Vec<u8> = b"0123456789abcdef\n".repeat(16 * 1024);
    let commit = commit_file(&root, "big.txt", &content);
    let workspace = GitWorkspace::new(root);
    assert_eq!(
        workspace.file_at(&commit, "big.txt").unwrap(),
        Some(content)
    );
}

#[test]
fn binary_content_reads_back_byte_for_byte() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let content: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
    let commit = commit_file(&root, "data.bin", &content);
    let workspace = GitWorkspace::new(root);
    assert_eq!(
        workspace.file_at(&commit, "data.bin").unwrap(),
        Some(content.clone())
    );
    assert_eq!(workspace.file_on_disk("data.bin").unwrap(), Some(content));
}

#[test]
fn a_missing_commit_reads_as_none() {
    let dir = repo();
    let workspace = GitWorkspace::new(dir.path().join("widgets"));
    assert_eq!(workspace.file_at(&"0".repeat(40), "a.txt").unwrap(), None);
}

#[test]
fn reads_a_file_at_a_commit_and_on_disk() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    fs::write(root.join("a.txt"), "changed\n").unwrap();
    let workspace = GitWorkspace::new(root);
    assert_eq!(
        workspace.file_at(&base, "a.txt").unwrap(),
        Some(b"a\n".to_vec())
    );
    assert_eq!(
        workspace.file_on_disk("a.txt").unwrap(),
        Some(b"changed\n".to_vec())
    );
    assert_eq!(workspace.file_at(&base, "absent.txt").unwrap(), None);
    assert_eq!(workspace.file_on_disk("absent.txt").unwrap(), None);
}

#[test]
fn the_merge_base_is_where_the_branch_left_the_base() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let branched_from = read_head_commit(&root);
    git(&root, &["checkout", "-q", "-b", "feature"]);
    fs::write(root.join("b.txt"), "b\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "feature"]);
    git(&root, &["checkout", "-q", "main"]);
    fs::write(root.join("c.txt"), "c\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "main moves on"]);
    let main_tip = read_head_commit(&root);
    git(&root, &["checkout", "-q", "feature"]);
    assert_eq!(
        GitWorkspace::new(root).merge_base(&main_tip).unwrap(),
        branched_from
    );
}

#[test]
fn finds_renames_against_a_commit() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    git(&root, &["mv", "a.txt", "renamed.txt"]);
    assert_eq!(
        GitWorkspace::new(root).renames(&base).unwrap(),
        [("a.txt".to_owned(), "renamed.txt".to_owned())]
    );
}

#[cfg(unix)]
#[test]
fn a_symlink_reads_as_its_target_and_is_not_followed() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let secret = dir.path().join("secret.txt");
    fs::write(&secret, "secret\n").unwrap();
    std::os::unix::fs::symlink(&secret, root.join("link")).unwrap();
    let content = GitWorkspace::new(root)
        .file_on_disk("link")
        .unwrap()
        .unwrap();
    assert_eq!(
        String::from_utf8(content).unwrap(),
        secret.to_string_lossy()
    );
}

#[cfg(unix)]
#[test]
fn a_directory_symlink_out_of_the_worktree_is_refused() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let outside = dir.path().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("f.txt"), "x").unwrap();
    std::os::unix::fs::symlink(&outside, root.join("out")).unwrap();
    let error = GitWorkspace::new(root)
        .file_on_disk("out/f.txt")
        .unwrap_err();
    assert!(
        format!("{error:#}").contains("outside the worktree"),
        "{error:#}"
    );
}

#[cfg(unix)]
#[test]
fn a_symlink_behind_a_directory_symlink_out_of_the_worktree_is_refused() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let outside = dir.path().join("outside");
    fs::create_dir(&outside).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", outside.join("link")).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("out")).unwrap();
    let error = GitWorkspace::new(root)
        .file_on_disk("out/link")
        .unwrap_err();
    assert!(
        format!("{error:#}").contains("outside the worktree"),
        "{error:#}"
    );
}

#[test]
fn a_path_git_would_cut_short_is_refused_instead_of_reading_another_file() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    let workspace = GitWorkspace::new(root);
    for path in ["a.txt\r", "a.txt\0b", "a.txt\nb"] {
        assert!(workspace.file_at(&base, path).is_err(), "{path:?}");
    }
}

#[test]
fn a_path_that_looks_like_an_option_is_only_a_path() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    let workspace = GitWorkspace::new(root);
    assert_eq!(workspace.file_at(&base, "--help").unwrap(), None);
    assert_eq!(workspace.file_on_disk("--help").unwrap(), None);
}

#[test]
fn a_commit_path_is_refused_when_the_disk_path_would_be() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    let workspace = GitWorkspace::new(root);
    for path in ["./a.txt", "../a.txt", "/a.txt", "a/./b", ""] {
        assert!(workspace.file_at(&base, path).is_err(), "{path:?}");
        assert!(workspace.file_on_disk(path).is_err(), "{path:?}");
    }
}

#[test]
fn finding_renames_leaves_the_reviewers_index_alone() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let base = read_head_commit(&root);
    // Same content, new modification time: a refreshing git would
    // rewrite the index to record it.
    let an_hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    let file = fs::File::options()
        .write(true)
        .open(root.join("a.txt"))
        .unwrap();
    file.set_modified(an_hour_ago).unwrap();
    let index_before = fs::read(root.join(".git/index")).unwrap();
    GitWorkspace::new(root.clone()).renames(&base).unwrap();
    assert_eq!(fs::read(root.join(".git/index")).unwrap(), index_before);
}

#[cfg(unix)]
#[test]
fn a_fetch_that_hangs_is_stopped_at_the_deadline() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let pid_file = dir.path().join("ssh.pid");
    let ssh = format!("echo $$ > '{}'; exec sleep 30 #", pid_file.display());
    git(
        &root,
        &[
            "remote",
            "add",
            "origin",
            "ssh://example.invalid/widgets.git",
        ],
    );
    git(&root, &["config", "core.sshCommand", &ssh]);
    let workspace = GitWorkspace::new(root).with_fetch_timeout(Duration::from_millis(500));
    let started = Instant::now();
    let error = workspace.merge_base(&"0".repeat(40)).unwrap_err();
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "{:?}",
        started.elapsed()
    );
    assert!(format!("{error:#}").contains("timed out"), "{error:#}");
    // The fetch really reached the stuck ssh. Whether the deadline also
    // stopped it depends on the engine having a terminal, which the
    // unattended module's tests cover; stop it here either way.
    let ssh_pid = wait_for_pid(&pid_file);
    stop_helper(&ssh_pid);
}

#[test]
fn opened_from_a_subdirectory_it_reads_paths_from_the_worktree_root() {
    let dir = repo();
    let root = dir.path().join("widgets");
    let subdirectory = root.join("src");
    fs::create_dir(&subdirectory).unwrap();
    fs::write(subdirectory.join("b.txt"), "b\n").unwrap();
    let workspace = GitWorkspace::open(&subdirectory).unwrap();
    assert_eq!(
        workspace.file_on_disk("a.txt").unwrap(),
        Some(b"a\n".to_vec())
    );
    assert_eq!(
        workspace.file_on_disk("src/b.txt").unwrap(),
        Some(b"b\n".to_vec())
    );
}

#[test]
fn opening_outside_a_checkout_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let error = GitWorkspace::open(dir.path()).unwrap_err();
    assert!(format!("{error:#}").contains("git checkout"), "{error:#}");
}

#[test]
fn climbing_paths_and_options_posing_as_commits_are_refused() {
    let dir = repo();
    let workspace = GitWorkspace::new(dir.path().join("widgets"));
    assert!(workspace.file_on_disk("../secret.txt").is_err());
    assert!(workspace.file_on_disk("/etc/passwd").is_err());
    assert!(workspace.file_at("--output=x", "a.txt").is_err());
    assert!(workspace.merge_base("--help").is_err());
    assert!(workspace.renames("HEAD").is_err());
}

#[test]
fn lists_committed_unstaged_and_untracked_changes_without_index_lock() {
    let temp_directory = tempfile::tempdir().unwrap();
    let root = temp_directory.path().join("widgets");
    fs::create_dir_all(root.join("src")).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    fs::write(root.join("src/lib.rs"), "pub fn a() {}\n").unwrap();
    fs::write(root.join("src/extra.rs"), "pub fn b() {}\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "base"]);
    let base_sha = read_head_commit(&root);
    fs::write(root.join("src/lib.rs"), "pub fn a() { let _ = 1; }\n").unwrap();
    git(&root, &["add", "src/lib.rs"]);
    git(&root, &["commit", "-q", "-m", "head"]);
    fs::write(root.join("src/extra.rs"), "pub fn b() { let _ = 2; }\n").unwrap();
    fs::write(root.join("src/new_file.rs"), "pub fn c() {}\n").unwrap();
    let changed = GitWorkspace::new(root.clone())
        .list_changed_files_since(&base_sha)
        .unwrap();
    assert_eq!(
        changed,
        vec!["src/extra.rs", "src/lib.rs", "src/new_file.rs"]
    );
    assert!(!root.join(".git/index.lock").exists());
}

#[test]
fn list_changed_files_since_rejects_invalid_and_unknown_commits() {
    let temp_directory = repo();
    let root = temp_directory.path().join("widgets");
    let base = read_head_commit(&root);
    let short_sha = &base[..7];
    let missing_sha = "0".repeat(40);
    let workspace = GitWorkspace::new(root);
    for invalid_ref in ["--all", "bad ref", "HEAD", short_sha, &missing_sha] {
        assert!(
            workspace.list_changed_files_since(invalid_ref).is_err(),
            "{invalid_ref:?}"
        );
    }
}

#[test]
fn list_changed_files_since_leaves_the_reviewers_index_alone() {
    let temp_directory = repo();
    let root = temp_directory.path().join("widgets");
    let base = read_head_commit(&root);
    // Same content, older modification time: a refreshing git command
    // would rewrite `.git/index` to update stat metadata.
    let an_hour_ago = std::time::SystemTime::now() - Duration::from_secs(3600);
    let file = fs::File::options()
        .write(true)
        .open(root.join("a.txt"))
        .unwrap();
    file.set_modified(an_hour_ago).unwrap();
    let index_before = fs::read(root.join(".git/index")).unwrap();
    GitWorkspace::new(root.clone())
        .list_changed_files_since(&base)
        .unwrap();
    assert_eq!(fs::read(root.join(".git/index")).unwrap(), index_before);
    assert!(!root.join(".git/index.lock").exists());
}

#[test]
fn lists_deleted_staged_and_renamed_changes_since_commit() {
    let temp_directory = repo();
    let root = temp_directory.path().join("widgets");
    fs::write(root.join("deleted.txt"), "gone\n").unwrap();
    fs::write(root.join("staged.txt"), "before\n").unwrap();
    fs::write(root.join("old_name.txt"), "move me\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "base"]);
    let base_sha = read_head_commit(&root);
    fs::remove_file(root.join("deleted.txt")).unwrap();
    fs::write(root.join("staged.txt"), "after\n").unwrap();
    git(&root, &["add", "staged.txt"]);
    git(&root, &["mv", "old_name.txt", "new_name.txt"]);
    let changed = GitWorkspace::new(root)
        .list_changed_files_since(&base_sha)
        .unwrap();
    assert_eq!(
        changed,
        vec!["deleted.txt", "new_name.txt", "old_name.txt", "staged.txt"]
    );
}
