//! The changed files as a tree: directories first, then files, each sorted
//! by name, with a directory that holds only one directory joined to it.

use std::collections::BTreeMap;

use review_model::TreeRow;

/// The tree rows for `paths`, in which each file row points back at its
/// index in `paths`.
#[must_use]
pub fn create_file_tree_from_paths<'a>(paths: impl IntoIterator<Item = &'a str>) -> Vec<TreeRow> {
    let mut root = Directory::default();
    for (index, path) in paths.into_iter().enumerate() {
        let path_parts: Vec<&str> = path.split('/').collect();
        root.insert(&path_parts, index);
    }
    let mut rows = Vec::new();
    root.write_rows(0, &mut rows);
    rows
}

#[derive(Default)]
struct Directory<'a> {
    directories: BTreeMap<&'a str, Self>,
    files: BTreeMap<&'a str, usize>,
}

impl<'a> Directory<'a> {
    fn insert(&mut self, parts: &[&'a str], index: usize) {
        match parts {
            [] => {}
            [name] => {
                self.files.insert(*name, index);
            }
            [directory, rest @ ..] => self
                .directories
                .entry(*directory)
                .or_default()
                .insert(rest, index),
        }
    }

    fn write_rows(&self, depth: usize, rows: &mut Vec<TreeRow>) {
        for (name, directory) in &self.directories {
            let (label, contents) = directory.join_lone_children(name);
            rows.push(TreeRow {
                depth,
                name: label,
                file: None,
            });
            contents.write_rows(depth + 1, rows);
        }
        for (name, index) in &self.files {
            rows.push(TreeRow {
                depth,
                name: (*name).to_owned(),
                file: Some(*index),
            });
        }
    }

    /// The label for this directory, called `name`, joined with each
    /// directory below it that is its only child, and the directory whose
    /// contents go under that label.
    fn join_lone_children(&self, name: &str) -> (String, &Self) {
        let mut label = name.to_owned();
        let mut directory = self;
        while directory.files.is_empty() && directory.directories.len() == 1 {
            let Some((child_name, child)) = directory.directories.iter().next() else {
                break;
            };
            label = format!("{label}/{child_name}");
            directory = child;
        }
        (label, directory)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree_rows_to_sketch(rows: &[TreeRow]) -> Vec<String> {
        rows.iter()
            .map(|row| {
                let suffix = row
                    .file
                    .map_or_else(|| "/".to_owned(), |index| format!(" #{index}"));
                format!("{}{}{suffix}", "  ".repeat(row.depth), row.name)
            })
            .collect()
    }

    #[test]
    fn directories_come_first_and_lone_directories_join() {
        let rows = create_file_tree_from_paths([
            "src/a.rs",
            "src/core/b.rs",
            "src/core/c.rs",
            "README.md",
            "docs/x/y.md",
        ]);
        assert_eq!(
            tree_rows_to_sketch(&rows),
            [
                "docs/x/",
                "  y.md #4",
                "src/",
                "  core/",
                "    b.rs #1",
                "    c.rs #2",
                "  a.rs #0",
                "README.md #3",
            ]
        );
    }

    #[test]
    fn no_files_is_no_rows() {
        assert_eq!(create_file_tree_from_paths([]), Vec::new());
    }
}
