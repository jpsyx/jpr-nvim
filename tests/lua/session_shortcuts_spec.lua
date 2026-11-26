-- Specs for review-wide gS, gs, and ga shortcuts across diff, base split,
-- stream, panel, and conversation buffers, plus custom/disabled key overrides.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local main_window = require("jpr.views.main_window")
local conversation_view = require("jpr.views.conversation")

local function find_buf_normal_map(buf, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if mapping.lhs == lhs then
            return mapping
        end
    end
    return nil
end

local function assert_session_maps(buf, label, expected)
    for lhs, expected_rhs in pairs(expected) do
        local mapping = find_buf_normal_map(buf, lhs)
        if expected_rhs == false then
            assert(mapping == nil, label .. " should not map " .. lhs)
        else
            assert(mapping ~= nil, label .. " missing map " .. lhs)
            assert(mapping.rhs == expected_rhs, label .. " map " .. lhs .. " rhs=" .. tostring(mapping.rhs))
        end
    end
end

local function setup_review_session(setup_opts)
    view_mode.path = vim.fn.tempname()
    vim.env.FAKE_ENGINE_LOG = vim.fn.tempname()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

    local opts = vim.tbl_deep_extend("force", {
        binary = root .. "/tests/lua/fixtures/fake_engine.sh",
    }, setup_opts or {})
    jpr.setup(opts)

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.view.pr ~= nil and review.panel ~= nil and review.stream ~= nil and review.stream.layout ~= nil
    end), "review session initialized")
    return review
end

local function test_default_shortcuts_bound_and_dispatch_across_all_review_buffers()
    local review = setup_review_session({ view = "split" })
    local default_maps = {
        gS = "<Plug>(jpr-send-agent)",
        gs = "<Plug>(jpr-submit-review)",
        ga = "<Plug>(jpr-toggle-agent)",
    }

    -- 1. PR Sidebar panel and stream buffers.
    assert_session_maps(review.panel.buf, "panel", default_maps)
    assert_session_maps(review.stream.buffers.main, "stream", default_maps)

    -- 2. Diff head + split base buffers.
    local main_win = main_window.find(review)
    main_window.edit(review, main_win, "README.md", 1)
    assert(vim.wait(3000, function()
        return review.diff.splits[main_win] ~= nil
    end), "split diff opened")
    local diff_buf = vim.api.nvim_win_get_buf(main_win)
    local base_buf = review.diff.splits[main_win].base_buf
    assert_session_maps(diff_buf, "diff", default_maps)
    assert_session_maps(base_buf, "base", default_maps)

    -- 3. PR conversation buffer.
    conversation_view.show(review)
    assert_session_maps(review.conversation.buf, "conversation", default_maps)

    -- 4. Pressing gS, gs, ga dispatches to send_current, submit_current, agent_current.
    local dispatched = {}
    local orig_send, orig_submit, orig_agent = session.send_current, session.submit_current, session.agent_current
    session.send_current = function() dispatched[#dispatched + 1] = "send" end
    session.submit_current = function() dispatched[#dispatched + 1] = "submit" end
    session.agent_current = function() dispatched[#dispatched + 1] = "agent" end

    vim.api.nvim_set_current_win(review.panel.win)
    helpers.press_key("gS")
    helpers.press_key("gs")
    helpers.press_key("ga")
    assert(vim.deep_equal(dispatched, { "send", "submit", "agent" }), "gS/gs/ga dispatch cleanly: " .. vim.inspect(dispatched))

    session.send_current, session.submit_current, session.agent_current = orig_send, orig_submit, orig_agent
    session.close_current()
end

local function test_custom_and_disabled_session_shortcuts()
    local review = setup_review_session({
        keys = {
            send_agent = false,
            submit_review = "gR",
            toggle_agent = false,
        },
    })
    local custom_maps = {
        gS = false,
        gs = false,
        ga = false,
        gR = "<Plug>(jpr-submit-review)",
    }

    assert_session_maps(review.panel.buf, "custom panel", custom_maps)
    assert_session_maps(review.stream.buffers.main, "custom stream", custom_maps)
    conversation_view.show(review)
    assert_session_maps(review.conversation.buf, "custom conversation", custom_maps)

    -- <Plug> mappings remain available even when default buffer keys are disabled.
    assert(vim.fn.maparg("<Plug>(jpr-send-agent)", "n") ~= "", "<Plug>(jpr-send-agent) stays defined")
    assert(vim.fn.maparg("<Plug>(jpr-submit-review)", "n") ~= "", "<Plug>(jpr-submit-review) stays defined")
    assert(vim.fn.maparg("<Plug>(jpr-toggle-agent)", "n") ~= "", "<Plug>(jpr-toggle-agent) stays defined")

    session.close_current()
    jpr.setup({})
end

test_default_shortcuts_bound_and_dispatch_across_all_review_buffers()
test_custom_and_disabled_session_shortcuts()

print("session_shortcuts_spec: ok")
