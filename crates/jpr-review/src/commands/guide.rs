use anyhow::Result;

/// Runs `jpr-review guide`: prints the interactive agent contract to stdout.
pub fn run() -> Result<()> {
    print!("{}", review_core::build_agent_guide());
    Ok(())
}
