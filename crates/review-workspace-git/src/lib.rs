//! A pull request's worktree: checking it out, and reading its files and
//! history. Generic: it knows git and gh, and nothing about any editor.

mod checkout;
mod custom;
mod default_checkout;
mod fast_forward;
mod git_output;
mod local_ref;
mod process;
mod push;
mod repo;
mod status;
#[cfg(test)]
mod test_support;
mod unattended;
mod workspace;
mod worktree_path;

pub use checkout::{WorktreeCommand, checkout_pr, render_custom};
pub use custom::last_path_line;
pub use default_checkout::default_worktree_path;
pub use local_ref::{
    BranchProbe, LocalWorktreeInfo, inspect_local_worktree, read_current_branch,
    resolve_default_base_branch, validate_git_ref,
};
pub use repo::main_repo_root;
pub use workspace::{FETCH_TIMEOUT, GitWorkspace};
