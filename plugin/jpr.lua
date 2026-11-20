-- Defines :Jpr. Everything else loads on first use.
if vim.g.loaded_jpr then
    return
end
vim.g.loaded_jpr = true

vim.api.nvim_create_user_command("Jpr", function(opts)
    require("jpr").command(opts.fargs)
end, {
    nargs = "+",
    desc = "Review a GitHub pull request (open, sync, close)",
    complete = function(arglead, cmdline)
        return require("jpr").complete(arglead, cmdline)
    end,
})
