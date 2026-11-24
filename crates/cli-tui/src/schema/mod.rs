//! Declarative command and step schemas for interactive CLI palettes.

mod active;
mod validate;

#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Arc;

pub use active::{get_active_steps_from_command, prune_inactive_answers};
pub use validate::validate_command_specs;

/// Key-value map of step IDs to selected or entered answer strings.
pub type Answers = BTreeMap<String, String>;

/// Loader that fetches select options dynamically based on prior answers.
pub type OptionLoader = Arc<dyn Fn(&Answers) -> anyhow::Result<Vec<SelectOption>> + Send + Sync>;

/// Predicate deciding whether a step is active given the current answers.
pub type WhenPredicate = Arc<dyn Fn(&Answers) -> bool + Send + Sync>;

/// Provider computing a default answer string given the current answers.
pub type DefaultProvider = Arc<dyn Fn(&Answers) -> String + Send + Sync>;

/// Validator checking a candidate answer string before advancing.
pub type ValueValidator = Arc<dyn Fn(&str, &Answers) -> Result<(), String> + Send + Sync>;

/// One selectable choice inside a static or dynamic option list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectOption {
    /// Machine-readable value stored in [`Answers`] when chosen.
    pub value: String,
    /// Human-readable label shown in the interactive menu.
    pub label: String,
    /// Optional short badge rendered beside the label (for example `draft`).
    pub badge: Option<String>,
    /// Optional 1-sentence helper text shown only while this option is hovered.
    pub help: Option<String>,
}

impl SelectOption {
    /// Creates a new select option with no badge or hover helper text.
    #[must_use]
    pub fn new(value: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            label: label.into(),
            badge: None,
            help: None,
        }
    }

    /// Attaches a short badge to display beside the option label.
    #[must_use]
    pub fn with_badge(mut self, badge: impl Into<String>) -> Self {
        self.badge = Some(badge.into());
        self
    }

    /// Attaches 1-sentence hover helper text to display when hovered.
    #[must_use]
    pub fn with_help(mut self, help: impl Into<String>) -> Self {
        self.help = Some(help.into());
        self
    }
}

/// Interaction style for a single wizard step.
#[derive(Clone)]
pub enum StepKind {
    /// Static menu of predefined options.
    Select(Vec<SelectOption>),
    /// Dynamic menu whose options are loaded on step entry.
    DynamicSelect(OptionLoader),
    /// Boolean toggle storing `"true"` for yes and `"false"` for no.
    Toggle {
        /// Label shown for the `"true"` choice.
        yes_label: String,
        /// Hover helper text shown for the `"true"` choice.
        yes_help: String,
        /// Label shown for the `"false"` choice.
        no_label: String,
        /// Hover helper text shown for the `"false"` choice.
        no_help: String,
    },
    /// Single-line editable text input.
    Text {
        /// Optional placeholder hint shown when the input buffer is empty.
        placeholder: Option<String>,
    },
}

impl fmt::Debug for StepKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Select(options) => formatter.debug_tuple("Select").field(options).finish(),
            Self::DynamicSelect(_) => formatter.write_str("DynamicSelect(<loader>)"),
            Self::Toggle {
                yes_label,
                yes_help,
                no_label,
                no_help,
            } => formatter
                .debug_struct("Toggle")
                .field("yes_label", yes_label)
                .field("yes_help", yes_help)
                .field("no_label", no_label)
                .field("no_help", no_help)
                .finish(),
            Self::Text { placeholder } => formatter
                .debug_struct("Text")
                .field("placeholder", placeholder)
                .finish(),
        }
    }
}

/// Declarative definition of one interactive step within a [`CommandSpec`].
#[derive(Clone)]
pub struct StepSpec {
    /// Unique identifier for this step within its command; used as the [`Answers`] key.
    pub id: String,
    /// Human-readable title displayed in the step header.
    pub label: String,
    /// Concise 1-sentence helper text shown below the step header.
    pub help: String,
    /// Input control kind for this step.
    pub kind: StepKind,
    /// Optional provider producing a prefilled or preselected default value.
    pub default_value: Option<DefaultProvider>,
    /// Optional predicate controlling whether this step is active.
    pub when: Option<WhenPredicate>,
    /// Optional validator invoked before accepting the step's answer.
    pub validate: Option<ValueValidator>,
}

impl StepSpec {
    /// Creates a step with no default provider, condition, or validator.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        help: impl Into<String>,
        kind: StepKind,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            help: help.into(),
            kind,
            default_value: None,
            when: None,
            validate: None,
        }
    }

    /// Sets a static default value for this step.
    #[must_use]
    pub fn with_default(mut self, value: impl Into<String>) -> Self {
        let static_default = value.into();
        self.default_value = Some(Arc::new(move |_| static_default.clone()));
        self
    }

    /// Sets a dynamic default provider for this step.
    #[must_use]
    pub fn with_default_fn<F>(mut self, provider: F) -> Self
    where
        F: Fn(&Answers) -> String + Send + Sync + 'static,
    {
        self.default_value = Some(Arc::new(provider));
        self
    }

    /// Sets a predicate determining whether this step is active.
    #[must_use]
    pub fn with_when<F>(mut self, predicate: F) -> Self
    where
        F: Fn(&Answers) -> bool + Send + Sync + 'static,
    {
        self.when = Some(Arc::new(predicate));
        self
    }

    /// Sets a validator checked before the user can advance past this step.
    #[must_use]
    pub fn with_validate<F>(mut self, validator: F) -> Self
    where
        F: Fn(&str, &Answers) -> Result<(), String> + Send + Sync + 'static,
    {
        self.validate = Some(Arc::new(validator));
        self
    }
}

impl fmt::Debug for StepSpec {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StepSpec")
            .field("id", &self.id)
            .field("label", &self.label)
            .field("help", &self.help)
            .field("kind", &self.kind)
            .field("has_default", &self.default_value.is_some())
            .field("has_when", &self.when.is_some())
            .field("has_validate", &self.validate.is_some())
            .finish()
    }
}

/// Declarative specification of one command in the interactive palette.
#[derive(Debug, Clone)]
pub struct CommandSpec {
    /// Machine-readable command identifier (for example `"checkout"`).
    pub id: String,
    /// Human-readable display label (for example `"Check Out Pull Request"`).
    pub label: String,
    /// Concise 1-sentence helper text shown while this command is hovered.
    pub help: String,
    /// Ordered steps that gather any missing parameters for this command.
    pub steps: Vec<StepSpec>,
}

impl CommandSpec {
    /// Creates a new command specification.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        help: impl Into<String>,
        steps: Vec<StepSpec>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            help: help.into(),
            steps,
        }
    }
}
