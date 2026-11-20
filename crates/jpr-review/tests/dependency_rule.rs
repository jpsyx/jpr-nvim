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
    let graph = DependencyGraph::from_metadata(metadata);
    graph
        .members
        .iter()
        .copied()
        .filter(|member| graph.name(member).starts_with(GENERIC_PREFIX))
        .flat_map(|member| graph.violations_of(member))
        .collect()
}

/// The parts of `cargo metadata`'s resolved graph the rule reads, keyed by
/// package id.
struct DependencyGraph<'a> {
    /// Each package's name.
    names: HashMap<&'a str, &'a str>,
    /// The workspace's own packages.
    members: BTreeSet<&'a str>,
    /// Each package's normal and build dependencies.
    edges: HashMap<&'a str, Vec<&'a str>>,
}

impl<'a> DependencyGraph<'a> {
    fn from_metadata(metadata: &'a Value) -> Self {
        let names = metadata["packages"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|package| Some((package["id"].as_str()?, package["name"].as_str()?)))
            .collect();
        let members = metadata["workspace_members"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        let edges = metadata["resolve"]["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|node| {
                let dependencies = node["deps"]
                    .as_array()?
                    .iter()
                    .filter(|dependency| is_runtime_dependency(dependency))
                    .filter_map(|dependency| dependency["pkg"].as_str())
                    .collect();
                Some((node["id"].as_str()?, dependencies))
            })
            .collect();
        Self {
            names,
            members,
            edges,
        }
    }

    /// The name of the package `package_id`, or the id when it has none.
    fn name(&self, package_id: &'a str) -> &'a str {
        self.names.get(package_id).copied().unwrap_or(package_id)
    }

    /// Every UI library and frontend crate `member` reaches, directly or
    /// through another crate, as one message each.
    fn violations_of(&self, member: &'a str) -> Vec<String> {
        let member_name = self.name(member);
        let mut found_violations = Vec::new();
        let mut visited = BTreeSet::new();
        let mut to_visit = vec![member];
        while let Some(package_id) = to_visit.pop() {
            for &dependency in self
                .edges
                .get(package_id)
                .map(Vec::as_slice)
                .unwrap_or_default()
            {
                if !visited.insert(dependency) {
                    continue;
                }
                let name = self.name(dependency);
                if UI_CRATES.contains(&name) {
                    found_violations
                        .push(format!("{member_name} depends on the UI library {name}"));
                }
                if self.members.contains(dependency) && !name.starts_with(GENERIC_PREFIX) {
                    found_violations.push(format!(
                        "{member_name} depends on the frontend crate {name}"
                    ));
                }
                to_visit.push(dependency);
            }
        }
        found_violations
    }
}

/// Whether an edge is a normal or build dependency. Dev-dependencies may be anything.
fn is_runtime_dependency(dependency: &Value) -> bool {
    dependency["dep_kinds"].as_array().is_some_and(|kinds| {
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
    let found_violations = violations(&workspace_metadata());
    assert!(
        found_violations.is_empty(),
        "the dependency rule is broken:\n{}",
        found_violations.join("\n")
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
