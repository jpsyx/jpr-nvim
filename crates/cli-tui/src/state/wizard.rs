//! Pure state machine driving a single command wizard step by step.

use crate::schema::{
    Answers, CommandSpec, SelectOption, StepKind, StepSpec, prune_inactive_answers,
    resolve_active_steps,
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
    answers: Answers,
    step_index: usize,
    can_return_to_palette: bool,
    selected_option_index: usize,
    loaded_options: Vec<SelectOption>,
    input_text: String,
    cursor_char_index: usize,
    validation_error: Option<String>,
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
        let active_steps = resolve_active_steps(command, &initial_answers);
        let starting_step_index =
            first_unanswered_step_index(&active_steps, &initial_answers).unwrap_or(0);
        let mut state = Self {
            answers: initial_answers,
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
        if resolve_active_steps(command, &self.answers).is_empty() {
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
        let active_steps = resolve_active_steps(command, &self.answers);
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
        resolve_active_steps(command, &self.answers)
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
        let active_steps = resolve_active_steps(command, &self.answers);
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

    fn handle_menu_key(
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

    fn handle_text_key(
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

    fn save_current_draft(&mut self, step: &StepSpec) {
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

    fn step_back(&mut self, command: &CommandSpec, step: &StepSpec) -> WizardOutcome {
        if self.step_index == 0 {
            return if self.can_return_to_palette {
                WizardOutcome::BackToPalette
            } else {
                WizardOutcome::Continue
            };
        }
        self.save_current_draft(step);
        self.step_index = self.step_index.saturating_sub(1);
        self.load_current_step(command);
        WizardOutcome::Continue
    }

    fn commit_step_answer(
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
        let updated_steps = resolve_active_steps(command, &self.answers);
        let current_position = updated_steps
            .iter()
            .position(|active_step| active_step.id == step.id)
            .unwrap_or(self.step_index);
        let next_step_index = current_position + 1;
        if next_step_index < updated_steps.len() {
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
    let active_steps = resolve_active_steps(command, answers);
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

fn char_to_byte_index(text: &str, char_index: usize) -> usize {
    text.char_indices()
        .nth(char_index)
        .map_or(text.len(), |(byte_index, _)| byte_index)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn branching_command() -> CommandSpec {
        CommandSpec::new(
            "threads",
            "List Review Threads",
            "Lists review threads from a socket or pull request.",
            vec![
                StepSpec::new(
                    "target_mode",
                    "Target Source",
                    "Pick socket or pull request.",
                    StepKind::Select(vec![
                        SelectOption::new("socket", "Live Socket"),
                        SelectOption::new("pr", "Pull Request"),
                    ]),
                )
                .with_default("socket"),
                StepSpec::new(
                    "socket",
                    "Socket Path",
                    "Path to running daemon socket.",
                    StepKind::Text {
                        placeholder: Some("/tmp/jpr.sock".to_owned()),
                    },
                )
                .with_default("/tmp/default.sock")
                .with_when(|answers| {
                    answers.get("target_mode").map(String::as_str) == Some("socket")
                }),
                StepSpec::new(
                    "pr",
                    "Pull Request Number",
                    "Numeric PR identifier.",
                    StepKind::Text {
                        placeholder: Some("42".to_owned()),
                    },
                )
                .with_when(|answers| answers.get("target_mode").map(String::as_str) == Some("pr"))
                .with_validate(|value, _| {
                    if value.trim().parse::<u64>().is_ok() {
                        Ok(())
                    } else {
                        Err("Pull request must be a positive integer.".to_owned())
                    }
                }),
                StepSpec::new(
                    "repo",
                    "Repository",
                    "Owner/name repository slug.",
                    StepKind::Text {
                        placeholder: Some("octo/widgets".to_owned()),
                    },
                )
                .with_default("octo/widgets")
                .with_when(|answers| answers.get("target_mode").map(String::as_str) == Some("pr")),
            ],
        )
    }

    #[test]
    fn wizard_discriminant_branching_back_and_stale_answer_pruning() {
        let command = branching_command();
        let mut wizard = WizardState::new(&command, Answers::new(), true);

        assert_eq!(wizard.step_index(), 0);
        assert_eq!(wizard.selected_option_index(), 0);

        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 1);
        assert_eq!(wizard.input_text(), "/tmp/default.sock");

        assert_eq!(
            wizard.handle_key(&command, KeyAction::Back),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 0);
        assert_eq!(
            wizard.answers().get("socket").map(String::as_str),
            Some("/tmp/default.sock")
        );

        assert_eq!(
            wizard.handle_key(&command, KeyAction::Down),
            WizardOutcome::Continue
        );
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 1);
        assert_eq!(
            wizard.current_step(&command).map(|step| step.id.as_str()),
            Some("pr")
        );

        for character in "77".chars() {
            assert_eq!(
                wizard.handle_key(&command, KeyAction::Char(character)),
                WizardOutcome::Continue
            );
        }
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 2);
        assert_eq!(wizard.input_text(), "octo/widgets");

        let outcome = wizard.handle_key(&command, KeyAction::Confirm);
        assert_eq!(
            outcome,
            WizardOutcome::Completed(Answers::from([
                ("target_mode".to_owned(), "pr".to_owned()),
                ("pr".to_owned(), "77".to_owned()),
                ("repo".to_owned(), "octo/widgets".to_owned()),
            ]))
        );
    }

    #[test]
    fn wizard_multi_round_discriminant_toggle_restores_draft_and_prunes() {
        let command = branching_command();
        let mut wizard = WizardState::new(&command, Answers::new(), false);

        // Choose socket, customize draft, step back.
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        let _ = wizard.handle_key(&command, KeyAction::Char('2'));
        let _ = wizard.handle_key(&command, KeyAction::Back);

        // Switch to pr, type "15", advance to repo, then step back twice to target_mode.
        let _ = wizard.handle_key(&command, KeyAction::Down);
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        let _ = wizard.handle_key(&command, KeyAction::Char('1'));
        let _ = wizard.handle_key(&command, KeyAction::Char('5'));
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        assert_eq!(wizard.step_index(), 2);
        let _ = wizard.handle_key(&command, KeyAction::Back);
        let _ = wizard.handle_key(&command, KeyAction::Back);
        assert_eq!(wizard.step_index(), 0);

        // Toggle back to socket: previous socket draft is restored and pr/repo are pruned.
        let _ = wizard.handle_key(&command, KeyAction::Up);
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        assert_eq!(wizard.input_text(), "/tmp/default.sock2");
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Completed(Answers::from([
                ("target_mode".to_owned(), "socket".to_owned()),
                ("socket".to_owned(), "/tmp/default.sock2".to_owned()),
            ]))
        );
    }

    #[test]
    fn wizard_validation_failure_keeps_focus_and_sets_error() {
        let command = branching_command();
        let initial = Answers::from([("target_mode".to_owned(), "pr".to_owned())]);
        let mut wizard = WizardState::new(&command, initial, false);

        assert_eq!(wizard.step_index(), 1);
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Char('x')),
            WizardOutcome::Continue
        );
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 1);
        assert_eq!(
            wizard.validation_error(),
            Some("Pull request must be a positive integer.")
        );
    }

    #[test]
    fn wizard_utf8_text_editing_and_boundary_keys_stay_safe() {
        let command = CommandSpec::new(
            "reply",
            "Reply",
            "Send a reply.",
            vec![StepSpec::new(
                "body",
                "Reply Body",
                "Type your reply.",
                StepKind::Text { placeholder: None },
            )],
        );
        let mut wizard = WizardState::new(&command, Answers::new(), false);

        // Boundary no-ops on empty text.
        for boundary_action in [
            KeyAction::Left,
            KeyAction::Right,
            KeyAction::Home,
            KeyAction::End,
            KeyAction::Backspace,
            KeyAction::Delete,
        ] {
            assert_eq!(
                wizard.handle_key(&command, boundary_action),
                WizardOutcome::Continue
            );
        }
        assert_eq!(wizard.input_text(), "");
        assert_eq!(wizard.cursor_char_index(), 0);

        for character in "héllo🦀".chars() {
            let _ = wizard.handle_key(&command, KeyAction::Char(character));
        }
        assert_eq!(wizard.input_text(), "héllo🦀");
        assert_eq!(wizard.cursor_char_index(), 6);

        // Right/Delete past end are no-ops.
        let _ = wizard.handle_key(&command, KeyAction::Right);
        let _ = wizard.handle_key(&command, KeyAction::Delete);
        assert_eq!(wizard.cursor_char_index(), 6);

        // Move left past 🦀 and insert '!'.
        let _ = wizard.handle_key(&command, KeyAction::Left);
        let _ = wizard.handle_key(&command, KeyAction::Char('!'));
        assert_eq!(wizard.input_text(), "héllo!🦀");

        // Jump Home: Left/Backspace at 0 are no-ops; Right + Delete removes 'é'.
        let _ = wizard.handle_key(&command, KeyAction::Home);
        let _ = wizard.handle_key(&command, KeyAction::Left);
        let _ = wizard.handle_key(&command, KeyAction::Backspace);
        assert_eq!(wizard.cursor_char_index(), 0);
        let _ = wizard.handle_key(&command, KeyAction::Right);
        let _ = wizard.handle_key(&command, KeyAction::Delete);
        assert_eq!(wizard.input_text(), "hllo!🦀");
        let _ = wizard.handle_key(&command, KeyAction::Backspace);
        assert_eq!(wizard.input_text(), "llo!🦀");

        let _ = wizard.handle_key(&command, KeyAction::End);
        let _ = wizard.handle_key(&command, KeyAction::Backspace);
        assert_eq!(wizard.input_text(), "llo!");
    }

    #[test]
    fn wizard_back_on_first_step_never_mutates_answers_and_respects_palette_flag() {
        let command = branching_command();

        let mut from_palette = WizardState::new(&command, Answers::new(), true);
        assert_eq!(
            from_palette.handle_key(&command, KeyAction::Back),
            WizardOutcome::BackToPalette
        );
        assert!(from_palette.answers().is_empty());

        let mut direct = WizardState::new(&command, Answers::new(), false);
        assert_eq!(
            direct.handle_key(&command, KeyAction::Back),
            WizardOutcome::Continue
        );
        assert_eq!(direct.step_index(), 0);
        assert!(direct.answers().is_empty());
    }

    #[test]
    fn wizard_zero_step_command_completes_immediately_but_cancel_always_cancels() {
        let command = CommandSpec::new(
            "guide",
            "Print Agent Review Guide",
            "Prints the review workflow guide.",
            vec![],
        );
        let mut wizard = WizardState::new(&command, Answers::new(), true);
        assert_eq!(wizard.immediate_completion(&command), Some(Answers::new()));
        assert!(!has_unanswered_active_step(&command, &Answers::new()));
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Cancel),
            WizardOutcome::Cancelled
        );
    }

    #[test]
    fn wizard_toggle_and_dynamic_select_work_cleanly() {
        let command = CommandSpec::new(
            "review",
            "Review",
            "Run review.",
            vec![
                StepSpec::new(
                    "pr",
                    "Pull Request",
                    "Pick an open PR.",
                    StepKind::DynamicSelect(Arc::new(|_| {
                        Ok(vec![
                            SelectOption::new("10", "#10 Add auth"),
                            SelectOption::new("12", "#12 Fix parser"),
                        ])
                    })),
                )
                .with_default("12"),
                StepSpec::new(
                    "is_local_only",
                    "Local Only",
                    "Filter to local-only threads.",
                    StepKind::Toggle {
                        yes_label: "Local only".to_owned(),
                        yes_help: "Include only unsynced local threads.".to_owned(),
                        no_label: "All threads".to_owned(),
                        no_help: "Include both remote and local threads.".to_owned(),
                    },
                ),
            ],
        );

        let mut wizard = WizardState::new(&command, Answers::new(), false);
        assert_eq!(wizard.selected_option_index(), 1);
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Continue
        );

        assert_eq!(wizard.selected_option_index(), 0);
        let _ = wizard.handle_key(&command, KeyAction::Down);
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Confirm),
            WizardOutcome::Completed(Answers::from([
                ("pr".to_owned(), "12".to_owned()),
                ("is_local_only".to_owned(), "true".to_owned()),
            ]))
        );
    }

    #[test]
    fn wizard_dynamic_select_failure_and_empty_handle_navigation_and_back() {
        let command = CommandSpec::new(
            "checkout",
            "Check Out",
            "Check out a PR.",
            vec![
                StepSpec::new(
                    "source",
                    "Source",
                    "Pick source.",
                    StepKind::Select(vec![
                        SelectOption::new("err", "Failing list"),
                        SelectOption::new("empty", "Empty list"),
                    ]),
                ),
                StepSpec::new(
                    "pr",
                    "Pull Request",
                    "Pick an open PR.",
                    StepKind::DynamicSelect(Arc::new(|answers| {
                        if answers.get("source").map(String::as_str) == Some("err") {
                            Err(anyhow::anyhow!("gh auth missing"))
                        } else {
                            Ok(vec![])
                        }
                    })),
                ),
            ],
        );

        let mut wizard = WizardState::new(&command, Answers::new(), false);
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        assert_eq!(wizard.validation_error(), Some("gh auth missing"));
        for action in [
            KeyAction::Up,
            KeyAction::Down,
            KeyAction::First,
            KeyAction::Last,
            KeyAction::Confirm,
        ] {
            assert_eq!(wizard.handle_key(&command, action), WizardOutcome::Continue);
        }
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Back),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 0);

        let _ = wizard.handle_key(&command, KeyAction::Down);
        let _ = wizard.handle_key(&command, KeyAction::Confirm);
        assert!(wizard.validation_error().is_some());
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Down),
            WizardOutcome::Continue
        );
        assert_eq!(
            wizard.handle_key(&command, KeyAction::Back),
            WizardOutcome::Continue
        );
        assert_eq!(wizard.step_index(), 0);
    }
}
