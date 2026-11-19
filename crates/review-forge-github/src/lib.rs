//! The GitHub forge: `gh pr view` for the pull request and `gh api graphql`
//! for threads, files and viewed state. Adapted from dif's `github/` module.

mod gh;
pub mod graphql;
pub mod pr;

pub use gh::{GH_TIMEOUT, Gh};
