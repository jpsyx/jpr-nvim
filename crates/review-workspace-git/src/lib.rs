//! Checking a pull request out into its own worktree. Generic: it knows git
//! and `gh`, and nothing about any editor.

mod checkout;
mod custom;
mod default_checkout;
mod process;
mod repo;
#[cfg(test)]
mod test_support;

pub use checkout::{WorktreeCommand, checkout_pr, render_custom};
pub use custom::last_path_line;
pub use default_checkout::default_worktree_path;
pub use repo::main_repo_root;
