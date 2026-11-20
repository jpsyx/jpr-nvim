use anyhow::Result;

/// Runs `jpr-review state-path`: prints the directory that holds pull request
/// `number`'s review state for `repo` (owner/name) on this machine, so a person
/// or a script can inspect or remove it.
pub fn run(number: u64, repo: &str) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    println!("{}", super::state_dir(&owner, &name, number)?.display());
    Ok(())
}
