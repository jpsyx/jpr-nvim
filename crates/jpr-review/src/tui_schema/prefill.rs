//! Prefilling [`Answers`] from partially specified CLI [`Command`] flags.

use std::path::Path;

use cli_tui::Answers;

use super::steps::non_empty_env;
use crate::cli::Command;

/// Returns `(command_id, prefilled_answers)` when `command` is missing required
/// inputs that should be gathered interactively, or `None` when it can run as-is.
#[must_use]
pub fn initial_answers_for_missing_inputs(command: &Command) -> Option<(&'static str, Answers)> {
    let env_socket = non_empty_env("JPR_SOCKET");
    let env_pr = non_empty_env("JPR_PR");
    let env = TargetEnv {
        socket: env_socket.as_deref(),
        pr: env_pr.as_deref(),
    };
    initial_answers_for_missing_inputs_with_env(command, env)
}

#[derive(Clone, Copy)]
pub(super) struct TargetEnv<'a> {
    pub(super) socket: Option<&'a str>,
    pub(super) pr: Option<&'a str>,
}

#[derive(Clone, Copy)]
struct TargetFlags<'a> {
    socket: Option<&'a Path>,
    pr: Option<u64>,
    repo: Option<&'a str>,
}

pub(super) fn initial_answers_for_missing_inputs_with_env(
    command: &Command,
    env: TargetEnv<'_>,
) -> Option<(&'static str, Answers)> {
    match command {
        Command::Checkout {
            pr,
            repo,
            worktree_cmd,
        } => initial_checkout_answers(*pr, repo.as_deref(), worktree_cmd.as_deref()),
        Command::StatePath { pr, repo } => initial_state_path_answers(*pr, repo.as_deref()),
        Command::Threads {
            pr,
            repo,
            socket,
            is_local_only,
        } => initial_threads_answers(
            target_flags(socket.as_deref(), *pr, repo.as_deref()),
            *is_local_only,
            env,
        ),
        Command::Reply {
            thread_id,
            body,
            pr,
            repo,
            socket,
        } => initial_reply_answers(
            thread_id.as_deref(),
            body.as_deref(),
            target_flags(socket.as_deref(), *pr, repo.as_deref()),
            env,
        ),
        Command::PrepassWrite {
            input,
            pr,
            repo,
            socket,
        } => initial_prepass_write_answers(
            input.as_deref(),
            target_flags(socket.as_deref(), *pr, repo.as_deref()),
            env,
        ),
        Command::Prs { .. } | Command::Serve { .. } | Command::Guide => None,
    }
}

const fn target_flags<'a>(
    socket: Option<&'a Path>,
    pr: Option<u64>,
    repo: Option<&'a str>,
) -> TargetFlags<'a> {
    TargetFlags { socket, pr, repo }
}

fn initial_checkout_answers(
    pr: Option<u64>,
    repo: Option<&str>,
    worktree_cmd: Option<&str>,
) -> Option<(&'static str, Answers)> {
    if pr.is_some() {
        return None;
    }
    let mut answers = Answers::new();
    if let Some(repo_value) = repo {
        answers.insert("custom_repo".to_owned(), "true".to_owned());
        answers.insert("repo".to_owned(), repo_value.to_owned());
    } else {
        answers.insert("custom_repo".to_owned(), "false".to_owned());
    }
    if let Some(command_value) = worktree_cmd {
        answers.insert("custom_worktree".to_owned(), "true".to_owned());
        answers.insert("worktree_cmd".to_owned(), command_value.to_owned());
    } else {
        answers.insert("custom_worktree".to_owned(), "false".to_owned());
    }
    Some(("checkout", answers))
}

fn initial_state_path_answers(
    pr: Option<u64>,
    repo: Option<&str>,
) -> Option<(&'static str, Answers)> {
    if pr.is_some() && repo.is_some() {
        return None;
    }
    let mut answers = Answers::new();
    if let Some(number) = pr {
        answers.insert("pr".to_owned(), number.to_string());
    }
    if let Some(repo_value) = repo {
        answers.insert("repo".to_owned(), repo_value.to_owned());
    }
    Some(("state-path", answers))
}

fn initial_threads_answers(
    flags: TargetFlags<'_>,
    is_local_only: bool,
    env: TargetEnv<'_>,
) -> Option<(&'static str, Answers)> {
    if has_resolved_target(flags, env) {
        return None;
    }
    let mut answers = Answers::new();
    prefill_target_answers(&mut answers, flags, env);
    answers.insert(
        "is_local_only".to_owned(),
        if is_local_only { "true" } else { "false" }.to_owned(),
    );
    Some(("threads", answers))
}

fn initial_reply_answers(
    thread_id: Option<&str>,
    body: Option<&str>,
    flags: TargetFlags<'_>,
    env: TargetEnv<'_>,
) -> Option<(&'static str, Answers)> {
    if thread_id.is_some() && body.is_some() && has_resolved_target(flags, env) {
        return None;
    }
    let mut answers = Answers::new();
    prefill_target_answers(&mut answers, flags, env);
    if let Some(id_value) = thread_id {
        answers.insert("thread_id".to_owned(), id_value.to_owned());
    }
    if let Some(body_value) = body {
        answers.insert("body".to_owned(), body_value.to_owned());
    }
    Some(("reply", answers))
}

fn initial_prepass_write_answers(
    input: Option<&Path>,
    flags: TargetFlags<'_>,
    env: TargetEnv<'_>,
) -> Option<(&'static str, Answers)> {
    if has_resolved_target(flags, env) {
        return None;
    }
    let mut answers = Answers::new();
    prefill_target_answers(&mut answers, flags, env);
    if let Some(input_path) = input {
        answers.insert("input_mode".to_owned(), "file".to_owned());
        answers.insert(
            "input".to_owned(),
            input_path.to_string_lossy().into_owned(),
        );
    } else {
        answers.insert("input_mode".to_owned(), "stdin".to_owned());
    }
    Some(("prepass-write", answers))
}

const fn has_resolved_target(flags: TargetFlags<'_>, env: TargetEnv<'_>) -> bool {
    if flags.socket.is_some() || flags.pr.is_some() {
        return true;
    }
    if flags.repo.is_some() {
        return false;
    }
    env.socket.is_some() || env.pr.is_some()
}

fn prefill_target_answers(answers: &mut Answers, flags: TargetFlags<'_>, env: TargetEnv<'_>) {
    if let Some(socket_path) = flags.socket {
        answers.insert("target_mode".to_owned(), "socket".to_owned());
        answers.insert(
            "socket".to_owned(),
            socket_path.to_string_lossy().into_owned(),
        );
    } else if let Some(pr_number) = flags.pr {
        answers.insert("target_mode".to_owned(), "pr".to_owned());
        answers.insert("pr".to_owned(), pr_number.to_string());
        answers.insert("repo".to_owned(), flags.repo.unwrap_or_default().to_owned());
    } else if let Some(repo_value) = flags.repo {
        answers.insert("target_mode".to_owned(), "pr".to_owned());
        answers.insert("repo".to_owned(), repo_value.to_owned());
    } else if let Some(socket_value) = env.socket {
        answers.insert("target_mode".to_owned(), "socket".to_owned());
        answers.insert("socket".to_owned(), socket_value.to_owned());
    } else if let Some(pr_value) = env.pr {
        answers.insert("target_mode".to_owned(), "pr".to_owned());
        answers.insert("pr".to_owned(), pr_value.to_owned());
        answers.insert("repo".to_owned(), String::new());
    }
}
