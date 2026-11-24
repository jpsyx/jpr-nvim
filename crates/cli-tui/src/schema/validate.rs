//! Validation rules for [`CommandSpec`] and [`StepSpec`] definitions.

use std::collections::BTreeSet;

use super::{CommandSpec, StepKind, StepSpec};

/// Validates a slice of command specifications for completeness and uniqueness.
pub fn validate_command_specs(commands: &[CommandSpec]) -> Result<(), String> {
    let mut seen_command_ids = BTreeSet::new();
    for command in commands {
        validate_single_command(command)?;
        if !seen_command_ids.insert(command.id.as_str()) {
            return Err(format!("duplicate command id `{}`", command.id));
        }
    }
    Ok(())
}

fn validate_single_command(command: &CommandSpec) -> Result<(), String> {
    if command.id.trim().is_empty() {
        return Err("command id must not be empty".to_owned());
    }
    if command.label.trim().is_empty() {
        return Err(format!(
            "command `{}` must have a non-empty label",
            command.id
        ));
    }
    if command.help.trim().is_empty() {
        return Err(format!(
            "command `{}` must have non-empty help text",
            command.id
        ));
    }

    let mut seen_step_ids = BTreeSet::new();
    for step in &command.steps {
        validate_single_step(&command.id, step)?;
        if !seen_step_ids.insert(step.id.as_str()) {
            return Err(format!(
                "command `{}` has duplicate step id `{}`",
                command.id, step.id
            ));
        }
    }
    Ok(())
}

fn validate_single_step(command_id: &str, step: &StepSpec) -> Result<(), String> {
    if step.id.trim().is_empty() {
        return Err(format!(
            "command `{command_id}` has a step with an empty id"
        ));
    }
    if step.label.trim().is_empty() {
        return Err(format!(
            "step `{}` in command `{command_id}` must have a non-empty label",
            step.id
        ));
    }
    if step.help.trim().is_empty() {
        return Err(format!(
            "step `{}` in command `{command_id}` must have non-empty help text",
            step.id
        ));
    }
    validate_step_kind(command_id, step)
}

fn validate_step_kind(command_id: &str, step: &StepSpec) -> Result<(), String> {
    match &step.kind {
        StepKind::Select(options) => {
            if options.is_empty() {
                return Err(format!(
                    "select step `{}` in command `{command_id}` must have at least one option",
                    step.id
                ));
            }
            for option in options {
                if option.value.trim().is_empty() || option.label.trim().is_empty() {
                    return Err(format!(
                        "select step `{}` in command `{command_id}` has an option with an empty value or label",
                        step.id
                    ));
                }
            }
            Ok(())
        }
        StepKind::Toggle {
            yes_label,
            no_label,
            ..
        } => {
            if yes_label.trim().is_empty() || no_label.trim().is_empty() {
                return Err(format!(
                    "toggle step `{}` in command `{command_id}` must have non-empty yes and no labels",
                    step.id
                ));
            }
            Ok(())
        }
        StepKind::DynamicSelect(_) | StepKind::Text { .. } => Ok(()),
    }
}
