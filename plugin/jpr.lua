-- Defines :Jpr and <Plug>(jpr-*) mappings. Everything else loads on first use.
if vim.g.loaded_jpr then
    return
end
vim.g.loaded_jpr = true

vim.api.nvim_create_user_command("Jpr", function(opts)
    require("jpr").command(opts.fargs, opts)
end, {
    nargs = "*",
    range = true,
    desc = "Review a GitHub pull request",
    complete = function(arglead, cmdline)
        return require("jpr").complete(arglead, cmdline)
    end,
})

vim.keymap.set("n", "<Plug>(jpr-palette)", function()
    require("jpr").command({})
end, { desc = "Open Jpr command palette" })
if vim.fn.maparg("<leader>J", "n") == "" then
    vim.keymap.set("n", "<leader>J", "<Plug>(jpr-palette)", { remap = true, silent = true, desc = "Open Jpr command palette" })
end
vim.keymap.set({ "n", "x" }, "<Plug>(jpr-comment)", function()
    require("jpr").action("comment")
end, { desc = "New GitHub draft comment on line or visual range" })
vim.keymap.set({ "n", "x" }, "<Plug>(jpr-suggest-comment)", function()
    require("jpr").action("suggest_comment")
end, { desc = "New GitHub draft comment pre-filled with a suggestion block" })
vim.keymap.set("n", "<Plug>(jpr-file-comment)", function()
    require("jpr").action("file_comment")
end, { desc = "New file-level GitHub draft comment" })
vim.keymap.set("n", "<Plug>(jpr-full-diff)", function()
    require("jpr").action("full_diff")
end, { desc = "Switch to the full branch diff view" })
vim.keymap.set("n", "<Plug>(jpr-toggle-viewed)", function()
    require("jpr").action("toggle_viewed")
end, { desc = "Toggle viewed for the current file or directory" })
vim.keymap.set("n", "<Plug>(jpr-thread-popup)", function()
    require("jpr").action("thread_popup")
end, { desc = "Open the review thread popup on the cursor line" })
vim.keymap.set("n", "<Plug>(jpr-next-thread)", function()
    require("jpr").action("next_thread")
end, { desc = "Jump to the next review thread in the buffer" })
vim.keymap.set("n", "<Plug>(jpr-prev-thread)", function()
    require("jpr").action("prev_thread")
end, { desc = "Jump to the previous review thread in the buffer" })
vim.keymap.set("n", "<Plug>(jpr-send-agent)", function()
    require("jpr").action("send_agent")
end, { desc = "Send unsent local review threads to the coding agent (confirms)" })
vim.keymap.set("n", "<Plug>(jpr-submit-review)", function()
    require("jpr").action("submit_review")
end, { desc = "Open the GitHub review submission modal (confirms before submitting)" })
vim.keymap.set("n", "<Plug>(jpr-toggle-agent)", function()
    require("jpr").action("toggle_agent")
end, { desc = "Toggle the coding agent terminal panel without quitting it" })
