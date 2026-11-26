-- Specs for pure agent command parsing, cold-start argv, and Claude Vim-mode detection.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local command = require("jpr.agent.command")

local function test_parse_command_argv()
    assert(vim.deep_equal(command.parse_command_argv("cl", "claude"), { "cl" }), "plain executable string")
    assert(
        vim.deep_equal(command.parse_command_argv("cl --model opus", "claude"), { "cl", "--model", "opus" }),
        "string with flags"
    )
    assert(
        vim.deep_equal(
            command.parse_command_argv("cl --tag 'a b' \"c d\"", "claude"),
            { "cl", "--tag", "a b", "c d" }
        ),
        "single and double quoted tokens"
    )
    assert(
        vim.deep_equal(command.parse_command_argv({ "cl", "--fast" }, "claude"), { "cl", "--fast" }),
        "argv table preserved"
    )
    assert(vim.deep_equal(command.parse_command_argv("", "claude"), { "claude" }), "empty string uses fallback")
    assert(vim.deep_equal(command.parse_command_argv("   \t ", "claude"), { "claude" }), "whitespace uses fallback")
    assert(vim.deep_equal(command.parse_command_argv(nil, "codex"), { "codex" }), "nil uses fallback")
end

local function test_launch_argv_and_cold_start_prompt()
    local home_dir = vim.fn.tempname()
    local worktree = "/tmp/my_repo.work/pr-7"
    local session_id = "00000000-0000-4000-8000-000000000001"
    assert(command.build_claude_project_slug_from_worktree(worktree) == "-tmp-my-repo-work-pr-7", "slug built")
    assert(not command.has_claude_transcript(worktree, session_id, home_dir), "transcript missing initially")

    local config = { agent = "claude", claude_cmd = "cl --model opus", codex_cmd = "codex" }
    local fresh_no_prompt = command.create_launch_argv_from_plan(
        config,
        worktree,
        { kind = "claude", sessionId = session_id, isResume = false },
        home_dir
    )
    assert(
        vim.deep_equal(fresh_no_prompt, { "cl", "--model", "opus", "--session-id", session_id }),
        "fresh claude without prompt"
    )

    local tricky_prompt = "- fix item\nCheck $HOME and 'quotes' and \"double\""
    assert(command.can_use_cli_initial_prompt("claude", tricky_prompt) == true, "claude accepts normal prompt")
    local fresh_with_prompt = command.create_launch_argv_from_plan(
        config,
        worktree,
        { kind = "claude", sessionId = session_id, isResume = false },
        home_dir,
        tricky_prompt
    )
    assert(
        vim.deep_equal(fresh_with_prompt, { "cl", "--model", "opus", "--session-id", session_id, "--", tricky_prompt }),
        "fresh claude with tricky prompt passes -- delimiter"
    )

    local transcript_dir = home_dir .. "/.claude/projects/-tmp-my-repo-work-pr-7"
    vim.fn.mkdir(transcript_dir, "p")
    vim.fn.writefile({ "{}" }, transcript_dir .. "/" .. session_id .. ".jsonl")
    assert(command.has_claude_transcript(worktree, session_id, home_dir), "transcript detected")

    local resumed_with_prompt = command.create_launch_argv_from_plan(
        config,
        worktree,
        { kind = "claude", sessionId = session_id, isResume = true },
        home_dir,
        tricky_prompt
    )
    assert(
        vim.deep_equal(resumed_with_prompt, { "cl", "--model", "opus", "--resume", session_id, "--", tricky_prompt }),
        "resumed claude with prompt uses --resume and --"
    )

    local oversized_prompt = string.rep("x", command.MAX_CLI_PROMPT_BYTES + 1)
    assert(command.can_use_cli_initial_prompt("claude", oversized_prompt) == false, "oversized prompt rejected")
    local oversized_argv = command.create_launch_argv_from_plan(
        config,
        worktree,
        { kind = "claude", sessionId = session_id, isResume = false },
        home_dir,
        oversized_prompt
    )
    assert(
        vim.deep_equal(oversized_argv, { "cl", "--model", "opus", "--session-id", session_id }),
        "oversized prompt omitted from CLI argv"
    )

    assert(command.can_use_cli_initial_prompt("codex", "hello") == false, "codex never uses CLI initial prompt")
    local codex_with_prompt = command.create_launch_argv_from_plan(
        config,
        worktree,
        { kind = "codex", sessionId = session_id, isResume = true },
        home_dir,
        "hello"
    )
    assert(vim.deep_equal(codex_with_prompt, { "codex", "resume", session_id }), "codex omits prompt")

    for _, missing_id in ipairs({ vim.NIL, "" }) do
        local no_id_with_prompt = command.create_launch_argv_from_plan(
            { claude_cmd = "cl" },
            worktree,
            { kind = "claude", sessionId = missing_id, isResume = false },
            home_dir,
            "run this"
        )
        assert(
            vim.deep_equal(no_id_with_prompt, { "cl", "--", "run this" }),
            "missing sessionId still preserves -- prompt"
        )
    end
end

local function test_claude_vim_mode_detection()
    local home_dir = vim.fn.tempname()
    assert(command.is_claude_vim_mode_enabled(home_dir, "") == false, "missing settings file is false")

    vim.fn.mkdir(home_dir .. "/.claude", "p")
    vim.fn.writefile({ '{"editorMode":"vim"}' }, home_dir .. "/.claude/settings.json")
    assert(command.is_claude_vim_mode_enabled(home_dir, "") == true, "vim editorMode detected in home")

    vim.fn.writefile({ '{"editorMode":"emacs"}' }, home_dir .. "/.claude/settings.json")
    assert(command.is_claude_vim_mode_enabled(home_dir, "") == false, "emacs editorMode returns false")

    vim.fn.writefile({ '{ invalid json' }, home_dir .. "/.claude/settings.json")
    assert(command.is_claude_vim_mode_enabled(home_dir, "") == false, "malformed JSON returns false safely")

    local custom_cfg = vim.fn.tempname()
    vim.fn.mkdir(custom_cfg, "p")
    vim.fn.writefile({ '{"editorMode":"vim"}' }, custom_cfg .. "/settings.json")
    assert(command.is_claude_vim_mode_enabled(home_dir, custom_cfg) == true, "custom config dir overrides home")
end

local function test_extract_prompt_preview_items()
    local prompt = table.concat({
        "Address 7 local review comments on PR #7 (octo/widgets).",
        "First run `jpr-review guide`.",
        "",
        "1. [loc-1] src/a.rs:L7",
        "   New comment: rename",
        "2. [loc-2] src/b.rs:L10-12",
        "3. [loc-3] src/c.rs",
        "4. [loc-4] PR",
        "5. [loc-5] src/e.rs:L1",
        "6. [loc-6] src/f.rs:L2",
        "7. [loc-7] src/g.rs:L3",
    }, "\n")
    local items = command.extract_prompt_preview_items(prompt)
    assert(
        vim.deep_equal(items, {
            "src/a.rs:L7",
            "src/b.rs:L10-12",
            "src/c.rs",
            "PR",
            "src/e.rs:L1",
            "... and 2 more",
        }),
        "preview caps at 5 items plus remainder: " .. vim.inspect(items)
    )
end

test_parse_command_argv()
test_launch_argv_and_cold_start_prompt()
test_claude_vim_mode_detection()
test_extract_prompt_preview_items()

print("agent_command_spec: ok")
