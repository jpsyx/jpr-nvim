-- Pure: turns the engine's SessionView into panel lines, highlights and a
-- line-to-path map. No windows or buffers here.
local header = require("jpr.render.panel.header")
local progress = require("jpr.render.panel.progress")
local tree = require("jpr.render.panel.tree")

local M = {}

M.age = header.age
M.one_line = header.one_line
M.build_branch_detail_lines = header.build_branch_detail_lines
M.sync_text = header.sync_text
M.build_worktree_badge_from_view = header.build_worktree_badge_from_view
M.build_counts_text = header.build_counts_text
M.build_threads_badge_from_file = header.build_threads_badge_from_file
M.create_flat_tree_from_files = tree.create_flat_tree_from_files
M.collect_directory_toggle_from_files = tree.collect_directory_toggle_from_files
M.find_next_unviewed_path = tree.find_next_unviewed_path
M.create_progress_bar_from_counts = progress.create_progress_bar_from_counts
M.append_progress_bar_highlights = progress.append_progress_bar_highlights

local function create_panel_content()
    local content = { lines = {}, highlights = {}, paths = {}, rows = {}, selectable_lines = {} }
    function content.add_line(text, group)
        content.lines[#content.lines + 1] = text
        if group then
            content.highlights[#content.highlights + 1] = {
                line = #content.lines - 1,
                col_start = 0,
                col_end = #text,
                group = group,
            }
        end
    end
    return content
end

local function render_panel_header(content, view, now, width, checkout_branch, hide_viewed)
    local pr = view.pr
    local local_ctx = type(view.localContext) == "table" and view.localContext or nil
    local is_unlinked_local = pr == nil and local_ctx ~= nil
    if pr then
        header.add_fitted_line(content, ("#%d %s"):format(pr.number, pr.title or ""), "JprTitle", width)
    elseif local_ctx then
        header.add_fitted_line(content, ("LOCAL %s vs %s"):format(local_ctx.branch or "", local_ctx.baseRef or ""), "JprTitle", width)
    else
        header.add_fitted_line(content, "Loading pull request…", "JprTitle", width)
    end
    for _, branch_line in ipairs(header.build_branch_detail_lines(pr, local_ctx, checkout_branch)) do
        header.add_fitted_line(content, branch_line, "JprMuted", width)
    end
    progress.add_progress_bar_line(content, view)
    content.add_line(header.build_counts_text(view), "JprMuted")
    if is_unlinked_local then
        content.add_line("local only · :Jpr sync to link PR", "JprMuted")
    else
        content.add_line(header.sync_text(view.sync, now))
    end
    local filter_line = progress.add_filter_pill_line(content, hide_viewed)
    return is_unlinked_local, filter_line
end

local function add_navigation_entries(content, view, is_unlinked_local)
    content.add_line("")
    content.add_line("  📄 Diff summary", "JprTitle")
    local summary_line = #content.lines
    content.rows[summary_line] = { kind = "summary" }
    content.selectable_lines[#content.selectable_lines + 1] = summary_line
    local conversation_count = view.conversationCount or 0
    local conversation_suffix = conversation_count > 0 and (" [%d]"):format(conversation_count) or ""
    local conversation_title = is_unlinked_local and "  💬 Local Notes" or "  💬 Conversation"
    content.add_line(conversation_title .. conversation_suffix, "JprTitle")
    local conversation_line = #content.lines
    content.rows[conversation_line] = { kind = "conversation" }
    content.selectable_lines[#content.selectable_lines + 1] = conversation_line
    return summary_line, conversation_line
end

--- The panel's contents for `view` at time `now` (Unix seconds): its lines,
--- their highlights, row metadata, selectable lines, and which file each line
--- shows, for the panel window to draw and navigate. `opts.hide_viewed`
--- omits `VIEWED` files and directories whose files are all `VIEWED`.
--- @return table { lines: string[], highlights: table[], paths: table<integer, string>, rows: table<integer, table>, selectable_lines: integer[], filter_line: integer, summary_line: integer, conversation_line: integer }
--- `line` is 0-based and columns are byte offsets; `paths` and `rows` are keyed by 1-based line number.
function M.build(view, now, opts)
    local collapsed_dirs = type(opts) == "table" and type(opts.collapsed_dirs) == "table" and opts.collapsed_dirs or {}
    local width = type(opts) == "table" and tonumber(opts.width) or nil
    local checkout_branch = type(opts) == "table" and opts.checkout_branch or nil
    local hide_viewed = type(opts) == "table" and opts.hide_viewed == true
    local content = create_panel_content()
    local is_unlinked_local, filter_line =
        render_panel_header(content, view, now, width, checkout_branch, hide_viewed)
    local summary_line, conversation_line = add_navigation_entries(content, view, is_unlinked_local)
    tree.render_tree_rows(content, view, collapsed_dirs, is_unlinked_local, hide_viewed)
    if hide_viewed and tree.every_file_is_viewed(view.files) then
        content.add_line("  all files viewed", "JprMuted")
    end
    return {
        lines = content.lines,
        highlights = content.highlights,
        paths = content.paths,
        rows = content.rows,
        selectable_lines = content.selectable_lines,
        filter_line = filter_line,
        summary_line = summary_line,
        conversation_line = conversation_line,
    }
end

return M
