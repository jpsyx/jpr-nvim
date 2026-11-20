use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

/// Runs `program` in `dir` and returns its stdout, or fails with its stderr.
pub fn run(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("running {program}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
    }
    bail!(
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )
}
