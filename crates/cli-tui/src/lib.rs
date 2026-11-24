//! Reusable declarative command-schema-to-TUI palette and stepper library.
//!
//! Callers describe their CLI surface as [`CommandSpec`] values with
//! discriminant-first [`StepSpec`] pipelines. Pure state transitions live in
//! [`state`], pure frame rendering lives in [`render`], and the thin terminal
//! shell that manages raw mode and stderr redraws lives in [`runner`].

pub mod render;
pub mod runner;
pub mod schema;
pub mod state;

pub use render::{render_palette, render_wizard};
pub use runner::{
    CommandOutcome, PaletteOutcome, is_interactive_terminal, run_command, run_palette,
};
pub use schema::{
    Answers, CommandSpec, DefaultProvider, OptionLoader, SelectOption, StepKind, StepSpec,
    ValueValidator, WhenPredicate, get_active_steps_from_command, prune_inactive_answers,
    validate_command_specs,
};
pub use state::{KeyAction, PaletteAction, PaletteState, WizardOutcome, WizardState};
