//! Shared test helpers for `tui_schema` unit tests.

mod convert;
mod edge_cases;
mod prefill;
mod specs;

use cli_tui::{Answers, CommandSpec, StepSpec, get_active_steps_from_command};

pub(super) fn answers_from(pairs: &[(&str, &str)]) -> Answers {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

pub(super) fn find_spec(specs: &[CommandSpec], command_id: &str) -> CommandSpec {
    specs
        .iter()
        .find(|spec| spec.id == command_id)
        .cloned()
        .unwrap_or_else(|| panic!("missing spec for `{command_id}`"))
}

pub(super) fn find_step<'a>(
    specs: &'a [CommandSpec],
    command_id: &str,
    step_id: &str,
) -> &'a StepSpec {
    specs
        .iter()
        .find(|spec| spec.id == command_id)
        .unwrap_or_else(|| panic!("missing spec `{command_id}`"))
        .steps
        .iter()
        .find(|step| step.id == step_id)
        .unwrap_or_else(|| panic!("missing step `{step_id}` in `{command_id}`"))
}

pub(super) fn active_step_ids(spec: &CommandSpec, pairs: &[(&str, &str)]) -> Vec<String> {
    let answers = answers_from(pairs);
    get_active_steps_from_command(spec, &answers)
        .into_iter()
        .map(|step| step.id.clone())
        .collect()
}
