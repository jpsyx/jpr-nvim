//! Running git, gh and custom commands as child processes: their stdout is
//! the answer, and a failure carries their stderr.

use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::thread;

use anyhow::{Context, Result, bail};

/// Variables that point git at another repository, index, object store or
/// work tree than the directory it runs in. `git commit` sets some of them
/// for the editor it starts, and the engine would inherit them from Neovim.
/// Each is one `git rev-parse --local-env-vars` lists.
pub const GIT_REPOSITORY_VARIABLES: [&str; 8] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_SHALLOW_FILE",
    "GIT_PREFIX",
];

/// Runs `program` in `dir` and returns its stdout as text, or fails with its
/// stderr.
pub fn run(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    run_bytes(program, args, dir).map(|stdout| String::from_utf8_lossy(&stdout).into_owned())
}

/// Runs `program` in `dir` and returns its raw stdout, or fails with its stderr.
pub fn run_bytes(program: &str, args: &[&str], dir: &Path) -> Result<Vec<u8>> {
    let mut command = create_command(program, args, dir);
    run_command_bytes(&mut command, program, args)
}

/// Runs `program` in `dir` with `GIT_OPTIONAL_LOCKS=0` and returns its raw
/// stdout, or fails with its stderr.
pub fn run_bytes_unlocked(program: &str, args: &[&str], dir: &Path) -> Result<Vec<u8>> {
    let mut command = create_command(program, args, dir);
    command.env("GIT_OPTIONAL_LOCKS", "0");
    run_command_bytes(&mut command, program, args)
}

fn run_command_bytes(command: &mut Command, program: &str, args: &[&str]) -> Result<Vec<u8>> {
    let output = command
        .output()
        .with_context(|| format!("running {program}"))?;
    get_stdout_from_output(program, args, output)
}

/// Runs `program` in `dir` with `input` on its stdin and returns its raw
/// stdout, or fails with its stderr.
pub fn run_with_input(program: &str, args: &[&str], dir: &Path, input: &[u8]) -> Result<Vec<u8>> {
    let mut child = create_command(program, args, dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {program}"))?;
    let stdin = child.stdin.take();
    // The input is written from its own thread while this one reads the
    // answer: a program that answers before it has read all of its input
    // would otherwise fill both pipes and wait forever. The writer drops
    // stdin when it is done, which closes it so the program ends.
    let (written, output) = thread::scope(|scope| {
        let writer = scope.spawn(move || stdin.map_or(Ok(()), |mut stdin| stdin.write_all(input)));
        let output = child.wait_with_output();
        let written = writer
            .join()
            .unwrap_or_else(|_| Err(io::Error::other("the writing thread panicked")));
        (written, output)
    });
    // A program that exits early has still been waited on, and its own
    // error, which says why, wins over the broken pipe it left behind.
    let output = output.with_context(|| format!("running {program}"))?;
    let stdout = get_stdout_from_output(program, args, output)?;
    written.with_context(|| format!("writing to {program}"))?;
    Ok(stdout)
}

/// `program` with `args`, to run in `dir`, with git's repository variables
/// cleared so git works on the repository at `dir` and nowhere else.
pub fn create_command(program: &str, args: &[&str], dir: &Path) -> Command {
    let mut command = Command::new(program);
    command.args(args).current_dir(dir);
    for variable in GIT_REPOSITORY_VARIABLES {
        command.env_remove(variable);
    }
    command
}

/// `output`'s stdout when the program succeeded, or an error carrying its
/// stderr, or its command line and exit status when stderr is empty.
pub fn get_stdout_from_output(program: &str, args: &[&str], output: Output) -> Result<Vec<u8>> {
    if output.status.success() {
        return Ok(output.stdout);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.trim().is_empty() {
        bail!("{program} {} failed with {}", args.join(" "), output.status);
    }
    bail!("{program} failed: {}", stderr.trim())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::repo;

    #[test]
    fn a_program_that_fails_while_reading_input_reports_its_own_error() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing").to_string_lossy().into_owned();
        // More than a pipe holds, so writing fails once git has exited.
        let input = vec![b'x'; 1024 * 1024];
        let args = ["-C", missing.as_str(), "cat-file", "--batch"];
        let error = run_with_input("git", &args, dir.path(), &input).unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("cannot change to"), "{message}");
        assert!(!message.contains("Broken pipe"), "{message}");
    }

    #[test]
    fn a_silent_failure_names_the_command_and_its_exit_status() {
        let dir = tempfile::tempdir().unwrap();
        let error = run("sh", &["-c", "exit 3"], dir.path()).unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("sh -c exit 3"), "{message}");
        assert!(message.contains("exit status: 3"), "{message}");
    }

    #[test]
    fn a_program_that_answers_before_reading_all_its_input_does_not_hang() {
        let dir = tempfile::tempdir().unwrap();
        let input = vec![b'x'; 1024 * 1024];
        assert_eq!(
            run_with_input("cat", &[], dir.path(), &input).unwrap(),
            input
        );
    }

    #[test]
    fn git_ignores_the_repository_the_engine_was_started_from() {
        // `git commit` starts its editor with these set, and Neovim passes
        // them on to the engine. Re-running one test in a child process is
        // the only way to give it such an environment.
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "process::tests::reads_the_worktree_it_is_given"])
            .args(["--ignored", "--quiet"])
            .env("GIT_DIR", "bogus-git-dir")
            .env("GIT_INDEX_FILE", "bogus-index")
            .env("GIT_WORK_TREE", "bogus-work-tree")
            .output()
            .unwrap();
        let report = String::from_utf8_lossy(&output.stdout);
        assert!(output.status.success(), "{report}");
        // Exactly one test ran: a renamed target would pass by running none.
        assert!(report.contains(" 1 passed;"), "{report}");
    }

    #[test]
    #[ignore = "run by git_ignores_the_repository_the_engine_was_started_from"]
    fn reads_the_worktree_it_is_given() {
        let dir = repo();
        let listed = run("git", &["ls-files"], &dir.path().join("widgets")).unwrap();
        assert_eq!(listed, "a.txt\n");
    }
}
