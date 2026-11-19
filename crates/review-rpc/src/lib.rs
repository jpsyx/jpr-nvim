//! JSON-RPC access to a review session for out-of-process frontends.
//! Frontend-neutral: any client that speaks docs/protocol.md can drive it.

pub mod protocol;

pub use protocol::{PROTOCOL_VERSION, Request, RpcError};
