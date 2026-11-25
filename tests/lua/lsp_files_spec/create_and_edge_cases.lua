-- LSP file create specs, symlinked willCreate root matching, and unloaded target buffer E95 guard.
return function(ctx)
    local lsp_files = ctx.lsp_files
    local create_temp_worktree = ctx.create_temp_worktree
    local write_lines = ctx.write_lines
    local open_buffer = ctx.open_buffer
    local restore_stubs = ctx.restore_stubs

    -- Test 5: Create file, create directory, and refuse existing target
    do
        local worktree = create_temp_worktree()
        local created_file = worktree .. "/nested/deep/new_file.ts"
        local created_dir = worktree .. "/nested/new_dir"

        local events = {}
        local fake_client = {
            id = 301,
            name = "tsserver",
            offset_encoding = "utf-16",
            config = { root_dir = worktree },
            server_capabilities = { workspace = { fileOperations = { willCreate = true, didCreate = true } } },
            request_sync = function(_, method, params)
                events[#events + 1] = { kind = "request", method = method, params = params }
                return { result = nil }
            end,
            notify = function(_, method, params)
                events[#events + 1] = { kind = "notify", method = method, params = params }
            end,
        }
        vim.lsp.get_clients = function()
            return { fake_client }
        end

        local file_ok, file_err
        lsp_files.create(created_file, false, {}, function(ok, err)
            file_ok, file_err = ok, err
        end)
        assert(file_ok == true and file_err == nil, "create file succeeds: " .. tostring(file_err))
        assert(vim.uv.fs_stat(created_file).type == "file", "created empty file exists")
        assert(#events == 2, "willCreateFiles and didCreateFiles sent")
        assert(events[1].method == "workspace/willCreateFiles", "willCreateFiles sent first")
        assert(events[2].method == "workspace/didCreateFiles", "didCreateFiles sent second")

        local dir_ok, dir_err
        lsp_files.create(created_dir, true, {}, function(ok, err)
            dir_ok, dir_err = ok, err
        end)
        assert(dir_ok == true and dir_err == nil, "create dir succeeds: " .. tostring(dir_err))
        assert(vim.uv.fs_stat(created_dir).type == "directory", "created directory exists")

        local dup_file_ok, dup_file_err
        lsp_files.create(created_file, false, {}, function(ok, err)
            dup_file_ok, dup_file_err = ok, err
        end)
        assert(dup_file_ok == false and dup_file_err ~= nil, "existing file creation refused")

        local dup_dir_ok, dup_dir_err
        lsp_files.create(created_dir, true, {}, function(ok, err)
            dup_dir_ok, dup_dir_err = ok, err
        end)
        assert(dup_dir_ok == false and dup_dir_err ~= nil, "existing dir creation refused")

        vim.fn.delete(worktree, "rf")
        restore_stubs()
    end

    -- Test 6: willCreate matches symlinked root via nearest existing parent, and rename guards against unloaded target buffer E95
    do
        local real_root = create_temp_worktree()
        local symlink_root = vim.fn.tempname()
        assert(vim.uv.fs_symlink(real_root, symlink_root, { dir = true }), "create symlink root")

        local will_create_count = 0
        local fake_client = {
            id = 401,
            name = "tsserver",
            offset_encoding = "utf-16",
            config = { root_dir = real_root },
            server_capabilities = { workspace = { fileOperations = { willCreate = true, didCreate = true } } },
            request_sync = function()
                will_create_count = will_create_count + 1
                return { result = nil }
            end,
            notify = function() end,
        }
        vim.lsp.get_clients = function()
            return { fake_client }
        end

        local nested_target = symlink_root .. "/deep/uncreated/new.ts"
        local create_ok, create_err
        lsp_files.create(nested_target, false, {}, function(ok, err)
            create_ok, create_err = ok, err
        end)
        assert(create_ok == true and create_err == nil, "symlinked willCreate succeeds: " .. tostring(create_err))
        assert(will_create_count == 1, "symlinked non-existent path matched real_root client via nearest existing parent")

        local src_path = real_root .. "/rename_src.ts"
        local dst_path = real_root .. "/rename_dst.ts"
        write_lines(src_path, { "export const v = 1;" })
        local loaded_src_buf = open_buffer(src_path)
        local stale_unloaded_dst_buf = vim.fn.bufadd(dst_path)
        assert(not vim.api.nvim_buf_is_loaded(stale_unloaded_dst_buf), "stale destination buffer is unloaded")

        vim.lsp.get_clients = function()
            return {}
        end
        local rename_ok, rename_err
        lsp_files.rename(src_path, dst_path, { attach_timeout_ms = 0 }, function(ok, err)
            rename_ok, rename_err = ok, err
        end)
        assert(rename_ok == true and rename_err == nil, "rename succeeds despite unloaded target buffer: " .. tostring(rename_err))
        assert(vim.api.nvim_buf_get_name(loaded_src_buf) == dst_path, "open buffer renamed cleanly without E95")

        pcall(vim.api.nvim_buf_delete, loaded_src_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, stale_unloaded_dst_buf, { force = true })
        vim.uv.fs_unlink(symlink_root)
        vim.fn.delete(real_root, "rf")
        restore_stubs()
    end
end
