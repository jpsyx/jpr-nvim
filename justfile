# Task entry points for jpr-nvim.
#
# `just` is a convenience, never a dependency: every recipe below is a single
# command you can also type by hand. Install it with `cargo install just`.

# Recipe arguments arrive as "$@" rather than just's own interpolation.
set positional-arguments

# Show the available tasks.
default:
    @just --list

# Compile every crate (debug).
build:
    cargo build --workspace

# Run the engine binary, for example: just run state-path --pr 7 --repo octo/widgets
run *args:
    cargo run -p jpr-review -- "$@"

# Run every Rust test, including the shared fakes and port contracts.
test:
    cargo test --workspace --all-features

# Run every Lua spec in a clean headless Neovim.
test-lua:
    ./scripts/test-lua.sh

# Lint with clippy (pedantic + nursery are on); any warning fails.
lint:
    cargo clippy --workspace --all-targets --all-features -- -D warnings

# Format the source.
fmt:
    cargo fmt --all

# Fail if anything is unformatted, without rewriting it.
fmt-check:
    cargo fmt --all --check

# Everything that has to pass before a change lands (reports only: `just fmt` fixes).
check: fmt-check lint test test-lua

# Build release and install `jpr-review` into $BIN_DIR (default ~/.local/bin).
install:
    ./install.sh

# Restore the agent skills pinned in skills-lock.json (run once after cloning).
skills-install:
    npx --yes skills experimental_install

# Update every agent skill this project has.
skills-update:
    ./scripts/skills/update-skills.sh
