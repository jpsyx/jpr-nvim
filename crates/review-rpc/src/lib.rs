//! JSON-RPC access to a review session for out-of-process frontends.
//! Frontend-neutral: any client that speaks docs/protocol.md can drive it.

mod params;
pub mod protocol;
mod server;
#[cfg(unix)]
mod socket;

pub use protocol::{PROTOCOL_VERSION, Request, RpcError};
pub use server::{
    PollStep, ServeOptions, get_poll_step_from_elapsed, get_wake_interval_from_intervals,
    get_wake_interval_from_poll_and_retry, handle, serve,
};
