-- Mouse click tests for PR conversation view: message selection, footer action
-- dispatch, and outside-window native click passthrough.
return function(context)
    local helpers = context.helpers
    local main_window = context.main_window
    local review = context.review
    local session = context.session

    session.conversation_current()
    assert(vim.wait(3000, function()
        local current_buf = vim.api.nvim_win_get_buf(main_window.find(review))
        return table.concat(vim.api.nvim_buf_get_lines(current_buf, 0, -1, false), "\n"):find("Offline follow-up", 1, true) ~= nil
    end), "reopened conversation draws")
    local reopened_win = main_window.find(review)
    local reopened_buf = vim.api.nvim_win_get_buf(reopened_win)
    vim.api.nvim_set_current_win(reopened_win)

    local mouse_mod = require("jpr.mouse")
    local original_getmousepos = vim.fn.getmousepos
    local original_passthrough = mouse_mod.passthrough
    local conversation_passthrough = {}
    mouse_mod.passthrough = function(key)
        conversation_passthrough[#conversation_passthrough + 1] = key
    end

    local is_conversation_mouse_ok, conversation_mouse_error = pcall(function()
        local conversation_lines = vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false)
        local own_line = helpers.find_line_number(conversation_lines, "Offline follow-up")
        assert(own_line ~= nil, "found own message line")
        vim.fn.getmousepos = function() return { winid = reopened_win, line = own_line, column = 3 } end
        helpers.press_key("<LeftMouse>")
        assert(vim.api.nvim_win_get_cursor(reopened_win)[1] == own_line, "clicking conversation message moves cursor")

        vim.fn.getmousepos = function() return { winid = review.panel.win, line = 1, column = 1 } end
        helpers.press_key("<LeftMouse>")
        assert(
            #conversation_passthrough == 1 and conversation_passthrough[1] == "<LeftMouse>",
            "outside conversation click passes through"
        )

        local comment_col = conversation_lines[#conversation_lines]:find("[c]omment", 1, true)
        assert(comment_col ~= nil, "found [c]omment in conversation footer")
        vim.fn.getmousepos = function() return { winid = reopened_win, line = #conversation_lines, column = comment_col + 2 } end
        helpers.press_key("<LeftMouse>")
        local compose_win = helpers.find_floating_win("PR Conversation")
        assert(compose_win ~= nil, "clicking [c]omment in footer opens compose float")
        helpers.press_key("q")
        assert(not vim.api.nvim_win_is_valid(compose_win), "closed compose float")

        vim.api.nvim_set_current_win(reopened_win)
        local quit_col = conversation_lines[#conversation_lines]:find("[q]uit", 1, true)
        vim.fn.getmousepos = function() return { winid = reopened_win, line = #conversation_lines, column = quit_col + 1 } end
        helpers.press_key("<LeftMouse>")
        assert(not vim.api.nvim_buf_is_valid(reopened_buf), "clicking [q]uit in conversation footer closes buffer")
    end)

    vim.fn.getmousepos = original_getmousepos
    mouse_mod.passthrough = original_passthrough
    assert(is_conversation_mouse_ok, tostring(conversation_mouse_error))
end
