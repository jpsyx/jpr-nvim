//! The command-line surface.
//!
//! The Neovim plugin drives these commands with flags. `checkout` and
//! `state-path` ask for an omitted value on a terminal; `serve` takes only
//! flags because its stdin is the protocol.

use std::path::PathBuf;

use clap::{Parser, Subcommand};

/// jpr-review: the review engine behind the jpr Neovim plugin.
#[derive(Debug, Clone, Parser)]
#[command(version, propagate_version = true)]
pub struct Cli {
    /// The command to run.
    #[command(subcommand)]
    pub command: Option<Command>,
}

/// The things this tool can be asked to do.
#[derive(Debug, Clone, PartialEq, Eq, Subcommand)]
pub enum Command {
    /// Check a pull request out into a worktree and print where, as JSON.
    Checkout {
        /// The pull request number. Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository the pull request must belong to, as owner/name. Left
        /// out, it is whichever repository the current directory resolves to.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// A shell command that creates the worktree and prints its path; `{n}` is the number.
        #[arg(long, value_name = "COMMAND", env = "JPR_WORKTREE_CMD")]
        worktree_cmd: Option<String>,
    },
    /// Inspect the current worktree for local review or active PR auto-detection.
    Local {
        /// Base git ref to diff against (bypasses active PR auto-detection).
        #[arg(long, value_name = "REF")]
        base: Option<String>,
        /// Explicit GitHub repository (`owner/name`) for PR lookup.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// Stay in local mode even if an open pull request exists for this branch.
        #[arg(long)]
        no_pr: bool,
    },
    /// Print the agent review and reply contract to stdout.
    Guide,
    /// Print review threads as JSON from a live daemon or saved state.
    Threads {
        /// The pull request number (or $JPR_PR). Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository, as owner/name. Left out, inferred from git or asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// Unix domain socket path of a running `jpr-review serve` daemon (or $JPR_SOCKET).
        #[arg(long, value_name = "PATH")]
        socket: Option<PathBuf>,
        /// Print only local (`origin == "local"`) threads.
        #[arg(long = "local")]
        is_local_only: bool,
    },
    /// Reply to a local review thread as the coding agent.
    Reply {
        /// Local thread id (e.g. loc-1). Left out on a terminal, you are asked.
        thread_id: Option<String>,
        /// Reply message body. Left out on a terminal, you are asked.
        #[arg(long)]
        body: Option<String>,
        /// The pull request number (or $JPR_PR). Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository, as owner/name. Left out, inferred from git or asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// Unix domain socket path of a running `jpr-review serve` daemon (or $JPR_SOCKET).
        #[arg(long, value_name = "PATH")]
        socket: Option<PathBuf>,
    },
    /// Write pre-pass review findings as answered local threads from JSON.
    PrepassWrite {
        /// JSON file of pre-pass findings (reads stdin when omitted).
        #[arg(long, value_name = "FILE")]
        input: Option<PathBuf>,
        /// The pull request number (or $JPR_PR). Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository, as owner/name. Left out, inferred from git or asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// Unix domain socket path of a running `jpr-review serve` daemon (or $JPR_SOCKET).
        #[arg(long, value_name = "PATH")]
        socket: Option<PathBuf>,
    },
    /// List open pull requests in the repository as a JSON array.
    Prs {
        /// The repository, as owner/name. Left out, inferred from the current directory.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
        /// Maximum number of open pull requests to return.
        #[arg(long, default_value_t = 50, value_parser = clap::value_parser!(u32).range(1..))]
        limit: u32,
    },
    /// List the authenticated GitHub user profile and organizations as JSON.
    Owners,
    /// List GitHub repositories for an account or organization as JSON.
    Repos {
        /// Account or organization login. Left out, lists your personal repositories.
        #[arg(long, value_name = "LOGIN")]
        owner: Option<String>,
        /// Maximum number of repositories to return.
        #[arg(long, default_value_t = 100, value_parser = clap::value_parser!(u32).range(1..))]
        limit: u32,
    },
    /// Serve a review session as JSON-RPC on stdin and stdout.
    Serve {
        /// The pull request number (mutually exclusive with --local).
        #[arg(
            long,
            conflicts_with = "is_local",
            required_unless_present = "is_local"
        )]
        pr: Option<u64>,
        /// Serve an unlinked local worktree review session.
        #[arg(long = "local", action = clap::ArgAction::SetTrue, conflicts_with = "pr")]
        is_local: bool,
        /// Base git ref to diff against when serving in --local mode.
        #[arg(long, value_name = "REF", requires = "is_local", conflicts_with = "pr")]
        base: Option<String>,
        /// The repository, as owner/name (required with --pr; optional with --local).
        #[arg(long, value_name = "OWNER/NAME", required_unless_present = "is_local")]
        repo: Option<String>,
        /// Seconds between background syncs; 0 syncs only on request.
        #[arg(long, value_name = "SECONDS", default_value_t = 60)]
        poll: u64,
    },
    /// Print the directory that holds a review session's state.
    StatePath {
        /// The pull request number. Left out on a terminal, you are asked.
        #[arg(long, conflicts_with = "is_local")]
        pr: Option<u64>,
        /// Print the local review state directory for the current worktree and branch.
        #[arg(long = "local", conflicts_with = "pr")]
        is_local: bool,
        /// The repository, as owner/name. Left out on a terminal, you are asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
    },
}

#[cfg(test)]
mod tests;
