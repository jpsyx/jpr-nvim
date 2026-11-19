//! The dependency rule from docs/architecture.md: a generic crate
//! (`review-*`) never depends on a frontend crate or a UI library, directly
//! or through another crate. Checked against `cargo metadata`'s resolved graph.

use std::collections::{BTreeSet, HashMap};
use std::process::Command;

use serde_json::{Value, json};

/// Libraries that tie code to a terminal UI or to an editor.
const UI_CRATES: &[&str] = &[
    "ratatui",
    "crossterm",
    "termion",
    "cursive",
    "tui-term",
    "portable-pty",
    "vt100",
    "nvim-rs",
    "nvim-oxi",
    "mlua",
    "neovim-lib",
];

const GENERIC_PREFIX: &str = "review-";

/// Every way a generic crate reaches a frontend crate or a UI library.
fn violations(metadata: &Value) -> Vec<String> {
    let names: HashMap<&str, &str> = metadata["packages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|package| Some((package["id"].as_str()?, package["name"].as_str()?)))
        .collect();
    let members: BTreeSet<&str> = metadata["workspace_members"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let edges: HashMap<&str, Vec<&str>> = metadata["resolve"]["nodes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|node| {
            let deps = node["deps"]
                .as_array()?
                .iter()
                .filter(|dep| runtime(dep))
                .filter_map(|dep| dep["pkg"].as_str())
                .collect();
            Some((node["id"].as_str()?, deps))
        })
        .collect();
    let mut found = Vec::new();
    for &member in &members {
        let member_name = names.get(member).copied().unwrap_or(member);
        if !member_name.starts_with(GENERIC_PREFIX) {
            continue;
        }
        let mut seen = BTreeSet::new();
        let mut stack = vec![member];
        while let Some(id) = stack.pop() {
            for &dep in edges.get(id).map(Vec::as_slice).unwrap_or_default() {
                if !seen.insert(dep) {
                    continue;
                }
                let name = names.get(dep).copied().unwrap_or(dep);
                if UI_CRATES.contains(&name) {
                    found.push(format!("{member_name} depends on the UI library {name}"));
                }
                if members.contains(dep) && !name.starts_with(GENERIC_PREFIX) {
                    found.push(format!(
                        "{member_name} depends on the frontend crate {name}"
                    ));
                }
                stack.push(dep);
            }
        }
    }
    found
}

/// Whether an edge is a normal or build dependency. Dev-dependencies may be anything.
fn runtime(dep: &Value) -> bool {
    dep["dep_kinds"].as_array().is_some_and(|kinds| {
        kinds
            .iter()
            .any(|kind| kind["kind"].is_null() || kind["kind"] == "build")
    })
}

fn workspace_metadata() -> Value {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned());
    let manifest = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml");
    let output = Command::new(cargo)
        .args([
            "metadata",
            "--format-version",
            "1",
            "--manifest-path",
            manifest,
        ])
        .output()
        .expect("cargo metadata runs");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("cargo metadata prints JSON")
}

#[test]
fn generic_crates_stay_frontend_neutral() {
    let found = violations(&workspace_metadata());
    assert!(
        found.is_empty(),
        "the dependency rule is broken:\n{}",
        found.join("\n")
    );
}

#[test]
fn the_rule_catches_a_ui_library_and_a_frontend_crate() {
    let metadata = json!({
        "packages": [
            { "id": "core", "name": "review-core" },
            { "id": "ui", "name": "ratatui" },
            { "id": "app", "name": "jpr-review" }
        ],
        "workspace_members": ["core", "app"],
        "resolve": { "nodes": [
            { "id": "core", "deps": [
                { "pkg": "ui", "dep_kinds": [{ "kind": null }] },
                { "pkg": "app", "dep_kinds": [{ "kind": null }] }
            ] },
            { "id": "ui", "deps": [] },
            { "id": "app", "deps": [] }
        ] }
    });
    assert_eq!(
        violations(&metadata),
        [
            "review-core depends on the UI library ratatui",
            "review-core depends on the frontend crate jpr-review",
        ]
    );
}

#[test]
fn dev_dependencies_are_exempt() {
    let metadata = json!({
        "packages": [{ "id": "core", "name": "review-core" }, { "id": "ui", "name": "ratatui" }],
        "workspace_members": ["core"],
        "resolve": { "nodes": [
            { "id": "core", "deps": [{ "pkg": "ui", "dep_kinds": [{ "kind": "dev" }] }] },
            { "id": "ui", "deps": [] }
        ] }
    });
    assert!(violations(&metadata).is_empty());
}
