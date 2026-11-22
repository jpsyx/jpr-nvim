//! The review engine. Frontends talk only to the `ReviewSession` facade; the
//! outside world is reached only through the traits in [`ports`]. See
//! docs/architecture.md.

pub mod agent;
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

pub use guide::build_agent_guide;
pub use presenter::session_view;
pub use session::ReviewSession;
