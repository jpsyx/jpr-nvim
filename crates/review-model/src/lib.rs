//! The review domain: pull requests, changed files, threads, and the read
//! models every frontend draws. Pure data: no IO and no frontend concepts.

mod pr;
mod thread;
mod view;

pub use pr::{ChangedFile, PullRequest, ViewedState};
pub use thread::{Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState};
pub use view::{Event, FileRow, SessionView, SyncState};
