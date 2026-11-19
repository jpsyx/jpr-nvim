//! JSON-RPC access to a review session for out-of-process frontends.
//! Frontend-neutral: any client that speaks docs/protocol.md can drive it.

pub mod protocol;
mod server;

pub use protocol::{PROTOCOL_VERSION, Request, RpcError};
pub use server::{ServeOptions, handle, serve};
