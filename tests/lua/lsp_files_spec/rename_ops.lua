-- LSP file rename specs: willRename/didRename, case-only APFS, directory prefix boundaries, and partial client failures.
return function(ctx)
    local lsp_files = ctx.lsp_files
    local create_temp_worktree = ctx.create_temp_worktree
    local write_lines = ctx.write_lines
    local open_buffer = ctx.open_buffer
    local list_dir_entries = ctx.list_dir_entries
    local restore_stubs = ctx.restore_stubs

    -- Test 1: File rename with willRenameFiles, WorkspaceEdit autosave, intermediate dirs, buffer rename, didRenameFiles
    do
        local worktree = create_temp_worktree()
        local old_path = worktree .. "/src/old.ts"
        local new_path = worktree .. "/moved/nested/new.ts"
        local caller_path = worktree .. "/src/caller.ts"
        write_lines(old_path, { "export const answer = 42;" })
        write_lines(caller_path, { 'import { answer } from "./old";' })

        local old_buf = open_buffer(old_path)
        local caller_buf = open_buffer(caller_path)

        local recorded = { will = {}, did = {} }
        local fake_client = {
            id = 101,
            name = "tsserver",
            offset_encoding = "utf-16",
            config = { root_dir = worktree },
            server_capabilities = {
                workspace = {
                    fileOperations = {
                        willRename = { filters = { { scheme = "file", pattern = { glob = "**/*.ts", matches = "file" } } } },
                        didRename = { filters = { { scheme = "file", pattern = { glob = "**/*.ts", matches = "file" } } } },
                    },
                },
            },
            request_sync = function(_, method, params)
                recorded.will[#recorded.will + 1] = { method = method, params = params }
                return {
                    result = {
                        changes = {
                            [vim.uri_from_fname(caller_path)] = {
                                {
                                    range = {
                                        start = { line = 0, character = 23 },
                                        ["end"] = { line = 0, character = 30 },
                                    },
                                    newText = '"../moved/nested/new"',
                                },
                            },
                        },
                    },
                }
            end,
            notify = function(_, method, params)
                recorded.did[#recorded.did + 1] = { method = method, params = params }
            end,
        }
        vim.lsp.get_clients = function()
            return { fake_client }
        end

        local done_ok, done_err
        lsp_files.rename(old_path, new_path, { attach_timeout_ms = 0 }, function(ok, err)
            done_ok, done_err = ok, err
        end)

        assert(done_ok == true and done_err == nil, "rename should succeed: " .. tostring(done_err))
        assert(#recorded.will == 1 and recorded.will[1].method == "workspace/willRenameFiles", "willRenameFiles sent")
        assert(recorded.will[1].params.files[1].oldUri == vim.uri_from_fname(old_path), "willRename oldUri matches")
        assert(recorded.will[1].params.files[1].newUri == vim.uri_from_fname(new_path), "willRename newUri matches")
        assert(vim.uv.fs_stat(old_path) == nil, "old file removed from disk")
        assert(vim.uv.fs_stat(new_path) ~= nil, "new file created across intermediate dirs")
        assert(vim.fn.readfile(new_path)[1] == "export const answer = 42;", "moved file content preserved")
        assert(
            vim.fn.readfile(caller_path)[1] == 'import { answer } from "../moved/nested/new";',
            "WorkspaceEdit applied and autosaved to caller.ts"
        )
        assert(vim.bo[caller_buf].modified == false, "clean caller buffer remains clean after autosave")
        assert(vim.api.nvim_buf_get_name(old_buf) == new_path, "open buffer name updated to new_path")
        assert(#recorded.did == 1 and recorded.did[1].method == "workspace/didRenameFiles", "didRenameFiles sent")

        pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, caller_buf, { force = true })
        vim.fn.delete(worktree, "rf")
        restore_stubs()
    end

    -- Test 2: Case-only rename on macOS APFS (Foo.ts -> foo.ts) via (dev, ino) check
    do
        local worktree = create_temp_worktree()
        local upper_path = worktree .. "/src/Foo.ts"
        local lower_path = worktree .. "/src/foo.ts"
        write_lines(upper_path, { "export const name = 'Foo';" })
        local buf = open_buffer(upper_path)

        vim.lsp.get_clients = function()
            return {}
        end

        local done_ok, done_err
        lsp_files.rename(upper_path, lower_path, { attach_timeout_ms = 0 }, function(ok, err)
            done_ok, done_err = ok, err
        end)

        assert(done_ok == true and done_err == nil, "case-only rename should succeed: " .. tostring(done_err))
        local entries = list_dir_entries(worktree .. "/src")
        assert(entries["foo.ts"] == true, "directory listing contains lowercase foo.ts")
        assert(entries["Foo.ts"] == nil, "directory listing no longer has Foo.ts")
        assert(vim.api.nvim_buf_get_name(buf) == lower_path, "open buffer renamed to foo.ts")

        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        vim.fn.delete(worktree, "rf")
        restore_stubs()
    end

    -- Test 3: Directory rename prefix boundary (src/api -> src/v2/api beside src/api-extra/other.ts)
    do
        local worktree = create_temp_worktree()
        local api_file = worktree .. "/src/api/index.ts"
        local extra_file = worktree .. "/src/api-extra/other.ts"
        write_lines(api_file, { "export const api = true;" })
        write_lines(extra_file, { "export const extra = true;" })

        local api_buf = open_buffer(api_file)
        local extra_buf = open_buffer(extra_file)

        vim.lsp.get_clients = function()
            return {}
        end

        local done_ok, done_err
        lsp_files.rename(worktree .. "/src/api", worktree .. "/src/v2/api", { attach_timeout_ms = 0 }, function(ok, err)
            done_ok, done_err = ok, err
        end)

        assert(done_ok == true and done_err == nil, "dir rename should succeed: " .. tostring(done_err))
        assert(vim.uv.fs_stat(worktree .. "/src/v2/api/index.ts") ~= nil, "moved dir child exists")
        assert(vim.uv.fs_stat(worktree .. "/src/api") == nil, "old dir removed")
        assert(vim.uv.fs_stat(extra_file) ~= nil, "sibling src/api-extra untouched on disk")
        assert(vim.api.nvim_buf_get_name(api_buf) == worktree .. "/src/v2/api/index.ts", "api buffer renamed")
        assert(vim.api.nvim_buf_get_name(extra_buf) == extra_file, "api-extra buffer untouched")

        -- Refuse moving a directory into itself
        local self_ok, self_err
        lsp_files.rename(worktree .. "/src/v2/api", worktree .. "/src/v2/api/sub", { attach_timeout_ms = 0 }, function(ok, err)
            self_ok, self_err = ok, err
        end)
        assert(self_ok == false and self_err ~= nil, "moving directory into itself must fail")

        pcall(vim.api.nvim_buf_delete, api_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, extra_buf, { force = true })
        vim.fn.delete(worktree, "rf")
        restore_stubs()
    end

    -- Test 4: Partial LSP client timeout/error collects all replies first, prompts via vim.ui.select
    do
        local worktree = create_temp_worktree()
        local old_path = worktree .. "/src/a.ts"
        local new_path = worktree .. "/src/b.ts"
        local caller_path = worktree .. "/src/caller.ts"
        write_lines(old_path, { "export const a = 1;" })
        write_lines(caller_path, { 'import { a } from "./a";' })
        local caller_buf = open_buffer(caller_path)

        local did_count = 0
        local warnings = {}
        require("jpr.notify").set_listener(function(kind, msg)
            if kind == "warn" then
                warnings[#warnings + 1] = "jpr: " .. msg
            end
        end)

        local client_ok = {
            id = 201,
            name = "tsserver",
            offset_encoding = "utf-16",
            config = { root_dir = worktree },
            server_capabilities = { workspace = { fileOperations = { willRename = true, didRename = true } } },
            request_sync = function()
                return {
                    result = {
                        changes = {
                            [vim.uri_from_fname(caller_path)] = {
                                {
                                    range = {
                                        start = { line = 0, character = 18 },
                                        ["end"] = { line = 0, character = 23 },
                                    },
                                    newText = '"./b"',
                                },
                            },
                        },
                    },
                }
            end,
            notify = function()
                did_count = did_count + 1
            end,
        }
        local client_timeout = {
            id = 202,
            name = "eslint",
            offset_encoding = "utf-16",
            config = { root_dir = worktree },
            server_capabilities = { workspace = { fileOperations = { willRename = true, didRename = true } } },
            request_sync = function()
                return nil, "timeout"
            end,
            notify = function()
                did_count = did_count + 1
            end,
        }
        vim.lsp.get_clients = function()
            return { client_ok, client_timeout }
        end

        -- Case A: Cancel leaves disk and buffers untouched
        local select_called = false
        vim.ui.select = function(items, _, on_choice)
            select_called = true
            assert(#items == 2, "select offers proceed and cancel")
            on_choice("Cancel rename")
        end

        local cancel_ok
        lsp_files.rename(old_path, new_path, { attach_timeout_ms = 0 }, function(ok)
            cancel_ok = ok
        end)

        assert(select_called == true, "vim.ui.select prompted on client timeout")
        assert(#warnings >= 1 and warnings[1]:find("eslint", 1, true) ~= nil, "warning names failing client")
        assert(cancel_ok == false, "cancelling returns ok = false")
        assert(vim.uv.fs_stat(old_path) ~= nil and vim.uv.fs_stat(new_path) == nil, "disk untouched on cancel")
        assert(vim.fn.readfile(caller_path)[1] == 'import { a } from "./a";', "caller file untouched on cancel")
        assert(vim.api.nvim_buf_get_lines(caller_buf, 0, -1, false)[1] == 'import { a } from "./a";', "caller buffer untouched")
        assert(did_count == 0, "didRenameFiles not sent on cancel")

        -- Case B: Confirming proceeds cleanly
        vim.ui.select = function(_, _, on_choice)
            on_choice("Proceed with rename without full LSP import updates")
        end

        local proceed_ok, proceed_err
        lsp_files.rename(old_path, new_path, { attach_timeout_ms = 0 }, function(ok, err)
            proceed_ok, proceed_err = ok, err
        end)

        assert(proceed_ok == true and proceed_err == nil, "confirming proceeds cleanly: " .. tostring(proceed_err))
        assert(vim.uv.fs_stat(old_path) == nil and vim.uv.fs_stat(new_path) ~= nil, "file moved after confirm")
        assert(vim.fn.readfile(caller_path)[1] == 'import { a } from "./b";', "collected edit applied and saved")
        assert(did_count == 2, "didRenameFiles sent after confirm")

        pcall(vim.api.nvim_buf_delete, caller_buf, { force = true })
        vim.fn.delete(worktree, "rf")
        restore_stubs()
    end
end
