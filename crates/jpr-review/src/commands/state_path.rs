//! `state-path`: where a pull request's review state lives on this machine.

use anyhow::Result;

pub fn run(number: u64, repo: &str) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    println!("{}", super::state_dir(&owner, &name, number)?.display());
    Ok(())
}
