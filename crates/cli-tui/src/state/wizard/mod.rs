//! Pure state machine driving a single command wizard step by step.

mod input;

#[cfg(test)]
mod tests;

use std::collections::BTreeSet;

use crate::schema::{
    Answers, CommandSpec, SelectOption, StepKind, StepSpec, get_active_steps_from_command,
    prune_inactive_answers,
};

use super::KeyAction;

/// Outcome of handling one key action in [`WizardState`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WizardOutcome {
    /// Stay in the wizard and redraw.
    Continue,
    /// Return to the command palette from step 1.
    BackToPalette,
    /// All active steps are complete with pruned answers.
    Completed(Answers),
    /// The user cancelled the wizard.
    Cancelled,
}

/// Pure state machine driving a single [`CommandSpec`] step by step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WizardState {
    pub(super) answers: Answers,
    pub(super) prefilled_keys: BTreeSet<String>,
    pub(super) step_index: usize,
    pub(super) can_return_to_palette: bool,
    pub(super) selected_option_index: usize,
    pub(super) loaded_options: Vec<SelectOption>,
    pub(super) input_text: String,
    pub(super) cursor_char_index: usize,
    pub(super) validation_error: Option<String>,
}

impl WizardState {
    /// Creates a wizard starting at the first unanswered active step (or step 0
    /// when all active steps are already answered or the command has no active steps).
    #[must_use]
    pub fn new(
        command: &CommandSpec,
        initial_answers: Answers,
        can_return_to_palette: bool,
    ) -> Self {
        let active_steps = get_active_steps_from_command(command, &initial_answers);
        let starting_step_index =
            first_unanswered_step_index(&active_steps, &initial_answers).unwrap_or(0);
        let prefilled_keys = initial_answers.keys().cloned().collect();
        let mut state = Self {
            answers: initial_answers,
            prefilled_keys,
            step_index: starting_step_index,
            can_return_to_palette,
            selected_option_index: 0,
            loaded_options: Vec::new(),
            input_text: String::new(),
            cursor_char_index: 0,
            validation_error: None,
        };
        state.load_current_step(command);
        state
    }

    /// Returns pruned answers immediately when `command` has zero active steps.
    #[must_use]
    pub fn immediate_completion(&self, command: &CommandSpec) -> Option<Answers> {
        if get_active_steps_from_command(command, &self.answers).is_empty() {
            Some(prune_inactive_answers(command, &self.answers))
        } else {
            None
        }
    }

    /// Applies one key action to the current wizard step.
    pub fn handle_key(&mut self, command: &CommandSpec, action: KeyAction) -> WizardOutcome {
        if matches!(action, KeyAction::Cancel) {
            return WizardOutcome::Cancelled;
        }
        let active_steps = get_active_steps_from_command(command, &self.answers);
        let Some(current_step) = active_steps.get(self.step_index).copied() else {
            return WizardOutcome::Completed(prune_inactive_answers(command, &self.answers));
        };
        match &current_step.kind {
            StepKind::Text { .. } => self.handle_text_key(command, current_step, action),
            StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
                self.handle_menu_key(command, current_step, action)
            }
        }
    }

    /// Returns the zero-based index of the active step currently in focus.
    #[must_use]
    pub const fn step_index(&self) -> usize {
        self.step_index
    }

    /// Returns whether pressing Back on step 0 returns to the command palette.
    #[must_use]
    pub const fn can_return_to_palette(&self) -> bool {
        self.can_return_to_palette
    }

    /// Returns the highlighted option index on menu, dynamic, or toggle steps.
    #[must_use]
    pub const fn selected_option_index(&self) -> usize {
        self.selected_option_index
    }

    /// Returns the loaded options for the current menu, dynamic, or toggle step.
    #[must_use]
    pub fn loaded_options(&self) -> &[SelectOption] {
        &self.loaded_options
    }

    /// Returns the current text buffer for text input steps.
    #[must_use]
    pub fn input_text(&self) -> &str {
        &self.input_text
    }

    /// Returns the cursor position measured in Unicode scalar values.
    #[must_use]
    pub const fn cursor_char_index(&self) -> usize {
        self.cursor_char_index
    }

    /// Returns the current step's validation or loader error message, if any.
    #[must_use]
    pub fn validation_error(&self) -> Option<&str> {
        self.validation_error.as_deref()
    }

    /// Returns the accumulated answers map (before final pruning).
    #[must_use]
    pub const fn answers(&self) -> &Answers {
        &self.answers
    }

    /// Returns the active [`StepSpec`] currently in focus, if any.
    #[must_use]
    pub fn current_step<'a>(&self, command: &'a CommandSpec) -> Option<&'a StepSpec> {
        get_active_steps_from_command(command, &self.answers)
            .get(self.step_index)
            .copied()
    }

    /// Returns `true` when the currently focused step accepts free-form text input.
    #[must_use]
    pub fn is_text_step(&self, command: &CommandSpec) -> bool {
        matches!(
            self.current_step(command).map(|step| &step.kind),
            Some(StepKind::Text { .. })
        )
    }

    fn load_current_step(&mut self, command: &CommandSpec) {
        self.validation_error = None;
        let active_steps = get_active_steps_from_command(command, &self.answers);
        if active_steps.is_empty() {
            self.step_index = 0;
            self.loaded_options.clear();
            self.selected_option_index = 0;
            self.clear_text_buffer();
            return;
        }
        if self.step_index >= active_steps.len() {
            self.step_index = active_steps.len() - 1;
        }
        let step = active_steps[self.step_index];
        let preferred_value = preferred_step_value(step, &self.answers);
        self.populate_step_controls(step, preferred_value.as_deref());
    }

    fn populate_step_controls(&mut self, step: &StepSpec, preferred_value: Option<&str>) {
        match &step.kind {
            StepKind::Select(options) => {
                self.loaded_options.clone_from(options);
                self.selected_option_index =
                    find_option_index(&self.loaded_options, preferred_value);
                self.clear_text_buffer();
            }
            StepKind::Toggle {
                yes_label,
                yes_help,
                no_label,
                no_help,
            } => {
                self.loaded_options = build_toggle_options(yes_label, yes_help, no_label, no_help);
                let toggle_target = preferred_value.or(Some("false"));
                self.selected_option_index = find_option_index(&self.loaded_options, toggle_target);
                self.clear_text_buffer();
            }
            StepKind::DynamicSelect(loader) => {
                self.load_dynamic_options(loader.as_ref(), preferred_value);
                self.clear_text_buffer();
            }
            StepKind::Text { .. } => {
                self.loaded_options.clear();
                self.selected_option_index = 0;
                preferred_value
                    .unwrap_or_default()
                    .clone_into(&mut self.input_text);
                self.cursor_char_index = self.input_text.chars().count();
            }
        }
    }

    fn load_dynamic_options(
        &mut self,
        loader: &(dyn Fn(&Answers) -> anyhow::Result<Vec<SelectOption>> + Send + Sync),
        preferred_value: Option<&str>,
    ) {
        match loader(&self.answers) {
            Ok(options) if !options.is_empty() => {
                self.selected_option_index = find_option_index(&options, preferred_value);
                self.loaded_options = options;
            }
            Ok(_) => {
                self.loaded_options.clear();
                self.selected_option_index = 0;
                self.validation_error = Some("No options available for this step.".to_owned());
            }
            Err(error) => {
                self.loaded_options.clear();
                self.selected_option_index = 0;
                self.validation_error = Some(error.to_string());
            }
        }
    }

    fn clear_text_buffer(&mut self) {
        self.input_text.clear();
        self.cursor_char_index = 0;
    }

    pub(super) fn step_back(&mut self, command: &CommandSpec, step: &StepSpec) -> WizardOutcome {
        if self.step_index == 0 {
            return if self.can_return_to_palette {
                WizardOutcome::BackToPalette
            } else {
                WizardOutcome::Continue
            };
        }
        self.save_current_draft(step);
        self.step_index = self.step_index.saturating_sub(1);
        if let Some(target_step) = get_active_steps_from_command(command, &self.answers)
            .get(self.step_index)
            .copied()
        {
            self.prefilled_keys.remove(&target_step.id);
        }
        self.load_current_step(command);
        WizardOutcome::Continue
    }

    pub(super) fn commit_step_answer(
        &mut self,
        command: &CommandSpec,
        step: &StepSpec,
        candidate_value: String,
    ) -> WizardOutcome {
        if let Some(validator) = &step.validate
            && let Err(message) = validator(&candidate_value, &self.answers)
        {
            self.validation_error = Some(message);
            return WizardOutcome::Continue;
        }
        self.answers.insert(step.id.clone(), candidate_value);
        self.prefilled_keys.remove(&step.id);
        let updated_steps = get_active_steps_from_command(command, &self.answers);
        let current_position = updated_steps
            .iter()
            .position(|active_step| active_step.id == step.id)
            .unwrap_or(self.step_index);
        if let Some(next_step_index) = updated_steps
            .iter()
            .enumerate()
            .skip(current_position + 1)
            .find_map(|(index, active_step)| {
                (!self.prefilled_keys.contains(&active_step.id)).then_some(index)
            })
        {
            self.step_index = next_step_index;
            self.load_current_step(command);
            WizardOutcome::Continue
        } else {
            WizardOutcome::Completed(prune_inactive_answers(command, &self.answers))
        }
    }
}

/// Returns whether `command` has at least one active step missing from `answers`.
#[must_use]
pub fn has_unanswered_active_step(command: &CommandSpec, answers: &Answers) -> bool {
    let active_steps = get_active_steps_from_command(command, answers);
    first_unanswered_step_index(&active_steps, answers).is_some()
}

fn first_unanswered_step_index(active_steps: &[&StepSpec], answers: &Answers) -> Option<usize> {
    active_steps
        .iter()
        .position(|step| !answers.contains_key(&step.id))
}

fn preferred_step_value(step: &StepSpec, answers: &Answers) -> Option<String> {
    answers.get(&step.id).cloned().or_else(|| {
        step.default_value
            .as_ref()
            .map(|provider| provider(answers))
    })
}

fn find_option_index(options: &[SelectOption], preferred_value: Option<&str>) -> usize {
    let Some(target_value) = preferred_value else {
        return 0;
    };
    options
        .iter()
        .position(|option| option.value == target_value)
        .unwrap_or(0)
}

fn build_toggle_options(
    yes_label: &str,
    yes_help: &str,
    no_label: &str,
    no_help: &str,
) -> Vec<SelectOption> {
    vec![
        SelectOption::new("false", no_label).with_help(no_help),
        SelectOption::new("true", yes_label).with_help(yes_help),
    ]
}
