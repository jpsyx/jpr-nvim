//! Menu and text input handling for [`WizardState`].

use crate::schema::{CommandSpec, StepKind, StepSpec};
use crate::state::KeyAction;

use super::{WizardOutcome, WizardState};

impl WizardState {
    pub(super) fn handle_menu_key(
        &mut self,
        command: &CommandSpec,
        step: &StepSpec,
        action: KeyAction,
    ) -> WizardOutcome {
        let option_count = self.loaded_options.len();
        match action {
            KeyAction::Up if option_count > 0 => {
                self.selected_option_index =
                    (self.selected_option_index + option_count - 1) % option_count;
                WizardOutcome::Continue
            }
            KeyAction::Down if option_count > 0 => {
                self.selected_option_index = (self.selected_option_index + 1) % option_count;
                WizardOutcome::Continue
            }
            KeyAction::First if option_count > 0 => {
                self.selected_option_index = 0;
                WizardOutcome::Continue
            }
            KeyAction::Last if option_count > 0 => {
                self.selected_option_index = option_count - 1;
                WizardOutcome::Continue
            }
            KeyAction::Back => self.step_back(command, step),
            KeyAction::Confirm => self.confirm_menu_option(command, step),
            _ => WizardOutcome::Continue,
        }
    }

    fn confirm_menu_option(&mut self, command: &CommandSpec, step: &StepSpec) -> WizardOutcome {
        let Some(selected_option) = self.loaded_options.get(self.selected_option_index) else {
            if self.validation_error.is_none() {
                self.validation_error = Some("No option selected.".to_owned());
            }
            return WizardOutcome::Continue;
        };
        let candidate_value = selected_option.value.clone();
        self.commit_step_answer(command, step, candidate_value)
    }

    pub(super) fn handle_text_key(
        &mut self,
        command: &CommandSpec,
        step: &StepSpec,
        action: KeyAction,
    ) -> WizardOutcome {
        match action {
            KeyAction::Back => self.step_back(command, step),
            KeyAction::Confirm => {
                let candidate_value = self.input_text.clone();
                self.commit_step_answer(command, step, candidate_value)
            }
            _ => {
                self.apply_text_edit(action);
                WizardOutcome::Continue
            }
        }
    }

    fn apply_text_edit(&mut self, action: KeyAction) {
        let char_count = self.input_text.chars().count();
        match action {
            KeyAction::Left => {
                self.cursor_char_index = self.cursor_char_index.saturating_sub(1);
            }
            KeyAction::Right if self.cursor_char_index < char_count => {
                self.cursor_char_index += 1;
            }
            KeyAction::Home => self.cursor_char_index = 0,
            KeyAction::End => self.cursor_char_index = char_count,
            KeyAction::Char(character) => {
                let byte_index = char_to_byte_index(&self.input_text, self.cursor_char_index);
                self.input_text.insert(byte_index, character);
                self.cursor_char_index += 1;
                self.validation_error = None;
            }
            KeyAction::Backspace if self.cursor_char_index > 0 => {
                let start_byte = char_to_byte_index(&self.input_text, self.cursor_char_index - 1);
                let end_byte = char_to_byte_index(&self.input_text, self.cursor_char_index);
                self.input_text.replace_range(start_byte..end_byte, "");
                self.cursor_char_index -= 1;
                self.validation_error = None;
            }
            KeyAction::Delete if self.cursor_char_index < char_count => {
                let start_byte = char_to_byte_index(&self.input_text, self.cursor_char_index);
                let end_byte = char_to_byte_index(&self.input_text, self.cursor_char_index + 1);
                self.input_text.replace_range(start_byte..end_byte, "");
                self.validation_error = None;
            }
            _ => {}
        }
    }

    pub(super) fn save_current_draft(&mut self, step: &StepSpec) {
        match &step.kind {
            StepKind::Text { .. } => {
                self.answers
                    .insert(step.id.clone(), self.input_text.clone());
            }
            StepKind::Select(_) | StepKind::DynamicSelect(_) | StepKind::Toggle { .. } => {
                if let Some(selected_option) = self.loaded_options.get(self.selected_option_index) {
                    self.answers
                        .insert(step.id.clone(), selected_option.value.clone());
                }
            }
        }
    }
}

fn char_to_byte_index(text: &str, char_index: usize) -> usize {
    text.char_indices()
        .nth(char_index)
        .map_or(text.len(), |(byte_index, _)| byte_index)
}
