//! Declarative command and step schemas for interactive CLI palettes.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Arc;

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

/// Validates a slice of command specifications for completeness and uniqueness.
pub fn validate_command_specs(commands: &[CommandSpec]) -> Result<(), String> {
    let mut seen_command_ids = std::collections::BTreeSet::new();
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

    let mut seen_step_ids = std::collections::BTreeSet::new();
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

/// Returns the ordered subset of steps in `command` whose `when` predicate is
/// `None` or evaluates to `true` for `answers`.
#[must_use]
pub fn resolve_active_steps<'a>(command: &'a CommandSpec, answers: &Answers) -> Vec<&'a StepSpec> {
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

/// Returns a copy of `answers` retaining only keys that belong to active steps
/// in `command`, iterating to a fixed point so transitive `when` chains prune
/// cleanly.
#[must_use]
pub fn prune_inactive_answers(command: &CommandSpec, answers: &Answers) -> Answers {
    let mut pruned = answers.clone();
    loop {
        let active_step_ids: std::collections::BTreeSet<&str> =
            resolve_active_steps(command, &pruned)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_branching_command() -> CommandSpec {
        CommandSpec::new(
            "threads",
            "List Review Threads",
            "Lists review threads from a live daemon socket or a pull request.",
            vec![
                StepSpec::new(
                    "target_mode",
                    "Target Source",
                    "Choose whether to query a running socket or a pull request.",
                    StepKind::Select(vec![
                        SelectOption::new("socket", "Live Daemon Socket")
                            .with_help("Connect to an already running jpr-review daemon."),
                        SelectOption::new("pr", "Pull Request Number")
                            .with_help("Read stored state for a specific PR number."),
                    ]),
                ),
                StepSpec::new(
                    "socket",
                    "Socket Path",
                    "Enter the Unix socket path for the running daemon.",
                    StepKind::Text {
                        placeholder: Some("/tmp/jpr.sock".to_owned()),
                    },
                )
                .with_when(|answers| {
                    answers.get("target_mode").map(String::as_str) == Some("socket")
                }),
                StepSpec::new(
                    "pr",
                    "Pull Request Number",
                    "Enter the pull request number to inspect.",
                    StepKind::Text {
                        placeholder: Some("42".to_owned()),
                    },
                )
                .with_when(|answers| answers.get("target_mode").map(String::as_str) == Some("pr")),
                StepSpec::new(
                    "repo",
                    "Repository",
                    "Enter the owner/name repository slug.",
                    StepKind::Text {
                        placeholder: Some("octo/widgets".to_owned()),
                    },
                )
                .with_when(|answers| answers.get("target_mode").map(String::as_str) == Some("pr")),
            ],
        )
    }

    #[test]
    fn validate_accepts_well_formed_command_specs() {
        let commands = vec![
            sample_branching_command(),
            CommandSpec::new(
                "guide",
                "Print Agent Review Guide",
                "Prints the review workflow guide to stdout.",
                vec![],
            ),
        ];
        assert_eq!(validate_command_specs(&commands), Ok(()));
    }

    #[test]
    fn validate_rejects_empty_command_fields() {
        let missing_label = vec![CommandSpec::new("guide", "   ", "Prints guide.", vec![])];
        assert!(validate_command_specs(&missing_label).is_err());

        let missing_help = vec![CommandSpec::new("guide", "Guide", "", vec![])];
        assert!(validate_command_specs(&missing_help).is_err());

        let missing_id = vec![CommandSpec::new("", "Guide", "Prints guide.", vec![])];
        assert!(validate_command_specs(&missing_id).is_err());
    }

    #[test]
    fn validate_rejects_duplicate_command_ids() {
        let duplicate = vec![
            CommandSpec::new("guide", "Guide A", "First guide.", vec![]),
            CommandSpec::new("guide", "Guide B", "Second guide.", vec![]),
        ];
        let error = validate_command_specs(&duplicate).unwrap_err();
        assert!(error.contains("guide"));
    }

    #[test]
    fn validate_rejects_duplicate_step_ids_and_empty_select_options() {
        let duplicate_steps = vec![CommandSpec::new(
            "cmd",
            "Command",
            "Does work.",
            vec![
                StepSpec::new(
                    "pr",
                    "PR",
                    "Enter PR.",
                    StepKind::Text { placeholder: None },
                ),
                StepSpec::new(
                    "pr",
                    "PR Again",
                    "Enter PR again.",
                    StepKind::Text { placeholder: None },
                ),
            ],
        )];
        assert!(validate_command_specs(&duplicate_steps).is_err());

        let empty_select = vec![CommandSpec::new(
            "cmd",
            "Command",
            "Does work.",
            vec![StepSpec::new(
                "mode",
                "Mode",
                "Pick mode.",
                StepKind::Select(vec![]),
            )],
        )];
        assert!(validate_command_specs(&empty_select).is_err());
    }

    #[test]
    fn resolve_active_steps_filters_by_when_predicates() {
        let command = sample_branching_command();

        let socket_answers = Answers::from([("target_mode".to_owned(), "socket".to_owned())]);
        let socket_ids: Vec<&str> = resolve_active_steps(&command, &socket_answers)
            .into_iter()
            .map(|step| step.id.as_str())
            .collect();
        assert_eq!(socket_ids, vec!["target_mode", "socket"]);

        let pr_answers = Answers::from([("target_mode".to_owned(), "pr".to_owned())]);
        let pr_ids: Vec<&str> = resolve_active_steps(&command, &pr_answers)
            .into_iter()
            .map(|step| step.id.as_str())
            .collect();
        assert_eq!(pr_ids, vec!["target_mode", "pr", "repo"]);
    }

    #[test]
    fn prune_inactive_answers_drops_stale_branch_keys() {
        let command = sample_branching_command();
        let dirty_answers = Answers::from([
            ("target_mode".to_owned(), "pr".to_owned()),
            ("socket".to_owned(), "/tmp/stale.sock".to_owned()),
            ("pr".to_owned(), "42".to_owned()),
            ("repo".to_owned(), "octo/widgets".to_owned()),
        ]);

        let pruned = prune_inactive_answers(&command, &dirty_answers);
        assert_eq!(
            pruned,
            Answers::from([
                ("target_mode".to_owned(), "pr".to_owned()),
                ("pr".to_owned(), "42".to_owned()),
                ("repo".to_owned(), "octo/widgets".to_owned()),
            ])
        );
    }

    #[test]
    fn prune_inactive_answers_prunes_transitive_when_chains() {
        let command = CommandSpec::new(
            "deploy",
            "Deploy",
            "Run a deployment.",
            vec![
                StepSpec::new(
                    "mode",
                    "Mode",
                    "Pick mode.",
                    StepKind::Select(vec![
                        SelectOption::new("local", "Local"),
                        SelectOption::new("remote", "Remote"),
                    ]),
                ),
                StepSpec::new(
                    "region",
                    "Region",
                    "Pick region.",
                    StepKind::Select(vec![
                        SelectOption::new("us", "US"),
                        SelectOption::new("eu", "EU"),
                    ]),
                )
                .with_when(|answers| answers.get("mode").map(String::as_str) == Some("remote")),
                StepSpec::new(
                    "eu_cluster",
                    "EU Cluster",
                    "Enter EU cluster name.",
                    StepKind::Text { placeholder: None },
                )
                .with_when(|answers| answers.get("region").map(String::as_str) == Some("eu")),
            ],
        );

        let dirty = Answers::from([
            ("mode".to_owned(), "local".to_owned()),
            ("region".to_owned(), "eu".to_owned()),
            ("eu_cluster".to_owned(), "fra-1".to_owned()),
        ]);

        let pruned = prune_inactive_answers(&command, &dirty);
        assert_eq!(
            pruned,
            Answers::from([("mode".to_owned(), "local".to_owned())])
        );
    }
}
