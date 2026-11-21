//! The review domain: pull requests, changed files, threads, and the read
//! models every frontend draws. Pure data: no IO and no frontend concepts.

mod diff;
mod pr;
mod review;
mod thread;
mod view;

pub use diff::{
    AddedLine, FileDiffView, LineCell, LineChange, RemovedBlock, RemovedLine, StreamRow,
    StreamView, ViewMode, WordRange,
};
pub use pr::{ChangedFile, PullRequest, ViewedState};
pub use review::{
    MentionCandidate, Reaction, ReactionContent, ReviewEvent, SubmitDraft, SubmitPreview,
};
pub use thread::{Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState};
pub use view::{Event, FileRow, SessionView, SyncState, TreeRow};
