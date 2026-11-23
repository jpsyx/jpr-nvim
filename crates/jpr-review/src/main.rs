//! The binary: parse, dispatch, report, exit.
//!
//! Nothing else belongs here. Every decision lives in the library so it can be
//! tested without a process, and failures come back as one `anyhow::Error`
//! that this file turns into a stderr line and a non-zero exit code.

use std::process::ExitCode;

use anyhow::{Context, Result};
use app::cli::{Cli, Command};
use app::theme::Theme;
use app::tui_schema;
use clap::{CommandFactory, Parser};
use cli_tui::{CommandOutcome, PaletteOutcome};

const PALETTE_TITLE: &str = "jpr-review Commands";
const USAGE_EXIT_CODE: u8 = 2;

fn main() -> ExitCode {
    let cli = Cli::parse();
    let theme = Theme::active();
    cli.command.as_ref().map_or_else(
        || run_without_subcommand(theme),
        |command| report_result(run_with_subcommand(command, theme), theme),
    )
}

fn run_without_subcommand(theme: Theme) -> ExitCode {
    if !cli_tui::is_interactive_terminal() {
        eprint!("{}", Cli::command().render_help());
        return ExitCode::from(USAGE_EXIT_CODE);
    }
    report_result(run_interactive_palette(theme), theme)
}

fn run_interactive_palette(theme: Theme) -> Result<()> {
    let specs = tui_schema::build_command_specs();
    match cli_tui::run_palette(PALETTE_TITLE, &specs)? {
        PaletteOutcome::Completed {
            command_id,
            answers,
        } => {
            let command = tui_schema::answers_to_command(&command_id, &answers)?;
            app::commands::run_command(&command, theme)
        }
        PaletteOutcome::Cancelled => Ok(()),
    }
}

fn run_with_subcommand(command: &Command, theme: Theme) -> Result<()> {
    if cli_tui::is_interactive_terminal()
        && let Some((command_id, initial_answers)) =
            tui_schema::initial_answers_for_missing_inputs(command)
    {
        let specs = tui_schema::build_command_specs();
        let spec = specs
            .iter()
            .find(|candidate| candidate.id == command_id)
            .with_context(|| format!("missing interactive schema for `{command_id}`"))?;
        return match cli_tui::run_command(spec, initial_answers)? {
            CommandOutcome::Completed(answers) => {
                let resolved = tui_schema::answers_to_command(command_id, &answers)?;
                app::commands::run_command(&resolved, theme)
            }
            CommandOutcome::Cancelled => Ok(()),
        };
    }
    app::commands::run_command(command, theme)
}

fn report_result(result: Result<()>, theme: Theme) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // `{:#}` prints the whole `.context(...)` chain on one line.
            eprintln!("{}", theme.error_line("error:", &format!("{error:#}")));
            ExitCode::FAILURE
        }
    }
}
