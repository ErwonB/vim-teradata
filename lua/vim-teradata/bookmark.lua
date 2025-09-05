local config = require('vim-teradata.config')

local M = {}

--- Gets the paths for global and user-specific bookmark directories.
--- @return string global_path, string|nil user_path
local function get_bookmark_paths()
    local global_path = config.options.bookmarks_dir .. '/' .. config.options.global_bookmarks_dir_name
    local user_path = nil

    if config.options.current_user_index then
        local current_user = config.options.users[config.options.current_user_index]
        if current_user then
            -- Sanitize username for directory name
            local user_dir_name = current_user.user:gsub('[^%w_.-]', '_')
            user_path = config.options.bookmarks_dir ..
                '/' .. config.options.user_bookmarks_dir_name .. '/' .. user_dir_name
            if vim.fn.isdirectory(user_path) == 0 then
                vim.fn.mkdir(user_path, 'p')
            end
        end
    end
    return global_path, user_path
end

--- Retrieves all global and user-specific bookmarks.
--- @return table { global = string[], user = string[] }
function M.get_all()
    local global_path, user_path = get_bookmark_paths()
    local result = { global = {}, user = {} }

    local global_files = vim.fn.glob(global_path .. '/*', false, true)
    result.global = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ':t') end, global_files)

    if user_path then
        local user_files = vim.fn.glob(user_path .. '/*', false, true)
        result.user = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ':t') end, user_files)
    end
    table.sort(result.global)
    table.sort(result.user)

    return result
end

--- Saves a bookmark to a file.
--- @param name string The name of the bookmark.
--- @param content string The SQL content.
--- @param type 'global'|'user' The type of bookmark.
--- @return boolean success, string message
local function save(name, content, type)
    if not name or name == "" then
        return false, "Bookmark name cannot be empty."
    end
    if not content or content == "" then
        return false, "Bookmark content cannot be empty."
    end

    local global_path, user_path = get_bookmark_paths()
    local target_path

    if type == 'global' then
        target_path = global_path
    elseif type == 'user' then
        if not user_path then
            return false, "No user selected for user-specific bookmark."
        end
        target_path = user_path
    else
        return false, "Invalid bookmark type."
    end

    vim.fn.writefile(vim.fn.split(content, '\n'), target_path .. '/' .. name)
    return true, 'Bookmark "' .. name .. '" saved.'
end

--- Adds a bookmark from a visual selection.
function M.add_from_range()
    local start_pos = vim.api.nvim_buf_get_mark(0, "<")
    local end_pos = vim.api.nvim_buf_get_mark(0, ">")
    local content = table.concat(
        vim.api.nvim_buf_get_text(0, start_pos[1] - 1, start_pos[2], end_pos[1] - 1, end_pos[2], {}),
        '\n'
    )

    if content:match('^%s*$') then
        return vim.notify('No text selected.', vim.log.levels.WARN)
    end

    vim.ui.input({ prompt = 'Enter bookmark name:' }, function(name)
        if not name then return end
        local options = { 'global', 'user' }
        vim.ui.select(options, { prompt = 'Select bookmark type:' }, function(choice)
            if not choice then return end
            local ok, msg = save(name, content, choice)
            if ok then
                vim.notify(msg, vim.log.levels.INFO)
            else
                vim.notify(msg, vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Deletes a bookmark file.
--- @param name string The name of the bookmark.
--- @param type 'global'|'user' The type of bookmark.
function M.delete(name, type)
    local global_path, user_path = get_bookmark_paths()
    local file_path
    if type == 'global' then
        file_path = global_path .. '/' .. name
    elseif type == 'user' and user_path then
        file_path = user_path .. '/' .. name
    end

    if file_path and vim.fn.filereadable(file_path) == 1 then
        vim.fn.delete(file_path)
        vim.notify('Bookmark "' .. name .. '" deleted.', vim.log.levels.INFO)
    end
end

--- Gets the content of a specific bookmark.
--- @param name string The name of the bookmark.
--- @param type 'global'|'user' The type of bookmark.
--- @return table|nil The content as a list of strings, or nil if not found.
function M.get_content(name, type)
    local global_path, user_path = get_bookmark_paths()
    local file_path
    if type == 'global' then
        file_path = global_path .. '/' .. name
    elseif type == 'user' and user_path then
        file_path = user_path .. '/' .. name
    end

    if file_path and vim.fn.filereadable(file_path) == 1 then
        return vim.fn.readfile(file_path)
    end
    return nil
end

--- Inserts bookmark content at the end of a specified buffer.
--- @param name string The name of the bookmark.
--- @param type 'global'|'user' The type of bookmark.
--- @param bufnr number The buffer number to insert into.
function M.insert_into_buffer(name, type, bufnr)
    local content = M.get_content(name, type)
    if content and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, content)
        vim.notify('Bookmark "' .. name .. '" inserted.', vim.log.levels.INFO)
    end
end

return M
