//! The review engine. Frontends talk only to the `ReviewSession` facade; the
//! outside world is reached only through the traits in [`ports`]. See
//! docs/architecture.md.

pub mod agent;
pub mod auth;
mod comments;
pub mod guide;
pub mod ports;
mod presenter;
pub mod reanchor;
mod session;
mod tree;
mod viewed;

#[cfg(any(test, feature = "fakes"))]
pub mod contract;
#[cfg(any(test, feature = "fakes"))]
pub mod fakes;

pub use auth::{AUTH_EXIT_CODE, ForgeAuthError, is_auth_error, is_gh_auth_failure_text};
pub use guide::build_agent_guide;
pub use presenter::session_view;
pub use session::{PathRename, ReviewSession};
pub use viewed::{collect_directory_toggle_paths, is_path_in_directory};
