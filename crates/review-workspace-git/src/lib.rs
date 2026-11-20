//! A pull request's worktree: checking it out, and reading its files and
//! history. Generic: it knows git and gh, and nothing about any editor.

mod checkout;
mod custom;
mod default_checkout;
mod git_output;
mod process;
mod repo;
#[cfg(test)]
mod test_support;
mod unattended;
mod workspace;
mod worktree_path;

pub use checkout::{WorktreeCommand, checkout_pr, render_custom};
pub use custom::last_path_line;
pub use default_checkout::default_worktree_path;
pub use repo::main_repo_root;
pub use workspace::{FETCH_TIMEOUT, GitWorkspace};
