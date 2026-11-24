//! Active step resolution and stale answer pruning for [`CommandSpec`].

use std::collections::BTreeSet;

use super::{Answers, CommandSpec, StepSpec};

/// Returns the ordered subset of steps in `command` whose `when` predicate is
/// `None` or evaluates to `true` for `answers`.
#[must_use]
pub fn get_active_steps_from_command<'a>(
    command: &'a CommandSpec,
    answers: &Answers,
) -> Vec<&'a StepSpec> {
    command
        .steps
        .iter()
        .filter(|step| {
            step.when
                .as_ref()
                .is_none_or(|predicate| predicate(answers))
        })
        .collect()
}

/// Returns a copy of `answers` retaining only keys belonging to active steps in
/// `command`, including transitively gated `when` branches, without mutating `answers`.
///
/// Used when finalizing or resetting wizard answers.
#[must_use]
pub fn prune_inactive_answers(command: &CommandSpec, answers: &Answers) -> Answers {
    let mut pruned = answers.clone();
    // Iterate to a fixed point so dropping an inactive intermediate step also
    // prunes downstream steps whose `when` predicate depended on it.
    loop {
        let active_step_ids: BTreeSet<&str> = get_active_steps_from_command(command, &pruned)
            .into_iter()
            .map(|step| step.id.as_str())
            .collect();
        let previous_len = pruned.len();
        pruned.retain(|step_id, _| active_step_ids.contains(step_id.as_str()));
        if pruned.len() == previous_len {
            return pruned;
        }
    }
}
