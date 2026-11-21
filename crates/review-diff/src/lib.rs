//! Diffs between two texts, and the read models frontends draw from them:
//! one file's overlay ([`create_file_diff_view_from_texts`]) and the stream
//! of every changed file ([`create_stream_view_from_inputs`]). Pure
//! functions: no IO and no frontend concepts.

mod lines;
mod overlay;
mod stream;
mod suggest;
mod text;
mod words;

pub use overlay::{create_file_diff_view_from_texts, create_file_diff_view_with_threads};
pub use stream::{CONTEXT_LINES, StreamInput, create_stream_view_from_inputs};
pub use suggest::create_suggestion_from_edit;
pub use text::FileText;
