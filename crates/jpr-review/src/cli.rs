//! The command-line surface.
//!
//! The Neovim plugin drives these commands with flags. `checkout` and
//! `state-path` ask for an omitted value on a terminal; `serve` takes only
//! flags because its stdin is the protocol.

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
        /// A shell command that creates the worktree and prints its path; `{n}` is the number.
        #[arg(long, value_name = "COMMAND", env = "JPR_WORKTREE_CMD")]
        worktree_cmd: Option<String>,
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
                worktree_cmd: Some("wt pr {n}".into())
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
}
