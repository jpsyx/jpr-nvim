//! jpr-review: the composition root. It wires the generic review crates
//! (`review-*`) to real adapters and exposes them as commands. No review rule
//! lives here; see docs/architecture.md.

pub mod cli;
pub mod commands;
pub mod prompt;
pub mod theme;
pub mod tui_schema;

/// The product name shown to people.
pub const APP_NAME: &str = "jpr-review";

/// The directory under the XDG state home where review state lives.
pub const STATE_APP: &str = "jpr";
