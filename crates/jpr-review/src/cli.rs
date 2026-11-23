//! The command-line surface.
//!
//! The Neovim plugin drives these commands with flags. `checkout` and
//! `state-path` ask for an omitted value on a terminal; `serve` takes only
//! flags because its stdin is the protocol.

use std::path::PathBuf;

use clap::{Parser, Subcommand};

/// jpr-review: the review engine behind the jpr Neovim plugin.
#[derive(Debug, Clone, Parser)]
#[command(version, propagate_version = true, arg_required_else_help = true)]
pub struct Cli {
    /// The command to run.
    #[command(subcommand)]
    pub command: Command,
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
    /// Serve a pull request's review session as JSON-RPC on stdin and stdout.
    Serve {
        /// The pull request number.
        #[arg(long)]
        pr: u64,
        /// The repository, as owner/name.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: String,
        /// Seconds between background syncs; 0 syncs only on request.
        #[arg(long, value_name = "SECONDS", default_value_t = 60)]
        poll: u64,
    },
    /// Print the directory that holds a pull request's review state.
    StatePath {
        /// The pull request number. Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository, as owner/name. Left out on a terminal, you are asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn the_surface_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn a_bare_invocation_shows_the_help() {
        let error = Cli::try_parse_from(["jpr-review"]).expect_err("a subcommand is required");
        assert_eq!(
            error.kind(),
            clap::error::ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
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
            Command::Checkout {
                pr: Some(7),
                repo: None,
                worktree_cmd: Some("wt pr {n}".into())
            }
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
            Command::Checkout {
                pr: Some(12),
                repo: Some("octo/gadgets".into()),
                worktree_cmd: None
            }
        );
    }

    #[test]
    fn serve_polls_every_minute_by_default() {
        let cli =
            Cli::try_parse_from(["jpr-review", "serve", "--pr", "7", "--repo", "octo/widgets"])
                .unwrap();
        assert_eq!(
            cli.command,
            Command::Serve {
                pr: 7,
                repo: "octo/widgets".into(),
                poll: 60
            }
        );
    }

    #[test]
    fn serve_requires_the_repository() {
        assert!(Cli::try_parse_from(["jpr-review", "serve", "--pr", "7"]).is_err());
    }

    #[test]
    fn guide_parses_without_arguments() {
        let cli = Cli::try_parse_from(["jpr-review", "guide"]).unwrap();
        assert_eq!(cli.command, Command::Guide);
    }

    #[test]
    fn threads_parses_pr_repo_and_local_flag() {
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
            Command::Threads {
                pr: Some(7),
                repo: Some("octo/widgets".into()),
                socket: None,
                is_local_only: true,
            }
        );
    }

    #[test]
    fn reply_parses_positional_thread_id_and_body() {
        let cli =
            Cli::try_parse_from(["jpr-review", "reply", "loc-1", "--body", "Done. (abc1234)"])
                .unwrap();
        assert_eq!(
            cli.command,
            Command::Reply {
                thread_id: Some("loc-1".into()),
                body: Some("Done. (abc1234)".into()),
                pr: None,
                repo: None,
                socket: None,
            }
        );
    }

    #[test]
    fn prepass_write_parses_input_file_flag() {
        let cli = Cli::try_parse_from(["jpr-review", "prepass-write", "--input", "findings.json"])
            .unwrap();
        assert_eq!(
            cli.command,
            Command::PrepassWrite {
                input: Some(std::path::PathBuf::from("findings.json")),
                pr: None,
                repo: None,
                socket: None,
            }
        );
    }

    #[test]
    fn prs_uses_default_limit_and_optional_repo() {
        let bare = Cli::try_parse_from(["jpr-review", "prs"]).unwrap();
        assert_eq!(
            bare.command,
            Command::Prs {
                repo: None,
                limit: 50,
            }
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
            Command::Prs {
                repo: Some("octo/widgets".into()),
                limit: 15,
            }
        );
        assert!(Cli::try_parse_from(["jpr-review", "prs", "--limit", "0"]).is_err());
    }
}
