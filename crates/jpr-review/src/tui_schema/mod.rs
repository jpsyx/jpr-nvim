//! Declarative `cli-tui` command specifications and answer conversions for `jpr-review`.

mod convert;
mod prefill;
mod specs;
mod steps;

#[cfg(test)]
mod tests;

pub use convert::{answers_to_command, apply_answers_to_command};
pub use prefill::initial_answers_for_missing_inputs;
pub use specs::build_command_specs;
pub use steps::pull_request_summary_to_option;
